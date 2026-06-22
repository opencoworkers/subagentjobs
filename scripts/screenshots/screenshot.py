#!/usr/bin/env python3
"""
screenshot.py — Sonnet-4-6-optimised screen capture utility.

Problem: raw macOS retina screenshots (e.g. 2560×1600 PNG ≈ 5 MB) exceed the
image size budget that works reliably with claude-sonnet-4-6, which has lower
image-processing headroom than claude-opus-4-6.

Solution: capture → resize to Claude's native vision budget → JPEG compress.

Claude's vision pipeline (from docs.anthropic.com/vision):
  • Resizes to fit within 1568 px longest edge AND ≤ 1.15 MP before billing.
  • Max supported: 8000×8000 px, 10 MB base64.
  We pre-downscale to the billing threshold so the model sees the same pixels
  we pay for — no wasted bytes, no API failures.

Uses macOS built-in `sips` — NO external Python packages required.

Usage (CLI):
    python3 screenshot.py                          # prints base64 to stdout
    python3 screenshot.py --out /tmp/shot.jpg      # saves file, prints path
    python3 screenshot.py --quality 75             # JPEG quality (default 72)
    python3 screenshot.py --max-px 1280            # longest-edge cap (default 1568)
    python3 screenshot.py --window <app-name>      # capture specific window

Usage (Python import):
    from screenshot import capture_base64, capture_file
    b64  = capture_base64()           # → str (base64, embed in API image block)
    path = capture_file("/tmp/s.jpg") # → str path to compressed JPEG
"""

import argparse
import base64
import subprocess
import sys
import tempfile
from pathlib import Path

# ── Defaults tuned for claude-sonnet-4-6 ────────────────────────────────────
# 1568 px = Claude's longest-edge billing threshold (anything larger is
# downscaled by the API anyway — we just skip the wasted upload bytes).
DEFAULT_MAX_PX  = 1568
# JPEG quality: 72 preserves text readability while keeping files ≪ 500 KB.
DEFAULT_QUALITY = 72
# ─────────────────────────────────────────────────────────────────────────────


def _take_raw_screenshot(window: str | None = None) -> Path:
    """Use macOS `screencapture` to grab a PNG into a temp file."""
    tmp = Path(tempfile.mktemp(suffix=".png"))
    cmd = ["screencapture", "-x"]   # -x = no sound
    if window:
        try:
            win_id = _get_window_id(window)
            cmd += ["-l", str(win_id)]
        except Exception:
            pass  # fall back to full-screen
    cmd.append(str(tmp))
    subprocess.run(cmd, check=True, capture_output=True)
    return tmp


