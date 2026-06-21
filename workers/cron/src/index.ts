/**
 * subagentjobs-cron — thin shim.
 * Calls the Rust MCP server's crawl_board for each board.
 * Zero business logic here — all CDC, hashing, and DB writes are in Rust.
 *
 * Board lists are canonical in workers/cron/boards/{greenhouse,lever}.yaml.
 * Lever boards must exist in dim_board with platform='lever' (migration 003).
 * Ashby boards are not yet supported by the crawler.
 */
interface Env { MCP_URL: string }

// ── Greenhouse (45 boards) ───────────────────────────────────────────────────
// Canonical list lives in workers/cron/boards/greenhouse.yaml
const GREENHOUSE_BOARDS = [
  // original validated
  "asana", "athena", "aura", "block", "brainlabs", "brex", "chronograph",
  "circleci", "coinbase", "descript", "doctolib", "figma", "gitlab",
  "gradial", "intercom", "jamf", "jetbrains", "juno", "lex", "lokalise",
  "lovable", "lyft", "n26", "otter", "postman", "praxis", "quantium",
  "smartsheet", "stripe", "tines", "warp", "workato", "zencoder",
  // resolved from unknown list via fuzzy probe
  "apollo", "cartahealthcare", "elationhealth", "futurehouse", "grafanalabs",
  "hubspot", "hume", "pendo", "prathaminternational", "triplewhale", "twilio",
  "youcom",
];

// ── Lever (4 boards) — platform seeded in dim_board via migration 003 ────────
// Canonical list lives in workers/cron/boards/lever.yaml
const LEVER_BOARDS = [
  "cred", "matillion", "spotify",
  "charmindustrial",   // charm-industrial
];

const BOARDS = [...GREENHOUSE_BOARDS, ...LEVER_BOARDS];

export default {
  async scheduled(_: ScheduledEvent, env: Env): Promise<void> {
    await Promise.allSettled(
      BOARDS.map((board) =>
        fetch(`${env.MCP_URL}/crawl?board=${board}`)
          .then((r) => r.json())
          .then((d) => console.log(JSON.stringify({ board, ...d as object })))
      )
    );
  },
};
