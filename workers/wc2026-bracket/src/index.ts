/**
 * subagentjobs-wc2026  —  subagentdata.com
 *
 * World Cup 2026 Round-of-32 radial bracket. Built to the same design system as
 * workers/web (subagentjobs.com): TypeScript module Worker, D1-backed, server-
 * rendered HTML, terminal aesthetic (#0a0a0a / #51c4ff), and an A2A agent card.
 *
 * Storage : D1 `subagentjobs-dwh` — dim_team + fact_match (migrations/0001).
 * Auth    : Cloudflare Secrets Store binding UPDATE_SECRET (env.UPDATE_SECRET.get()).
 *
 * Routes:
 *   GET  /                          → server-rendered bracket + matches page
 *   GET  /api/bracket               → matches + r16 pairs + meta
 *   GET  /api/status                → summary counts + final results
 *   POST /api/update                → apply score/status deltas (Bearer secret)
 *   GET  /health                    → liveness
 *   GET  /.well-known/agent-card.json    → A2A discovery
 *   GET  /.well-known/agent-context.json → full worker + binding context for agents
 *   POST /a2a                       → A2A tasks/send → bracket artifact
 *   (cron) scheduled()              → autonomous score ingestion from SCORES_SOURCE_URL
 *
 * Autonomy: this Worker is designed to run agent-to-agent with no human in the
 * loop. agent-context.json (served live at /.well-known/agent-context.json)
 * gives any future Claude/A2A agent the complete binding + update context.
 */

import agentContext from './agent-context.json';
import { bracketGraph } from './layout';
export { bracketGraph } from './layout';

export interface Env {
  DB: D1Database;
  // Cloudflare Secrets Store binding — read with await env.UPDATE_SECRET.get()
  UPDATE_SECRET?: { get(): Promise<string> };
  // Autonomous ingestion source: scheduled() fetches this and applies deltas.
  SCORES_SOURCE_URL?: string;
}

// Match-delta shape accepted by /api/update and the scheduled ingester.
interface MatchDelta {
  id: string;
  status?: string;
  home_score?: number | null;
  away_score?: number | null;
  home_pens?: number | null; // penalty-shootout goals (winner/loser on a tie)
  away_pens?: number | null;
  winner?: string | null;
  winner_code?: string | null;
  note?: string | null;
}

// Apply score/status deltas to fact_match. Shared by POST /api/update (human or
// agent push) and scheduled() (autonomous cron). Returns the applied timestamp.
async function applyUpdates(env: Env, deltas: MatchDelta[]): Promise<{ updated: string; count: number }> {
  const now = new Date().toISOString();
  const stmts = deltas
    .filter((m) => typeof m?.id === 'string')
    .map((m) =>
      env.DB.prepare(
        `UPDATE fact_match
            SET status      = COALESCE(?, status),
                home_score  = ?,
                away_score  = ?,
                home_pens   = ?,
                away_pens   = ?,
                winner_code = ?,
                note        = ?,
                updated_at  = ?
          WHERE match_id = ?`
      ).bind(
        m.status ?? null,
        m.home_score ?? null,
        m.away_score ?? null,
        m.home_pens ?? null,
        m.away_pens ?? null,
        m.winner ?? m.winner_code ?? null,
        m.note ?? null,
        now,
        m.id
      )
    );
  if (stmts.length) await env.DB.batch(stmts);
  return { updated: now, count: stmts.length };
}

const cors = { 'access-control-allow-origin': '*' } as const;

const META = {
  stage: 'Round of 32',
  final_date: 'Jul 19, 2026',
  final_venue: 'MetLife Stadium',
} as const;

// ── Shaped match row ──────────────────────────────────────────────────────────
export interface Side { c: string; n: string; f: string }
export interface ShapedMatch {
  id: string;
  seq: number;
  status: string;
  date: string | null;
  venue: string | null;
  home: Side;
  away: Side;
  s: { h: number; a: number } | null;
  pk: { h: number; a: number } | null; // penalty-shootout score when a tie went to pens
  w: string | null;
  p: { h: number } | null;
  note: string | null;
}

// Load all matches joined to dim_team (home + away), ordered around the radial.
async function loadMatches(env: Env): Promise<ShapedMatch[]> {
  const { results } = await env.DB.prepare(
    `SELECT m.match_id, m.seq, m.status, m.match_date, m.venue,
            m.home_code, ht.name AS home_name, ht.flag AS home_flag,
            m.away_code, at.name AS away_name, at.flag AS away_flag,
            m.home_score, m.away_score, m.home_pens, m.away_pens, m.winner_code, m.prob_home, m.note
       FROM fact_match m
       JOIN dim_team ht ON m.home_code = ht.team_code
       JOIN dim_team at ON m.away_code = at.team_code
      ORDER BY m.seq`
  ).all<any>();

  return (results as any[]).map((r) => ({
    id: r.match_id,
    seq: r.seq,
    status: r.status,
    date: r.match_date,
    venue: r.venue,
    home: { c: r.home_code, n: r.home_name, f: r.home_flag },
    away: { c: r.away_code, n: r.away_name, f: r.away_flag },
    s: r.home_score != null && r.away_score != null ? { h: r.home_score, a: r.away_score } : null,
    pk: r.home_pens != null && r.away_pens != null ? { h: r.home_pens, a: r.away_pens } : null,
    w: r.winner_code ?? null,
    p: r.prob_home != null ? { h: r.prob_home } : null,
    note: r.note ?? null,
  }));
}

