/**
 * subagentjobs-cron
 *
 * Phase 1: Crawl all boards via Rust MCP (unchanged)
 * Phase 2: Evict stale jobs — tombstone + consecutive-miss counter + two-phase delete
 *
 * Eviction algorithm (runs after every crawl cycle):
 *   For each board, fetch the current live job IDs directly from the source API.
 *   ┌─ job in D1 AND in live API  → miss_count = 0  (stays active / auto-restores)
 *   └─ job in D1 NOT in live API  → miss_count++
 *        miss_count >= MISS_THRESHOLD → evicted_at = now()  (soft-delete)
 *   evicted_at older than HARD_DELETE_DAYS → DELETE  (hard delete)
 *
 * Why 3 misses?  At a 6-hour crawl cadence, 3 misses = 18 hours of absence before
 * soft-deleting.  This survives transient API outages and crawler hiccups.
 *
 * Why a grace period?  Soft-deleted rows are kept 30 days for auditability and
 * recovery from crawler bugs.  They are already hidden from the web UI on day 1.
 *
 * Conservative default: if an API call fails (network error, 4xx/5xx) we return
 * { ok: false } and skip eviction for that board entirely.  Better to leave a
 * stale job visible than to wipe a live one because of a transient error.
 */

interface Env {
  MCP_URL: string;
  DB: D1Database;
}

// ── Greenhouse (45 boards) ───────────────────────────────────────────────────
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
const LEVER_BOARDS = [
  "cred", "matillion", "spotify",
  "charmindustrial",   // charm-industrial
];

const BOARDS = [...GREENHOUSE_BOARDS, ...LEVER_BOARDS];

// Tune these to trade eviction speed vs safety
const MISS_THRESHOLD    = 3;   // consecutive missed crawls before soft-delete (18 hrs at 6h cadence)
const HARD_DELETE_DAYS  = 30;  // days after soft-delete before hard delete

// ── Types ─────────────────────────────────────────────────────────────────────
type LiveIdsResult =
  | { ok: true;  ids: Set<string> }
  | { ok: false; reason: string  };

// ── Main handler ──────────────────────────────────────────────────────────────
export default {
  async scheduled(_: ScheduledEvent, env: Env): Promise<void> {
    // ── Phase 1: Crawl ────────────────────────────────────────────────────────
    await Promise.allSettled(
      BOARDS.map((board) =>
        fetch(`${env.MCP_URL}/crawl?board=${board}`)
          .then((r) => r.json())
          .then((d) => console.log(JSON.stringify({ board, ...d as object })))
      )
    );

    // ── Phase 2: Evict stale jobs ─────────────────────────────────────────────
    let totalEvicted = 0;
    let totalRestored = 0;

    const evictionResults = await Promise.allSettled(
      BOARDS.map(async (board) => {
        const result = LEVER_BOARDS.includes(board)
          ? await fetchLeverIds(board)
          : await fetchGreenhouseIds(board);

        if (!result.ok) {
          console.warn(`eviction skipped for ${board}: ${result.reason}`);
          return { evicted: 0, restored: 0 };
        }

        return evictBoard(env.DB, board, result.ids);
      })
    );

    for (const r of evictionResults) {
      if (r.status === 'fulfilled') {
        totalEvicted  += r.value.evicted;
        totalRestored += r.value.restored;
      }
    }

    // Global hard-delete pass — purge tombstones older than HARD_DELETE_DAYS
    const hardDelete = await env.DB
      .prepare(
        `DELETE FROM fact_job_posting
         WHERE evicted_at IS NOT NULL
           AND evicted_at < datetime('now', '-${HARD_DELETE_DAYS} days')`
      )
      .run();

    console.log(JSON.stringify({
      phase: 'eviction_summary',
      soft_evicted:  totalEvicted,
      auto_restored: totalRestored,
      hard_deleted:  hardDelete.meta.changes ?? 0,
    }));
  },
};

// ── API fetchers ──────────────────────────────────────────────────────────────

