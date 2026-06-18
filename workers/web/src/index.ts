/**
 * subagentjobs-web — thin Hono router, D1 read-only, no business logic.
 * All writes go through the Rust MCP server.
 */
import { Hono } from "hono";
import { cache } from "hono/cache";

export interface Env {
  DB: D1Database;
  CACHE: KVNamespace;
}

const app = new Hono<{ Bindings: Env }>();

// ── /api/stats ──────────────────────────────────────────────────────────────
app.get("/api/stats", cache({ cacheName: "stats", cacheControl: "max-age=60" }), async (c) => {
  const [{ results: boards }, { results: total }] = await Promise.all([
    c.env.DB.prepare("SELECT board_token,name,platform,job_count,last_crawled_at FROM dim_board WHERE job_count>0 ORDER BY job_count DESC").all(),
    c.env.DB.prepare("SELECT COUNT(*) as n FROM fact_job_posting").all(),
  ]);
  return c.json({ total: (total[0] as { n: number }).n, boards });
});

// ── /api/jobs ────────────────────────────────────────────────────────────────
app.get("/api/jobs", async (c) => {
  const company = c.req.query("company");
  const skill   = c.req.query("skill");
  const q       = c.req.query("q")?.toLowerCase() ?? "";

  let sql: string;
  const params: string[] = [];

  if (skill) {
    sql = `SELECT DISTINCT f.job_post_id,f.title,f.location_name,f.location_type,
                  f.company_name,f.first_published,f.updated_at
           FROM fact_job_posting f
           JOIN bridge_job_skill b ON f.job_post_id=b.job_post_id
           JOIN dim_skill s ON b.skill_key=s.skill_key
           WHERE s.name=? ORDER BY f.company_name,f.title LIMIT 200`;
    params.push(skill);
  } else if (company) {
    sql = `SELECT job_post_id,title,location_name,location_type,company_name,first_published,updated_at
           FROM fact_job_posting WHERE company_name=? ORDER BY title LIMIT 200`;
    params.push(company);
  } else {
    sql = `SELECT job_post_id,title,location_name,location_type,company_name,first_published,updated_at
           FROM fact_job_posting ORDER BY company_name,title LIMIT 500`;
  }

  const stmt = params.length
    ? c.env.DB.prepare(sql).bind(...params)
    : c.env.DB.prepare(sql);

  const { results } = await stmt.all();
  return c.json({ jobs: results, total: results.length });
});

// ── /api/graph ────────────────────────────────────────────────────────────────
app.get("/api/graph", cache({ cacheName: "graph", cacheControl: "max-age=300" }), async (c) => {
  const [{ results: nodes }, { results: edges }] = await Promise.all([
    c.env.DB.prepare(
      `SELECT s.name,s.category,COUNT(*) as job_count
       FROM bridge_job_skill b JOIN dim_skill s ON b.skill_key=s.skill_key
       GROUP BY s.skill_key ORDER BY job_count DESC`
    ).all(),
    c.env.DB.prepare(
      `SELECT s1.name as source,s2.name as target,COUNT(*) as weight
       FROM bridge_job_skill a
       JOIN bridge_job_skill b ON a.job_post_id=b.job_post_id AND a.skill_key<b.skill_key
       JOIN dim_skill s1 ON a.skill_key=s1.skill_key
       JOIN dim_skill s2 ON b.skill_key=s2.skill_key
       GROUP BY a.skill_key,b.skill_key HAVING COUNT(*)>=15
       ORDER BY weight DESC LIMIT 80`
    ).all(),
  ]);
  return c.json({ nodes, edges });
});

// ── / (dashboard HTML) ────────────────────────────────────────────────────────
app.get("/", (c) => c.redirect("/index.html"));

export default app;