// Group match ids by r16_group into [idA, idB] tuples (winners meet in R16).
async function loadR16(env: Env): Promise<[string, string][]> {
  const { results } = await env.DB.prepare(
    `SELECT r16_group AS g, match_id FROM fact_match ORDER BY r16_group, seq`
  ).all<any>();
  const groups = new Map<number, string[]>();
  for (const r of results as any[]) {
    const arr = groups.get(r.g) ?? [];
    arr.push(r.match_id);
    groups.set(r.g, arr);
  }
  const pairs: [string, string][] = [];
  for (const arr of groups.values()) if (arr.length === 2) pairs.push([arr[0], arr[1]]);
  return pairs;
}

async function bracketPayload(env: Env) {
  const [matches, r16, upd] = await Promise.all([
    loadMatches(env),
    loadR16(env),
    env.DB.prepare(`SELECT MAX(updated_at) AS u FROM fact_match`).first<{ u: string | null }>(),
  ]);
  // Symmetric radial tree positions (d3-hierarchy), computed server-side.
  const graph = bracketGraph(matches, r16);
  return { matches, r16, graph, meta: { updated: upd?.u ?? null, ...META } };
}

const countBy = (ms: ShapedMatch[], st: string) => ms.filter((m) => m.status === st).length;
const finalLine = (m: ShapedMatch) =>
  `${m.home.c}${m.s ? ` ${m.s.h}-${m.s.a}` : ''}${m.pk ? ` pens ${m.pk.h}-${m.pk.a}` : ''} vs ${m.away.c}${m.w ? ` W:${m.w}` : ''}${m.note ? ` (${m.note})` : ''}`;

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const u = new URL(req.url);

    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });

    // ── /api/bracket ──────────────────────────────────────────────────────────
    if (u.pathname === '/api/bracket') {
      const payload = await bracketPayload(env);
      return Response.json(payload, {
        headers: { ...cors, 'cache-control': 'public,max-age=30,stale-while-revalidate=60' },
      });
    }

    // ── /api/status ───────────────────────────────────────────────────────────
    if (u.pathname === '/api/status') {
      const [matches, upd] = await Promise.all([
        loadMatches(env),
        env.DB.prepare(`SELECT MAX(updated_at) AS u FROM fact_match`).first<{ u: string | null }>(),
      ]);
      return Response.json({
        updated: upd?.u ?? null,
        done: countBy(matches, 'final'),
        live: countBy(matches, 'in_progress'),
        upcoming: countBy(matches, 'scheduled'),
        total: matches.length,
        results: matches.filter((m) => m.status === 'final').map(finalLine),
      }, { headers: cors });
    }

    // ── POST /api/update ──────────────────────────────────────────────────────
    if (u.pathname === '/api/update' && req.method === 'POST') {
      let secret = '';
      try { secret = (await env.UPDATE_SECRET?.get()) ?? ''; } catch { secret = ''; }
      const auth = req.headers.get('Authorization') || '';
      if (secret && auth !== `Bearer ${secret}`) {
        return Response.json({ error: 'unauthorized' }, { status: 401, headers: cors });
      }

      let body: any;
      try { body = await req.json(); } catch { return Response.json({ error: 'invalid json' }, { status: 400, headers: cors }); }
      if (!Array.isArray(body?.matches)) {
        return Response.json({ error: 'missing matches[]' }, { status: 400, headers: cors });
      }

      const { updated, count } = await applyUpdates(env, body.matches as MatchDelta[]);
      const matches = await loadMatches(env);
      const by = (st: string) => matches.filter((m) => m.status === st).length;
      return Response.json({ ok: true, updated, applied: count, done: by('final'), live: by('in_progress') }, { headers: cors });
    }

    if (u.pathname === '/health') return Response.json({ ok: true, ts: Date.now() }, { headers: cors });

    // ── /.well-known/agent-context.json — full context for autonomous agents ──
    // The committed manifest augmented with live binding presence, so any future
    // Claude / A2A agent can self-serve worker + binding context with no human.
    if (u.pathname === '/.well-known/agent-context.json') {
      return Response.json({
        ...agentContext,
        live: {
          bindings: {
            DB: !!env.DB,
            UPDATE_SECRET: !!env.UPDATE_SECRET,
            SCORES_SOURCE_URL: !!env.SCORES_SOURCE_URL,
          },
          scores_source_configured: !!env.SCORES_SOURCE_URL,
        },
      }, { headers: cors });
    }

    // ── A2A agent card ────────────────────────────────────────────────────────
    if (u.pathname === '/.well-known/agent-card.json') {
      return Response.json({
        name: 'subagentdata-wc2026',
        version: '0.1.0',
        description: 'FIFA World Cup 2026 Round-of-32 bracket: live scores, fixtures and results.',
        url: 'https://subagentdata.com',
        documentationUrl: 'https://subagentdata.com/api/bracket',
        defaultInputModes: ['text/plain', 'application/json'],
        defaultOutputModes: ['application/json'],
        capabilities: { streaming: false, pushNotifications: false, stateTransitionHistory: false },
        // Pointer so peer agents can self-serve full binding/update context.
        contextUrl: 'https://subagentdata.com/.well-known/agent-context.json',
        skills: [
          {
            id: 'get_bracket',
            name: 'Get Bracket',
            description: 'Return the World Cup 2026 Round-of-32 bracket — matches, scores, statuses and R16 pairings.',
            tags: ['football', 'soccer', 'world-cup', 'wc2026', 'bracket'],
            examples: ['Show the World Cup round of 32', 'Which teams advanced?', 'Live World Cup scores'],
            inputModes: ['text/plain', 'application/json'],
            outputModes: ['application/json'],
          },
          {
            id: 'update_bracket',
            name: 'Update Bracket',
            description: 'Apply match score/status deltas. Agent-to-agent: POST {matches:[{id,status,home_score,away_score,winner,note}]} to /api/update (Bearer UPDATE_SECRET), or publish a JSON feed for the worker cron to ingest.',
            tags: ['football', 'wc2026', 'update', 'ingest', 'autonomous'],
            examples: ['Update M07 to 2-1 final, winner ENG', 'Push the latest live scores'],
            inputModes: ['application/json'],
            outputModes: ['application/json'],
          },
        ],
      }, { headers: cors });
    }

    // ── POST /a2a ─────────────────────────────────────────────────────────────
    if (u.pathname === '/a2a' && req.method === 'POST') {
      let b: any;
      try { b = await req.json(); } catch { b = {}; }
      const taskId = b?.params?.id ?? crypto.randomUUID();
      const payload = await bracketPayload(env);
      return Response.json({
        jsonrpc: '2.0',
        id: b?.id ?? null,
        result: {
          id: taskId,
          status: { state: 'completed' },
          artifacts: [{ name: 'wc2026_bracket', parts: [{ type: 'data', data: payload }] }],
        },
      }, { headers: cors });
    }

    // ── / dashboard ───────────────────────────────────────────────────────────
    const matches = await loadMatches(env);
    return new Response(page(matches), { headers: { 'content-type': 'text/html;charset=utf-8' } });
  },

  // ── Autonomous score ingestion (Cron Trigger) ──────────────────────────────
  // No human, no secret: fetch the agent-published SCORES_SOURCE_URL and apply
  // its {matches:[delta]} to D1. A no-op when the var is unset, so the cron is
  // safe to ship before a source exists.
  async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    const src = env.SCORES_SOURCE_URL;
    if (!src) return;
    ctx.waitUntil(
      (async () => {
        try {
          const r = await fetch(src, { headers: { accept: 'application/json' } });
          if (!r.ok) return;
          const body: any = await r.json();
          const deltas = Array.isArray(body?.matches) ? (body.matches as MatchDelta[]) : [];
          if (deltas.length) await applyUpdates(env, deltas);
        } catch {
          /* transient source/network error — next tick retries */
        }
      })()
    );
  },
};

