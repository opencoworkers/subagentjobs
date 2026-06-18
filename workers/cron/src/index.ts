/**
 * subagentjobs-cron — 5-line shim.
 * Calls the Rust MCP server's crawl_board for each board.
 * Zero business logic here — all CDC, hashing, and DB writes are in Rust.
 */
interface Env { MCP_URL: string }

const BOARDS = ["anthropic","cloudflare","databricks","discord","figma",
                "stripe","andurilindustries","palantir","spotify"];

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
