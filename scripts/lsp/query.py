#!/usr/bin/env python3
"""
scripts/lsp/query.py — Repo-aware LSP code-intelligence tool

Uses installed LSP servers (never downloads its own):
  Rust:       rustup which rust-analyzer
  TypeScript: which typescript-language-server
  Swift:      xcrun --find sourcekit-lsp  (macOS)  or  /opt/swift/usr/bin/sourcekit-lsp  (Linux)

Usage (run from repo root, or any subdirectory):
  python3 scripts/lsp/query.py symbols  <file>
  python3 scripts/lsp/query.py def      <file> <line> <col>
  python3 scripts/lsp/query.py refs     <file> <line> <col>
  python3 scripts/lsp/query.py hover    <file> <line> <col>

Line/col are 0-based (LSP convention).  File path is relative to repo root.

Output: JSON to stdout, one result per line.
        Errors go to stderr and exit 1.

Language auto-detected from extension:
  .rs            → rust   (multilspy + system rust-analyzer)
  .ts .tsx       → typescript (multilspy + system typescript-language-server)
  .swift         → swift  (sourcekit-lsp via minimal JSON-RPC subprocess)

Supported queries per language:
  rust, typescript  →  symbols, def, refs, hover
  swift             →  symbols  (def/refs/hover require macOS + running sourcekit-lsp)
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import threading
import time
from queue import Queue, Empty
from typing import Any


# ── Repo root detection ───────────────────────────────────────────────────────

def find_repo_root(start: pathlib.Path) -> pathlib.Path:
    """Walk up until we find a Cargo.toml at the workspace root."""
    p = start.resolve()
    while True:
        if (p / "Cargo.toml").exists() and (p / ".claude").exists():
            return p
        if p.parent == p:
            # Fallback: current directory
            return start.resolve()
        p = p.parent


# ── System binary discovery ───────────────────────────────────────────────────

def find_rust_analyzer() -> str:
    r = subprocess.run(["rustup", "which", "rust-analyzer"],
                       capture_output=True, text=True)
    if r.returncode == 0:
        return r.stdout.strip()
    p = shutil.which("rust-analyzer")
    if p:
        return p
    raise RuntimeError(
        "rust-analyzer not found. Fix: rustup component add rust-analyzer"
    )


def find_typescript_language_server() -> str:
    p = shutil.which("typescript-language-server")
    if p:
        return p
    raise RuntimeError(
        "typescript-language-server not found. "
        "Fix: npm install -g typescript-language-server typescript"
    )


def find_sourcekit_lsp() -> str:
    xcode_beta = "/Applications/Xcode-beta.app/Contents/Developer"
    for env in [{**os.environ, "DEVELOPER_DIR": xcode_beta}, os.environ]:
        r = subprocess.run(
            ["xcrun", "--find", "sourcekit-lsp"],
            capture_output=True, text=True, env=env
        )
        if r.returncode == 0:
            return r.stdout.strip()
    for candidate in [
        "/opt/swift/usr/bin/sourcekit-lsp",
        "/usr/bin/sourcekit-lsp",
    ]:
        if os.path.exists(candidate):
            return candidate
    p = shutil.which("sourcekit-lsp")
    if p:
        return p
    raise RuntimeError(
        "sourcekit-lsp not found. On macOS install Xcode beta. "
        "On Linux run: make toolchain"
    )


# ── multilspy monkeypatch ─────────────────────────────────────────────────────
#
# multilspy bundles its own rust-analyzer (Oct 2023) and typescript-language-server.
# Those stale binaries don't understand Rust 1.96 syntax.  We replace
# setup_runtime_dependencies() on both classes to return our system binaries.

def _patch_multilspy_to_use_system_binaries() -> None:
    # Import the classes before patching
    from multilspy.language_servers.rust_analyzer.rust_analyzer import RustAnalyzer
    from multilspy.language_servers.typescript_language_server.typescript_language_server import (
        TypeScriptLanguageServer,
    )

    def ra_setup(self, logger, config):
        return find_rust_analyzer()

    def ts_setup(self, logger, config):
        return find_typescript_language_server()

    RustAnalyzer.setup_runtime_dependencies = ra_setup           # type: ignore[method-assign]
    TypeScriptLanguageServer.setup_runtime_dependencies = ts_setup  # type: ignore[method-assign]


# ── Multilspy queries (Rust + TypeScript) ─────────────────────────────────────

def _multilspy_query(kind: str, language: str, filepath: str,
                     line: int, col: int, repo_root: str) -> list[dict]:
    _patch_multilspy_to_use_system_binaries()

    from multilspy import SyncLanguageServer
    from multilspy.multilspy_config import MultilspyConfig
    from multilspy.multilspy_logger import MultilspyLogger

    config = MultilspyConfig.from_dict({"code_language": language})
    logger = MultilspyLogger()

    # Relative path within the project (multilspy wants repo-relative paths)
    abs_file = pathlib.Path(filepath).resolve()
    rel_file = str(abs_file.relative_to(pathlib.Path(repo_root).resolve()))

    # multilspy returns results as (list, ...) tuple — unwrap first element
    def _unwrap(raw: Any) -> list:
        if isinstance(raw, tuple):
            raw = raw[0] if raw else []
        return raw or []

    KIND_MAP = {
        1: "file", 2: "module", 3: "namespace", 4: "package",
        5: "class", 6: "method", 7: "property", 8: "field",
        9: "constructor", 10: "enum", 11: "interface", 12: "function",
        13: "variable", 14: "constant", 23: "struct", 22: "enum_member",
        19: "object", 24: "event", 25: "operator", 26: "type_parameter",
    }

    results: list[dict] = []
    server = SyncLanguageServer.create(config, logger, repo_root)
    with server.start_server() as lsp:
        if kind == "symbols":
            raw = _unwrap(lsp.request_document_symbols(rel_file))
            for sym in raw:
                kind_int = sym.get("kind", 0)
                results.append({
                    "name": sym.get("name"),
                    "kind": KIND_MAP.get(kind_int, str(kind_int)),
                    "detail": sym.get("detail"),
                    "range": sym.get("selectionRange") or sym.get("range"),
                    "children": [c.get("name") for c in sym.get("children", [])],
                })
        elif kind == "def":
            raw = _unwrap(lsp.request_definition(rel_file, line, col))
            for loc in raw:
                results.append({
                    "file": loc.get("uri", "").replace("file://", ""),
                    "range": loc.get("range"),
                })
        elif kind == "refs":
            raw = _unwrap(lsp.request_references(rel_file, line, col))
            for loc in raw:
                results.append({
                    "file": loc.get("uri", "").replace("file://", ""),
                    "range": loc.get("range"),
                })
        elif kind == "hover":
            raw_hover = lsp.request_hover(rel_file, line, col)
            if isinstance(raw_hover, tuple):
                raw_hover = raw_hover[0] if raw_hover else None
            if raw_hover:
                content = raw_hover.get("contents", raw_hover) if isinstance(raw_hover, dict) else raw_hover
                if isinstance(content, dict):
                    results.append({"value": content.get("value", str(content))})
                elif isinstance(content, list):
                    for item in content:
                        val = item.get("value", item) if isinstance(item, dict) else item
                        results.append({"value": val})
                else:
                    results.append({"value": str(content)})

    return results


# ── Minimal synchronous LSP client for Swift / sourcekit-lsp ─────────────────

class _SwiftLSP:
    """
    Thin synchronous wrapper around sourcekit-lsp for document-symbol queries.

    sourcekit-lsp speaks JSON-RPC 2.0 over stdio with the standard
    Content-Length header framing.  We spawn it as a subprocess, send
    initialize + textDocument/didOpen + textDocument/documentSymbol, then
    terminate the process.
    """

    TIMEOUT = 30  # seconds to wait for symbol response

    def __init__(self, binary: str, repo_root: str):
        self.binary = binary
        self.repo_root = str(pathlib.Path(repo_root).resolve())
        self._id = 0
        self._proc: subprocess.Popen | None = None
        self._queue: Queue[dict] = Queue()
        self._reader_thread: threading.Thread | None = None

    # ── Wire helpers ──────────────────────────────────────────────────────────

    def _next_id(self) -> int:
        self._id += 1
        return self._id

    def _send(self, msg: dict) -> None:
        assert self._proc and self._proc.stdin
        body = json.dumps(msg).encode()
        header = f"Content-Length: {len(body)}\r\n\r\n".encode()
        self._proc.stdin.write(header + body)
        self._proc.stdin.flush()

    def _reader_loop(self) -> None:
        """Background thread: read LSP responses and push to queue."""
        assert self._proc and self._proc.stdout
        stdout = self._proc.stdout
        buf = b""
        while True:
            ch = stdout.read(1)
            if not ch:
                break
            buf += ch
            if buf.endswith(b"\r\n\r\n"):
                try:
                    length = int(
                        buf.decode().split("Content-Length:")[1].strip().split()[0]
                    )
                except (IndexError, ValueError):
                    buf = b""
                    continue
                body = stdout.read(length)
                if not body:
                    break
                try:
                    self._queue.put(json.loads(body))
                except json.JSONDecodeError:
                    pass
                buf = b""

    def _wait_for(self, req_id: int, timeout: float = TIMEOUT) -> dict | None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = self._queue.get(timeout=deadline - time.time())
                if msg.get("id") == req_id:
                    return msg
                # Put non-matching messages back (notifications, other responses)
                self._queue.put(msg)
                time.sleep(0.01)
            except Empty:
                break
        return None

    # ── Lifecycle ─────────────────────────────────────────────────────────────

    def __enter__(self) -> "_SwiftLSP":
        self._proc = subprocess.Popen(
            [self.binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self._reader_thread = threading.Thread(
            target=self._reader_loop, daemon=True
        )
        self._reader_thread.start()

        # Initialize handshake
        init_id = self._next_id()
        self._send({
            "jsonrpc": "2.0",
            "id": init_id,
            "method": "initialize",
            "params": {
                "processId": os.getpid(),
                "rootUri": pathlib.Path(self.repo_root).as_uri(),
                "capabilities": {
                    "textDocument": {
                        "documentSymbol": {
                            "hierarchicalDocumentSymbolSupport": True
                        }
                    }
                },
                "initializationOptions": {},
            },
        })
        self._wait_for(init_id, timeout=15)

        # initialized notification (no id — fire-and-forget)
        self._send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
        return self

    def __exit__(self, *_: Any) -> None:
        if self._proc:
            try:
                self._proc.terminate()
                self._proc.wait(timeout=3)
            except Exception:
                self._proc.kill()

    # ── Queries ───────────────────────────────────────────────────────────────

    def document_symbols(self, filepath: str) -> list[dict]:
        abs_path = pathlib.Path(filepath).resolve()
        uri = abs_path.as_uri()
        content = abs_path.read_text(encoding="utf-8")

        # Open document
        self._send({
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {
                "textDocument": {
                    "uri": uri,
                    "languageId": "swift",
                    "version": 1,
                    "text": content,
                }
            },
        })
        # Give sourcekit-lsp a moment to index the file
        time.sleep(1)

        sym_id = self._next_id()
        self._send({
            "jsonrpc": "2.0",
            "id": sym_id,
            "method": "textDocument/documentSymbol",
            "params": {"textDocument": {"uri": uri}},
        })
        resp = self._wait_for(sym_id)
        if resp is None:
            return []
        return resp.get("result") or []


def _flatten_swift_symbols(syms: list[dict], depth: int = 0) -> list[dict]:
    out = []
    KIND_MAP = {
        1: "file", 2: "module", 3: "namespace", 4: "package",
        5: "class", 6: "method", 7: "property", 8: "field",
        9: "constructor", 10: "enum", 11: "interface", 12: "function",
        13: "variable", 14: "constant", 15: "string", 16: "number",
        17: "boolean", 18: "array", 19: "object", 20: "key",
        21: "null", 22: "enum_member", 23: "struct", 24: "event",
        25: "operator", 26: "type_parameter",
    }
    for sym in syms:
        kind_int = sym.get("kind", 0)
        out.append({
            "name": sym.get("name", "?"),
            "kind": KIND_MAP.get(kind_int, str(kind_int)),
            "depth": depth,
            "range": sym.get("selectionRange") or sym.get("range"),
        })
        children = sym.get("children", [])
        if children:
            out.extend(_flatten_swift_symbols(children, depth + 1))
    return out


def _swift_symbols(filepath: str, repo_root: str) -> list[dict]:
    binary = find_sourcekit_lsp()
    with _SwiftLSP(binary, repo_root) as lsp:
        raw = lsp.document_symbols(filepath)
    return _flatten_swift_symbols(raw)


# ── Main entry point ──────────────────────────────────────────────────────────

LANGUAGE_MAP = {
    ".rs": "rust",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".swift": "swift",
}


def detect_language(filepath: str) -> str:
    ext = pathlib.Path(filepath).suffix.lower()
    lang = LANGUAGE_MAP.get(ext)
    if lang is None:
        print(
            f"error: unsupported extension '{ext}'. Supported: .rs .ts .tsx .swift",
            file=sys.stderr,
        )
        sys.exit(1)
    return lang


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Repo-aware LSP code-intelligence (Rust / TypeScript / Swift)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "kind",
        choices=["symbols", "def", "refs", "hover"],
        help="Query kind",
    )
    parser.add_argument("file", help="Source file (relative to repo root)")
    parser.add_argument("line", nargs="?", type=int, default=0,
                        help="Line number (0-based, required for def/refs/hover)")
    parser.add_argument("col", nargs="?", type=int, default=0,
                        help="Column number (0-based, required for def/refs/hover)")
    parser.add_argument("--json", action="store_true",
                        help="Output as JSON array instead of JSON lines")
    args = parser.parse_args()

    repo_root = str(find_repo_root(pathlib.Path(args.file).parent
                                   if not pathlib.Path(args.file).is_absolute()
                                   else pathlib.Path(args.file)))

    # Resolve file to absolute path
    filepath = str(pathlib.Path(args.file).resolve())
    if not os.path.exists(filepath):
        print(f"error: file not found: {args.file}", file=sys.stderr)
        sys.exit(1)

    language = detect_language(filepath)

    try:
        if language == "swift":
            if args.kind != "symbols":
                print(
                    f"error: Swift only supports 'symbols' via this tool "
                    f"(def/refs/hover require a running sourcekit-lsp session). "
                    f"Use the swift-lsp Claude Code plugin for interactive queries.",
                    file=sys.stderr,
                )
                sys.exit(1)
            results = _swift_symbols(filepath, repo_root)
        else:
            results = _multilspy_query(
                args.kind, language, filepath,
                args.line, args.col, repo_root
            )
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        for item in results:
            print(json.dumps(item))


if __name__ == "__main__":
    main()