// ── Shared CSS ────────────────────────────────────────────────────────────────
// Design tokens from workers/web, tokenised into CSS variables so the accent
// palette can be widened to Display-P3 on capable screens (iPhone 16 Pro is a
// P3 panel). Translucent variants use Chrome 150 relative-color syntax with an
// sRGB fallback declared first. prefers-reduced-motion + `contain` keep the
// 120 Hz ProMotion display from doing needless work.
function sharedCss(): string {
  return `
:root{
  --bg:#0a0a0a;--panel:#111;--line:#1f1f1f;--line2:#2a2a2a;
  --txt:#d4d4d4;--txt-hi:#f4f4f4;--mut:#6a6a6a;--dim:#3a3a3a;
  --cyan:#51c4ff;--green:#7bd88f;--amber:#f4a73b;--red:#f47067;
}
/* Display-P3 widening for wide-gamut screens (iPhone 16 Pro, modern Chrome). */
@supports (color: color(display-p3 1 1 1)){
  @media (color-gamut: p3){
    :root{
      --cyan:color(display-p3 0.30 0.76 1.00);
      --green:color(display-p3 0.46 0.85 0.53);
      --amber:color(display-p3 0.95 0.64 0.20);
      --red:color(display-p3 0.93 0.42 0.38);
    }
  }
}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html{color-scheme:dark}
html,body{margin:0;padding:0;
  font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;
  background:var(--bg);color:var(--txt);-webkit-font-smoothing:antialiased;font-size:13px}
/* SOTA typography: balanced headings + tidy wrapping (Chrome 114 / 117+).
   Ref: https://developer.chrome.com/blog/css-text-wrap-balance */
.sh .sl{text-wrap:balance}
.mteam .nm{text-wrap:pretty}
/* View Transitions tuning (Chrome 111+): quick cross-fade, disabled for reduced
   motion. Ref: https://developer.chrome.com/docs/web-platform/view-transitions/same-document */
::view-transition-old(root),::view-transition-new(root){animation-duration:.2s}
@media (prefers-reduced-motion: reduce){
  ::view-transition-group(*),::view-transition-old(*),::view-transition-new(*){animation:none!important}
}
#hdr{padding:10px 16px;padding-top:calc(10px + env(safe-area-inset-top));
  border-bottom:1px solid var(--line);display:flex;align-items:center;gap:12px;
  position:sticky;top:0;background:rgba(10,10,10,.94);
  backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);z-index:20}
#hdr h1{margin:0;font-size:14px;font-weight:600;letter-spacing:1px;color:var(--txt-hi)}
.hdr-meta{font-size:11px;color:var(--cyan)}
.hdr-badge{margin-left:auto;font-size:9px;text-transform:uppercase;letter-spacing:1px;
  border:1px solid var(--line2);padding:2px 7px;color:var(--mut)}
.hdr-badge.live{color:var(--red);border-color:#f4706744;border-color:rgb(from var(--red) r g b / .27)}
nav{display:flex;overflow-x:auto;border-bottom:1px solid var(--line);scrollbar-width:none;
  background:rgba(10,10,10,.94);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);
  position:sticky;top:calc(41px + env(safe-area-inset-top));z-index:19}
nav::-webkit-scrollbar{display:none}
nav a{padding:8px 14px;font-size:11px;color:var(--mut);text-decoration:none;white-space:nowrap;
  border-bottom:2px solid transparent;min-height:36px;display:flex;align-items:center;flex-shrink:0;
  background:none;border-left:none;border-right:none;border-top:none;font-family:inherit;cursor:pointer}
nav a.active,nav a:hover{color:var(--cyan);border-bottom-color:var(--cyan)}
main{padding:12px 16px;padding-bottom:calc(48px + env(safe-area-inset-bottom))}
.section{margin-bottom:24px}
.sh{display:flex;align-items:baseline;gap:10px;padding:6px 0;border-bottom:1px solid var(--line);margin-bottom:10px}
.sl{font-size:10px;text-transform:uppercase;letter-spacing:1px;font-weight:600;color:var(--cyan)}
.sl-m{color:var(--mut);font-weight:400}
.footer{text-align:center;padding:16px;font-size:10px;color:var(--dim);border-top:1px solid #1a1a1a}
.footer a{color:var(--cyan);text-decoration:none}
/* graph — SVG (crisp vectors, real DOM nodes, a11y). contain limits paint. */
#graph-wrap{height:min(86vw,460px);position:relative;border:1px solid var(--line2);
  background:var(--panel);overflow:hidden;contain:layout paint}
#svg{position:absolute;inset:0;width:100%;height:100%;touch-action:none;display:block}
.ring{fill:none;stroke:#141414;stroke-width:.25}.ring.out{stroke:#1c1c1c}
.lk{fill:none;stroke-linecap:round}
.crest{font-size:4px;text-anchor:middle;dominant-baseline:central}
.code{font-family:ui-monospace,monospace;font-weight:400;font-size:1.5px;text-anchor:middle;dominant-baseline:central}
.trophy{font-size:5.5px;text-anchor:middle;dominant-baseline:central}
.node{cursor:pointer}
.node .hit{fill:transparent}
.node .dot{stroke-width:.3}
.node .foc{fill:none;stroke:none}
.node:focus{outline:none}
.node:focus .foc,.node[data-sel] .foc{stroke:var(--cyan);stroke-width:.4}
.node .sc{font-family:ui-monospace,monospace;font-weight:600;font-size:2.1px;text-anchor:middle;dominant-baseline:central}
.node .sc.pk{font-size:1.7px}
.node.live .dot{animation:pdot 1.2s ease-in-out infinite}
@keyframes pdot{0%,100%{opacity:1}50%{opacity:.45}}
@media (prefers-reduced-motion:reduce){.node.live .dot{animation:none}}
/* focus+context match detail — CSS anchor positioning + @position-try */
#detail{display:block;position:fixed;margin:0;border:1px solid var(--line2);background:#0e0e0eee;color:var(--txt);
  backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border-radius:12px;padding:12px 14px;width:min(280px,86vw);z-index:6;
  position-anchor:--sel;top:anchor(bottom);left:anchor(center);translate:-50% 8px;inset:auto;
  position-try-fallbacks:flip-block,flip-inline,flip-block flip-inline}
@supports not (anchor-name:--x){#detail{left:50%;bottom:14px;top:auto;translate:-50% 0}}
#detail[hidden]{display:none}
#detail .dh{display:flex;justify-content:space-between;font-size:9px;letter-spacing:.08em;color:var(--mut);text-transform:uppercase;margin-bottom:8px}
#detail .dlive{color:var(--red)}
#detail .drow{display:flex;align-items:center;gap:8px;padding:3px 0;font-size:14px}
#detail .drow .fl{font-size:17px}.drow .nm{flex:1}.drow .dsc{font-weight:600;color:var(--cyan)}
#detail .drow .dsc .p{font-size:10px;font-weight:400;color:var(--mut);margin-left:1px}
#detail .drow[data-s=won] .nm{color:var(--cyan);font-weight:600}
#detail .drow[data-s=lost] .nm{color:var(--mut)}
#detail .dsep{height:1px;background:var(--line);margin:2px 0}
#detail .dnote{margin-top:8px;font-size:9px;color:var(--mut);text-transform:uppercase;letter-spacing:.08em}
#detail .dclose{position:absolute;top:5px;right:9px;color:var(--mut);background:none;border:none;font-size:15px;cursor:pointer}
.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}
.zc{position:absolute;right:8px;bottom:8px;display:flex;flex-direction:column;gap:6px;z-index:2}
.zc button{width:34px;height:34px;border:1px solid var(--line2);background:rgba(10,10,10,.72);
  color:var(--cyan);font-size:17px;line-height:1;font-family:var(--mono,inherit);border-radius:8px;cursor:pointer;
  backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);display:flex;align-items:center;justify-content:center;
  -webkit-tap-highlight-color:transparent;transition:border-color .15s,color .15s}
.zc button:hover,.zc button:active{border-color:var(--cyan);color:var(--txt-hi)}
.legend{display:flex;flex-wrap:wrap;gap:8px 14px;padding:10px 2px;font-size:9px;
  letter-spacing:.5px;color:var(--mut);text-transform:uppercase}
.leg{display:flex;align-items:center;gap:5px}.leg i{width:7px;height:7px;border-radius:50%;display:inline-block}
/* match cards */
.mcard{border:1px solid var(--line);background:var(--panel);padding:10px 12px;margin-bottom:8px;position:relative;
  content-visibility:auto;contain-intrinsic-size:auto 84px}
.mcard.live{border-color:#f4706744;border-color:rgb(from var(--red) r g b / .27);background:#160d0d}
.mcard.final{border-color:var(--line2)}
.mmeta{display:flex;justify-content:space-between;font-size:9px;letter-spacing:.5px;
  color:var(--mut);text-transform:uppercase;margin-bottom:8px}
.mteam{display:flex;align-items:center;gap:8px;padding:3px 0;font-size:13px}
.mteam .fl{font-size:16px;line-height:1}
.mteam .nm{flex:1;color:var(--txt)}
.mteam .sc{font-size:14px;font-weight:600;color:var(--cyan);min-width:16px;text-align:right}
.mteam .sc.dim{font-size:10px;color:var(--dim)}
.mteam .sc .pk{font-size:10px;font-weight:400;color:var(--mut);margin-left:1px;vertical-align:1px}
.mteam.won .nm{color:var(--cyan);font-weight:600}
.mteam.lost .nm{color:var(--mut)}
.msep{height:1px;background:var(--line);margin:2px 0}
.pbar{height:2px;background:var(--line);margin-top:9px;overflow:hidden}
.pfill{height:100%;background:var(--cyan);opacity:.6}
.pip{position:absolute;top:0;right:0;font-size:8px;letter-spacing:.5px;padding:2px 6px;text-transform:uppercase}
.pip.ft{background:#10262e;color:var(--cyan)}
.pip.lv{background:#2a0f0f;color:var(--red)}
.note{position:absolute;top:0;left:0;font-size:8px;letter-spacing:.5px;padding:2px 6px;
  background:#1a1a0d;color:var(--amber);text-transform:uppercase}
@media (prefers-reduced-motion: reduce){*{animation:none!important}}
`.trim();
}