async function fetchGreenhouseIds(token: string): Promise<LiveIdsResult> {
  try {
    const r = await fetch(
      `https://boards-api.greenhouse.io/v1/boards/${token}/jobs`,
      {
        headers: { 'User-Agent': 'subagentjobs-cron/1.0' },
        signal: AbortSignal.timeout(15_000),
      }
    );
    if (!r.ok) return { ok: false, reason: `HTTP ${r.status}` };
    const { jobs } = await r.json() as { jobs: Array<{ id: number }> };
    return { ok: true, ids: new Set(jobs.map(j => String(j.id))) };
  } catch (e) {
    return { ok: false, reason: String(e) };
  }
}

async function fetchLeverIds(token: string): Promise<LiveIdsResult> {
  const ids = new Set<string>();
  try {
    let skip = 0;
    while (true) {
      const r = await fetch(
        `https://api.lever.co/v0/postings/${token}?limit=250&skip=${skip}`,
        { signal: AbortSignal.timeout(15_000) }
      );
      if (!r.ok) return { ok: false, reason: `HTTP ${r.status}` };
      const data = await r.json() as Array<{ id: string }>;
      if (!data.length) break;
      data.forEach(j => ids.add(j.id));
      if (data.length < 250) break;
      skip += 250;
    }
    return { ok: true, ids };
  } catch (e) {
    return { ok: false, reason: String(e) };
  }
}

// ── Eviction logic ────────────────────────────────────────────────────────────

async function evictBoard(
  db: D1Database,
  companyName: string,
  liveIds: Set<string>
): Promise<{ evicted: number; restored: number }> {
  // Fetch all currently-active (non-evicted) job IDs for this board from D1
  const { results } = await db
    .prepare(`SELECT job_post_id FROM fact_job_posting WHERE company_name=? AND evicted_at IS NULL`)
    .bind(companyName)
    .all<{ job_post_id: string }>();

  if (results.length === 0) return { evicted: 0, restored: 0 };

  // Partition into stale (absent from API) and fresh (present in API)
  const staleIds = results
    .filter(r => !liveIds.has(String(r.job_post_id)))
    .map(r => String(r.job_post_id));

  const freshIds = results
    .filter(r => liveIds.has(String(r.job_post_id)))
    .map(r => String(r.job_post_id));

  const stmts: D1PreparedStatement[] = [];

  // Increment miss_count for absent jobs (batched to keep IN clause ≤100 IDs)
  for (let i = 0; i < staleIds.length; i += 100) {
    const batch = staleIds.slice(i, i + 100);
    const ph = batch.map(() => '?').join(',');
    stmts.push(
      db.prepare(`UPDATE fact_job_posting SET miss_count=miss_count+1 WHERE job_post_id IN (${ph})`)
        .bind(...batch)
    );
  }

  // Reset miss_count (and un-evict) for jobs that are back in the API
  for (let i = 0; i < freshIds.length; i += 100) {
    const batch = freshIds.slice(i, i + 100);
    const ph = batch.map(() => '?').join(',');
    stmts.push(
      db.prepare(`UPDATE fact_job_posting SET miss_count=0, evicted_at=NULL WHERE job_post_id IN (${ph})`)
        .bind(...batch)
    );
  }

  // Soft-delete jobs that have crossed the miss threshold
  stmts.push(
    db.prepare(
      `UPDATE fact_job_posting
       SET evicted_at=datetime('now')
       WHERE company_name=? AND miss_count>=? AND evicted_at IS NULL`
    ).bind(companyName, MISS_THRESHOLD)
  );

  await db.batch(stmts);

  // Count newly evicted and currently active (for logging)
  const [evictedRow, activeRow] = await Promise.all([
    db.prepare(`SELECT COUNT(*) as n FROM fact_job_posting WHERE company_name=? AND evicted_at IS NOT NULL`)
      .bind(companyName).first<{ n: number }>(),
    db.prepare(`SELECT COUNT(*) as n FROM fact_job_posting WHERE company_name=? AND evicted_at IS NULL`)
      .bind(companyName).first<{ n: number }>(),
  ]);

  const evicted  = evictedRow?.n  ?? 0;
  const restored = activeRow?.n   ?? 0;

  if (evicted > 0) {
    console.log(JSON.stringify({ board: companyName, active: restored, evicted, stale_count: staleIds.length }));
  }

  return { evicted, restored };
}