def _get_window_id(app_name: str) -> int:
    """Return the CGWindowID for the frontmost window of `app_name` via Swift."""
    swift_code = f'''
import AppKit
let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
for w in windows {{
    let owner = w["kCGWindowOwnerName"] as? String ?? ""
    if owner.contains("{app_name}") {{
        if let id = w["kCGWindowNumber"] as? Int {{
            print(id)
            exit(0)
        }}
    }}
}}
exit(1)
'''
    result = subprocess.run(
        ["swift", "-"],
        input=swift_code, capture_output=True, text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError(f"Window not found for app '{app_name}'")
    return int(result.stdout.strip())


def _get_image_dimensions(path: Path) -> tuple[int, int]:
    """Return (width, height) using sips."""
    result = subprocess.run(
        ["sips", "--getProperty", "pixelWidth", "--getProperty", "pixelHeight", str(path)],
        capture_output=True, text=True, check=True,
    )
    w = h = 0
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith("pixelWidth:"):
            w = int(line.split(":")[1].strip())
        elif line.startswith("pixelHeight:"):
            h = int(line.split(":")[1].strip())
    return w, h


def _resize_and_compress(
    src: Path,
    dest: Path,
    max_px: int = DEFAULT_MAX_PX,
    quality: int = DEFAULT_QUALITY,
) -> None:
    """
    Resize `src` PNG to fit within max_px (longest edge), save as JPEG at `dest`.
    Uses macOS `sips` — no Python packages needed.
    """
    w, h = _get_image_dimensions(src)
    longest = max(w, h)

    # Step 1: resize if needed (sips --resampleLongitudinalAxis keeps aspect ratio)
    if longest > max_px:
        resized = Path(tempfile.mktemp(suffix=".png"))
        # -Z / --resampleHeightWidthMax: resize so longest edge ≤ max_px, keep aspect ratio
        subprocess.run(
            ["sips", "-Z", str(max_px), str(src), "--out", str(resized)],
            check=True, capture_output=True,
        )
        src_to_convert = resized
    else:
        resized = None
        src_to_convert = src

    try:
        # Step 2: convert to JPEG at target quality
        subprocess.run(
            ["sips",
             "--setProperty", "format", "jpeg",
             "--setProperty", "formatOptions", str(quality),
             str(src_to_convert),
             "--out", str(dest)],
            check=True, capture_output=True,
        )
    finally:
        if resized:
            resized.unlink(missing_ok=True)


def capture_file(
    out_path: str | Path | None = None,
    window: str | None = None,
    max_px: int = DEFAULT_MAX_PX,
    quality: int = DEFAULT_QUALITY,
) -> str:
    """
    Capture the screen, resize/compress, save to `out_path` (or a temp file).
    Returns the path to the JPEG file as a string.
    """
    if out_path is None:
        out_path = Path(tempfile.mktemp(suffix=".jpg"))
    else:
        out_path = Path(out_path)

    raw = _take_raw_screenshot(window=window)
    try:
        _resize_and_compress(raw, out_path, max_px=max_px, quality=quality)
    finally:
        raw.unlink(missing_ok=True)

    size_kb = out_path.stat().st_size / 1024
    print(f"[screenshot] {size_kb:.0f} KB JPEG (max_px={max_px}, q={quality})",
          file=sys.stderr)
    return str(out_path)


def capture_base64(
    window: str | None = None,
    max_px: int = DEFAULT_MAX_PX,
    quality: int = DEFAULT_QUALITY,
) -> str:
    """
    Capture the screen and return a base64-encoded JPEG string.
    Suitable for direct embedding in Claude API `image` content blocks:

        {"type": "image", "source": {"type": "base64",
         "media_type": "image/jpeg", "data": capture_base64()}}
    """
    tmp_jpg = Path(tempfile.mktemp(suffix=".jpg"))
    try:
        capture_file(tmp_jpg, window=window, max_px=max_px, quality=quality)
        data = tmp_jpg.read_bytes()
        return base64.b64encode(data).decode("ascii")
    finally:
        tmp_jpg.unlink(missing_ok=True)


# ── CLI ──────────────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out",     metavar="PATH",    help="Save JPEG to this path (default: print base64)")
    p.add_argument("--quality", metavar="N",  type=int, default=DEFAULT_QUALITY,
                   help=f"JPEG quality 1–95 (default {DEFAULT_QUALITY})")
    p.add_argument("--max-px",  metavar="N",  type=int, default=DEFAULT_MAX_PX,
                   help=f"Longest-edge pixel cap (default {DEFAULT_MAX_PX})")
    p.add_argument("--window",  metavar="APP",
                   help="Capture frontmost window of this app name")
    args = p.parse_args()

    if args.out:
        path = capture_file(args.out, window=args.window,
                            max_px=args.max_px, quality=args.quality)
        size_kb = Path(path).stat().st_size / 1024
        w, h = _get_image_dimensions(Path(path))
        print(f"Saved: {path}  ({w}×{h} px, {size_kb:.0f} KB)")
    else:
        b64 = capture_base64(window=args.window,
                             max_px=args.max_px, quality=args.quality)
        print(b64)


if __name__ == "__main__":
    main()