// ── Server-rendered page ──────────────────────────────────────────────────────
// Exported so the render-preview harness (tests) can build the page offline.
export function page(matches: ShapedMatch[]): string {
  const done = matches.filter((m) => m.status === 'final').length;
  const live = matches.filter((m) => m.status === 'in_progress').length;

  const cards = matches.map((m) => {
    const fin = m.status === 'final';
    const lv = m.status === 'in_progress';
    const hWon = fin && m.w === m.home.c, hLost = fin && !hWon && m.w != null;
    const aWon = fin && m.w === m.away.c, aLost = fin && !aWon && m.w != null;
    const pkh = m.pk ? `<span class=pk>(${m.pk.h})</span>` : '';
    const pka = m.pk ? `<span class=pk>(${m.pk.a})</span>` : '';
    const hs = m.s ? `<span class=sc>${m.s.h}${pkh}</span>` : '<span class="sc dim">—</span>';
    const as = m.s ? `<span class=sc>${m.s.a}${pka}</span>` : '<span class="sc dim">—</span>';
    const pip = fin ? '<span class="pip ft">FT</span>' : lv ? '<span class="pip lv">live</span>' : '';
    const note = m.note ? `<span class=note>${esc(m.note)}</span>` : '';
    const prob = !fin && !lv && m.p
      ? `<div class=pbar><div class=pfill style="width:${Math.round(m.p.h)}%"></div></div>` : '';
    const meta = lv ? '<span style="color:#f47067">live</span>'
      : `<span>${esc(m.venue || '')}</span>`;
    return `<div class="mcard${fin ? ' final' : lv ? ' live' : ''}" id="card-${esc(m.id)}">${pip}${note}` +
      `<div class=mmeta><span>${esc(m.id)} · ${esc(m.date || '')}</span>${meta}</div>` +
      `<div class="mteam${hWon ? ' won' : hLost ? ' lost' : ''}"><span class=fl>${m.home.f}</span>` +
        `<span class=nm>${esc(m.home.n)}</span>${hs}</div>` +
      `<div class=msep></div>` +
      `<div class="mteam${aWon ? ' won' : aLost ? ' lost' : ''}"><span class=fl>${m.away.f}</span>` +
        `<span class=nm>${esc(m.away.n)}</span>${as}</div>${prob}</div>`;
  }).join('');

  // Client JS — array of strings, no nested template literals (workers/web style).
  // iPhone 16 Pro / Chrome optimisations:
  //  • Display-P3 + desynchronized 2D contexts (wide gamut, low latency).
  //  • DPR capped at 3 (the iPhone 16 Pro ratio) so absurd ratios can't blow up
  //    the backing store.
  //  • On-demand ("dirty") rendering — a continuous rAF runs ONLY while a match
  //    is live (the blinking node); otherwise we paint once and idle, so a
  //    120 Hz ProMotion panel isn't pinned at full rate. Pan/zoom/resize each
  //    schedule a single coalesced frame.
  //  • prefers-reduced-motion disables the blink loop entirely.
  const js = [
    // SVG rebuild (research-backed): the bracket is real DOM — crisp vectors at any
    // zoom/DPR, native tap targets + :focus, screen-reader text. The d3 symmetric
    // tree (DATA.graph) maps to SVG; pan/zoom transform one camera <g>, so nodes
    // stay addressable. P(ang,r) projects into the 0..100 viewBox.
    'var DATA=null,Z=1,px=0,py=0,LT=null,LD=null,LC=null,PINCH=false,MINZ=0.6,MAXZ=6,easeRAF=0,selId=null;',
    'var RM=(window.matchMedia&&matchMedia("(prefers-reduced-motion: reduce)").matches)||false;',
    'var SVGNS="http://www.w3.org/2000/svg";',
    'function svel(n,at){var e=document.createElementNS(SVGNS,n);for(var k in at)e.setAttribute(k,at[k]);return e;}',
    'function col(s){return s==="adv"?"#7bd88f":s==="live"?"#f47067":s==="up"?"#51c4ff":s==="elim"?"#2a2a2a":"#242424";}',
    'function lcol(s){return s==="adv"?"#15321f":s==="live"?"#3a0f0f":s==="up"?"#12222d":"#181818";}',
    'function fillc(s){return s==="live"?"#2a0f0f":s==="adv"?"#0f2417":"#111";}',
    'function P(ang,r){return [50+Math.cos(ang)*r*40,50+Math.sin(ang)*r*40];}',
    'function mById(id){if(!DATA)return null;for(var i=0;i<DATA.matches.length;i++)if(DATA.matches[i].id===id)return DATA.matches[i];return null;}',
    'function swapTab(name,el){',
    '  document.querySelectorAll("nav a").forEach(function(a){a.classList.remove("active");});',
    '  el.classList.add("active");',
    '  ["bracket","matches"].forEach(function(t){var s=document.getElementById("tab-"+t);if(s)s.style.display=(t===name?"":"none");});',
    '}',
    'function showTab(name,el){',
    '  if(RM||!document.startViewTransition){swapTab(name,el);return;}',
    '  document.startViewTransition(function(){swapTab(name,el);});',
    '}',
    'function loadGraph(){',
    '  fetch("/api/bracket").then(function(r){return r.json();}).then(function(d){',
    '    DATA=d;buildSVG();if(/^#M\\d\\d$/.test(location.hash))selectMatch(location.hash.slice(1));',
    '  });',
    '}',
    'function buildSVG(){',
    '  if(!DATA||!DATA.graph)return;',
    '  var LK=document.getElementById("g-links"),ND=document.getElementById("g-nodes"),SR=document.getElementById("srlist");',
    '  LK.textContent="";ND.textContent="";if(SR)SR.textContent="";var N=DATA.graph.nodes;',
    '  DATA.graph.links.forEach(function(L){var a=N[L[0]],b=N[L[1]];if(!a||!b)return;',
    '    var pb=P(b.ang,b.r),pa=P(a.ang,a.r),pm=P(b.ang,(a.r+b.r)*0.5);',
    '    LK.appendChild(svel("path",{"class":"lk",d:"M"+pb[0]+" "+pb[1]+"Q"+pm[0]+" "+pm[1]+" "+pa[0]+" "+pa[1],stroke:lcol(b.st),"stroke-width":b.k==="team"?0.5:0.7}));});',
    '  N.forEach(function(g){var p=P(g.ang,g.r);',
    '    if(g.k==="final"){var tr=svel("text",{"class":"trophy",x:50,y:50});tr.textContent="\\uD83C\\uDFC6";ND.appendChild(tr);return;}',
    '    if(g.k==="team"){var gg=svel("g",{"class":"tm"});',
    '      var fl=svel("text",{"class":"crest",x:p[0],y:p[1]});fl.textContent=g.flag;gg.appendChild(fl);',
    '      var d=Math.hypot(p[0]-50,p[1]-50)||1,ux=(p[0]-50)/d,uy=(p[1]-50)/d;',
    '      var cd=svel("text",{"class":"code",x:p[0]+ux*3.4,y:p[1]+uy*3.4,fill:g.st==="adv"?"#7bd88f":g.st==="elim"?"#333":"#8a8a8a"});cd.textContent=g.code;gg.appendChild(cd);',
    '      ND.appendChild(gg);return;}',
    '    var rad=g.k==="match"?(g.live?2.2:g.st==="adv"?2:1.6):g.k==="r16"?0.9:0.7;',
    '    var node=svel("g",{"class":"node"+(g.live?" live":"")});',
    '    if(g.mid){node.setAttribute("data-id",g.mid);node.setAttribute("tabindex","0");node.setAttribute("role","button");}',
    '    node.appendChild(svel("circle",{"class":"hit",cx:p[0],cy:p[1],r:3.6}));',
    '    node.appendChild(svel("circle",{"class":"foc",cx:p[0],cy:p[1],r:rad+1.3}));',
    '    node.appendChild(svel("circle",{"class":"dot",cx:p[0],cy:p[1],r:rad,fill:fillc(g.st),stroke:col(g.st)}));',
    '    if(g.k==="match"&&g.score){var sc=svel("text",{"class":"sc"+(g.score.indexOf("(")>=0?" pk":""),x:p[0],y:p[1],fill:g.live?"#f47067":"#51c4ff"});sc.textContent=g.score;node.appendChild(sc);}',
    '    if(g.mid){var m=mById(g.mid),lab=m?(m.home.n+" versus "+m.away.n+(m.s?" "+m.s.h+" "+m.s.a:"")):g.mid;',
    '      var ti=svel("title");ti.textContent=lab;node.appendChild(ti);node.setAttribute("aria-label",lab);',
    '      node.addEventListener("click",function(ev){ev.stopPropagation();selectMatch(g.mid);});',
    '      node.addEventListener("keydown",function(e){if(e.key==="Enter"||e.key===" "){e.preventDefault();selectMatch(g.mid);}});',
    '      if(SR){var li=document.createElement("li"),aa=document.createElement("a");aa.href="#"+g.mid;aa.textContent=lab;',
    '        aa.addEventListener("click",function(){selectMatch(g.mid);});li.appendChild(aa);SR.appendChild(li);}}',
    '    ND.appendChild(node);});',
    '  applyCam();',
    '}',
    'function fmtSc(v,pk){return v==null?"\\u2013":v+(pk!=null?"<span class=p>("+pk+")</span>":"");}',
    'function selectMatch(id){if(document.startViewTransition&&!RM)document.startViewTransition(function(){doSelect(id);});else doSelect(id);}',
    'function doSelect(id){var m=mById(id);if(!m)return;',
    '  var prev=document.querySelector(".node[data-sel]");if(prev){prev.removeAttribute("data-sel");prev.style.removeProperty("anchor-name");}',
    '  var node=document.querySelector(".node[data-id="+id+"]");',
    '  if(node){node.setAttribute("data-sel","");node.style.setProperty("anchor-name","--sel");}selId=id;',
    '  var d=document.getElementById("detail"),fin=m.status==="final",hW=fin&&m.w===m.home.c,aW=fin&&m.w===m.away.c;',
    '  d.innerHTML="<button class=dclose aria-label=close>\\u00d7</button>"+',
    '    "<div class=dh><span>"+m.id+" \\u00b7 "+(m.date||"")+"</span><span>"+(m.status==="in_progress"?"<b class=dlive>live</b>":(m.venue||""))+"</span></div>"+',
    '    "<div class=drow data-s="+(hW?"won":fin?"lost":"none")+"><span class=fl>"+m.home.f+"</span><span class=nm>"+m.home.n+"</span><span class=dsc>"+fmtSc(m.s?m.s.h:null,m.pk?m.pk.h:null)+"</span></div>"+',
    '    "<div class=dsep></div>"+',
    '    "<div class=drow data-s="+(aW?"won":fin?"lost":"none")+"><span class=fl>"+m.away.f+"</span><span class=nm>"+m.away.n+"</span><span class=dsc>"+fmtSc(m.s?m.s.a:null,m.pk?m.pk.a:null)+"</span></div>"+',
    '    (m.note?"<div class=dnote>"+m.note+"</div>":"");',
    '  d.querySelector(".dclose").addEventListener("click",deselect);d.hidden=false;',
    '  if(location.hash!=="#"+id)history.replaceState(null,"","#"+id);',
    '}',
    'function deselect(){var p=document.querySelector(".node[data-sel]");if(p){p.removeAttribute("data-sel");p.style.removeProperty("anchor-name");}',
    '  var d=document.getElementById("detail");if(d)d.hidden=true;selId=null;if(location.hash)history.replaceState(null,"",location.pathname);}',
    'function applyCam(){var c=document.getElementById("cam");if(c)c.setAttribute("transform","translate("+px+" "+py+") scale("+Z+")");}',
    'function clampZ(z){return Math.min(MAXZ,Math.max(MINZ,z));}',
    'function zoomAt(fx,fy,f){var nz=clampZ(Z*f),k=nz/Z;px=fx-k*(fx-px);py=fy-k*(fy-py);Z=nz;applyCam();}',
    'function glide(tz,tx,ty){if(easeRAF)cancelAnimationFrame(easeRAF);(function step(){var dz=tz-Z,dx=tx-px,dy=ty-py;',
    '  if(Math.abs(dz)<0.002&&Math.abs(dx)<0.1&&Math.abs(dy)<0.1){Z=tz;px=tx;py=ty;applyCam();easeRAF=0;return;}',
    '  Z+=dz*0.22;px+=dx*0.22;py+=dy*0.22;applyCam();easeRAF=requestAnimationFrame(step);})();}',
    'function resetView(){glide(1,0,0);deselect();}',
    'function interact(){var el=document.getElementById("graph-wrap");if(!el)return;',
    '  function vb(t){var r=el.getBoundingClientRect();return{x:(t.clientX-r.left)/r.width*100,y:(t.clientY-r.top)/r.height*100};}',
    '  function cen(ts){return{clientX:(ts[0].clientX+ts[1].clientX)/2,clientY:(ts[0].clientY+ts[1].clientY)/2};}',
    '  var lastTap=0;',
    '  el.addEventListener("touchstart",function(e){if(easeRAF){cancelAnimationFrame(easeRAF);easeRAF=0;}',
    '    if(e.touches.length===1){LT=vb(e.touches[0]);PINCH=false;var now=performance.now();if(now-lastTap<300){resetView();lastTap=0;}else lastTap=now;}',
    '    else if(e.touches.length===2){PINCH=true;LD=Math.hypot(e.touches[0].clientX-e.touches[1].clientX,e.touches[0].clientY-e.touches[1].clientY);LC=vb(cen(e.touches));}},{passive:true});',
    '  el.addEventListener("touchmove",function(e){if(e.touches.length===1&&LT&&!PINCH){var p=vb(e.touches[0]);px+=p.x-LT.x;py+=p.y-LT.y;LT=p;applyCam();}',
    '    else if(e.touches.length===2&&LD){var d=Math.hypot(e.touches[0].clientX-e.touches[1].clientX,e.touches[0].clientY-e.touches[1].clientY);var c=vb(cen(e.touches));',
    '      if(LC){px+=c.x-LC.x;py+=c.y-LC.y;}zoomAt(c.x,c.y,d/LD);LD=d;LC=c;}},{passive:true});',
    '  el.addEventListener("touchend",function(e){if(!e.touches.length)LT=null;LD=null;LC=null;if(e.touches.length<2)PINCH=false;},{passive:true});',
    '  el.addEventListener("wheel",function(e){e.preventDefault();if(easeRAF){cancelAnimationFrame(easeRAF);easeRAF=0;}var p=vb(e);zoomAt(p.x,p.y,Math.exp(-e.deltaY*0.0016));},{passive:false});',
    '  el.addEventListener("dblclick",function(e){e.preventDefault();var p=vb(e);glide(clampZ(Z*1.8),p.x-1.8*(p.x-px),p.y-1.8*(p.y-py));});',
    '  var svg=document.getElementById("svg");if(svg)svg.addEventListener("click",function(e){var t=e.target;if(t===svg||t.id==="cam"||(t.getAttribute&&(""+t.getAttribute("class")).indexOf("ring")>=0))deselect();});',
    '  document.querySelectorAll("[data-z]").forEach(function(b){b.addEventListener("click",function(ev){ev.stopPropagation();',
    '    if(b.dataset.z==="in")zoomAt(50,50,1.4);else if(b.dataset.z==="out")zoomAt(50,50,1/1.4);else resetView();});});',
    '}',
    'interact();loadGraph();',
  ].join('\n');

  return `<!DOCTYPE html>
<html lang=en>
<head>
<meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name=theme-color content=#0a0a0a>
<title>subagentdata · wc2026</title>
<style>
${sharedCss()}
</style>
</head>
<body>
<div id=hdr>
  <h1>subagentdata</h1>
  <span class=hdr-meta>wc2026</span>
  <span class="hdr-badge${live ? ' live' : ''}">${live ? 'live' : 'r32'}</span>
</div>
<nav>
  <a class=active data-t=bracket onclick="showTab('bracket',this);return false">bracket</a>
  <a data-t=matches onclick="showTab('matches',this);return false">matches</a>
  <a href=https://coworkers.subagentknowledge.com target=_blank style="margin-left:auto">coworkers ↗</a>
</nav>
<main>

<section id=tab-bracket>
  <div class=section>
    <div class=sh>
      <span class=sl>round of 32</span>
      <span class="sl sl-m" style="margin-left:auto">${done} done${live ? ' · ' + live + ' live' : ''} · pinch · scroll · 2× tap</span>
    </div>
    <div id=graph-wrap>
      <svg id=svg viewBox="0 0 100 100" role=group aria-label="World Cup 2026 round of 32 radial bracket" preserveAspectRatio="xMidYMid meet">
        <g id=cam>
          <circle class=ring cx=50 cy=50 r=8></circle><circle class=ring cx=50 cy=50 r=16></circle><circle class=ring cx=50 cy=50 r=24></circle><circle class=ring cx=50 cy=50 r=32></circle><circle class="ring out" cx=50 cy=50 r=40></circle>
          <g id=g-links></g><g id=g-nodes></g>
        </g>
      </svg>
      <div class=zc>
        <button data-z=in aria-label="zoom in">+</button>
        <button data-z=out aria-label="zoom out">−</button>
        <button data-z=reset aria-label="reset view">⤢</button>
      </div>
      <dialog id=detail aria-label="match detail" hidden></dialog>
    </div>
    <div class=legend>
      <span class=leg><i style="background:#51c4ff"></i>upcoming</span>
      <span class=leg><i style="background:#7bd88f"></i>advanced</span>
      <span class=leg><i style="background:#f47067"></i>live</span>
      <span class=leg><i style="background:#3a3a3a"></i>eliminated</span>
    </div>
    <ul class=sr id=srlist aria-label="all matches"></ul>
  </div>
</section>

<section id=tab-matches style=display:none>
  <div class=section>
    <div class=sh>
      <span class=sl>all matches</span>
      <span class="sl sl-m" style="margin-left:auto">${matches.length}</span>
    </div>
    ${cards}
  </div>
</section>

</main>
<div class=footer>
  <a href=/api/bracket>bracket api</a> · <a href=/api/status>status api</a> · <a href=/.well-known/agent-card.json>a2a</a>
</div>
<script>${js}</script>
</body>
</html>`;
}

function esc(s: string): string {
  return (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
