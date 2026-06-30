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
                winner_code = ?,
                note        = ?,
                updated_at  = ?
          WHERE match_id = ?`
      ).bind(
        m.status ?? null,
        m.home_score ?? null,
        m.away_score ?? null,
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
interface Side { c: string; n: string; f: string }
interface ShapedMatch {
  id: string;
  seq: number;
  status: string;
  date: string | null;
  venue: string | null;
  home: Side;
  away: Side;
  s: { h: number; a: number } | null;
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
            m.home_score, m.away_score, m.winner_code, m.prob_home, m.note
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
  return { matches, r16, meta: { updated: upd?.u ?? null, ...META } };
}

const countBy = (ms: ShapedMatch[], st: string) => ms.filter((m) => m.status === st).length;
const finalLine = (m: ShapedMatch) =>
  `${m.home.c}${m.s ? ` ${m.s.h}-${m.s.a}` : ''} vs ${m.away.c}${m.w ? ` W:${m.w}` : ''}${m.note ? ` (${m.note})` : ''}`;

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
/* graph — contain limits layout/paint to the canvas box */
#graph-wrap{height:min(78vw,440px);position:relative;border:1px solid var(--line2);
  background:var(--panel);overflow:hidden;contain:layout paint}
#gcanvas,#lcanvas{position:absolute;top:0;left:0;width:100%;height:100%}
#gcanvas{touch-action:none}#lcanvas{pointer-events:none}
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
    const hs = m.s ? `<span class=sc>${m.s.h}</span>` : '<span class="sc dim">—</span>';
    const as = m.s ? `<span class=sc>${m.s.a}</span>` : '<span class="sc dim">—</span>';
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
    'var DATA=null,nodes=[],pan={x:0,y:0};',
    'var Z=1,LT=null,LD=null,PINCH=false;',
    'var GW=0,GH=0,DPR=1,gctx=null,lctx=null,pending=false,blinkRAF=0;',
    'var RM=(window.matchMedia&&matchMedia("(prefers-reduced-motion: reduce)").matches)||false;',
    'function ctx2d(c){try{return c.getContext("2d",{desynchronized:true,colorSpace:"display-p3"});}',
    '  catch(e){try{return c.getContext("2d",{desynchronized:true});}catch(e2){return c.getContext("2d");}}}',
    'function hasLive(){return !!(DATA&&DATA.matches.some(function(m){return m.status==="in_progress";}));}',
    'function blinkV(){return RM?1:(0.5+0.5*Math.sin((performance.now()/1000)*Math.PI*1.2));}',
    'function swapTab(name,el){',
    '  document.querySelectorAll("nav a").forEach(function(a){a.classList.remove("active");});',
    '  el.classList.add("active");',
    '  ["bracket","matches"].forEach(function(t){',
    '    var s=document.getElementById("tab-"+t);if(s)s.style.display=(t===name?"":"none");',
    '  });',
    '  if(name==="bracket"){resize();startBlink();}',
    '}',
    // SOTA: View Transitions API (same-document, Chrome 111+) cross-fades tabs.
    // Feature-detected + skipped under reduced-motion.
    // Ref: https://developer.chrome.com/docs/web-platform/view-transitions/same-document
    'function showTab(name,el){',
    '  if(RM||!document.startViewTransition){swapTab(name,el);return;}',
    '  document.startViewTransition(function(){swapTab(name,el);});',
    '}',
    'function loadGraph(){',
    '  fetch("/api/bracket").then(function(r){return r.json();}).then(function(d){',
    '    DATA=d;resize();startBlink();',
    '  });',
    '}',
    'function gn(id){for(var i=0;i<nodes.length;i++)if(nodes[i].id===id)return nodes[i];return null;}',
    'function build(W,H){',
    '  if(!DATA)return;nodes=[];',
    '  var cx=W/2,cy=H/2,R=Math.min(W,H)*0.38,M=DATA.matches,n=M.length;',
    '  for(var i=0;i<n;i++){',
    '    var m=M[i],ang=(i/n)*Math.PI*2-Math.PI/2;',
    '    nodes.push({id:m.id,ang:ang,x:cx+Math.cos(ang)*R,y:cy+Math.sin(ang)*R,m:m,',
    '      done:m.status==="final",live:m.status==="in_progress",sz:m.status==="final"?8:m.status==="in_progress"?10:6});',
    '  }',
    '}',
    'function draw(W,H,blink){',
    '  if(!gctx)return;gctx.clearRect(0,0,W*DPR,H*DPR);',
    '  gctx.save();gctx.scale(DPR,DPR);gctx.translate(pan.x,pan.y);gctx.scale(Z,Z);',
    '  var cx=W/2,cy=H/2,R=Math.min(W,H)*0.38;',
    '  gctx.beginPath();gctx.arc(cx,cy,R,0,Math.PI*2);gctx.strokeStyle="#1f1f1f";gctx.lineWidth=1;gctx.stroke();',
    '  gctx.beginPath();gctx.arc(cx,cy,R*0.62,0,Math.PI*2);gctx.strokeStyle="#161616";gctx.setLineDash([2,6]);gctx.stroke();gctx.setLineDash([]);',
    '  if(DATA.r16)DATA.r16.forEach(function(p){',
    '    var a=gn(p[0]),b=gn(p[1]);if(!a||!b)return;var Rr=R*0.62,d=b.ang-a.ang;',
    '    if(d>Math.PI)d-=Math.PI*2;if(d<-Math.PI)d+=Math.PI*2;',
    '    gctx.beginPath();d>=0?gctx.arc(cx,cy,Rr,a.ang,a.ang+d):gctx.arc(cx,cy,Rr,a.ang,a.ang+d,true);',
    '    gctx.strokeStyle="#13241a";gctx.lineWidth=1.5;gctx.stroke();',
    '  });',
    '  nodes.forEach(function(nd){',
    '    gctx.beginPath();gctx.moveTo(cx,cy);gctx.lineTo(nd.x,nd.y);',
    '    gctx.strokeStyle=nd.done?"#15321f":nd.live?"#2a0f0f":"#161616";gctx.lineWidth=1;gctx.stroke();',
    '  });',
    '  nodes.forEach(function(nd){',
    '    var a=nd.live?(0.55+0.45*blink):1;gctx.globalAlpha=a;',
    '    gctx.beginPath();gctx.arc(nd.x,nd.y,nd.sz,0,Math.PI*2);',
    '    gctx.fillStyle=nd.live?"#2a0f0f":nd.done?"#0f2417":"#111";gctx.fill();',
    '    gctx.strokeStyle=nd.live?"#f47067":nd.done?"#7bd88f":"#51c4ff";gctx.lineWidth=1.2;gctx.stroke();',
    '    gctx.globalAlpha=1;',
    '  });',
    '  gctx.restore();',
    '}',
    'function labels(W,H){',
    '  if(!lctx)return;var x=lctx;x.clearRect(0,0,W*DPR,H*DPR);',
    '  x.save();x.scale(DPR,DPR);var cx=W/2,cy=H/2,R=Math.min(W,H)*0.38;',
    '  x.textAlign="center";x.textBaseline="middle";',
    '  x.font="18px serif";x.fillText("\\uD83C\\uDFC6",cx+pan.x,cy+pan.y-4);',
    '  x.font="300 6px ui-monospace,monospace";x.fillStyle="#3a3a3a";',
    '  x.fillText("FINAL \\u00b7 JUL 19",cx+pan.x,cy+pan.y+11);',
    '  nodes.forEach(function(nd){',
    '    var m=nd.m,lr=R*Z+24,lx=cx*Z+pan.x+Math.cos(nd.ang)*lr,ly=cy*Z+pan.y+Math.sin(nd.ang)*lr;',
    '    var perp=nd.ang+Math.PI/2,off=9;',
    '    var hW=nd.done&&m.w===m.home.c,aW=nd.done&&m.w===m.away.c;',
    '    x.font="300 8px ui-monospace,monospace";',
    '    x.fillStyle=hW?"#51c4ff":nd.done?"#2a2a2a":"#6a6a6a";',
    '    x.fillText(m.home.f+" "+m.home.c,lx+Math.cos(perp)*off,ly+Math.sin(perp)*off);',
    '    x.fillStyle=aW?"#51c4ff":nd.done?"#2a2a2a":"#6a6a6a";',
    '    x.fillText(m.away.f+" "+m.away.c,lx-Math.cos(perp)*off,ly-Math.sin(perp)*off);',
    '    if((nd.done||nd.live)&&m.s){',
    '      x.font="600 "+(nd.sz*Z*0.85)+"px ui-monospace,monospace";',
    '      x.fillStyle=nd.done?"#51c4ff":"#f47067";',
    '      x.fillText(m.s.h+"-"+m.s.a,nd.x*Z+pan.x,nd.y*Z+pan.y);',
    '    }',
    '  });',
    '  x.restore();',
    '}',
    // Node layout depends only on DATA + canvas size, so build() runs in resize()
    // /loadGraph — not per frame. render() (called on every blink/pan/zoom frame)
    // just redraws.
    'function render(blink){if(!DATA||!GW)return;draw(GW,GH,blink==null?blinkV():blink);labels(GW,GH);}',
    // coalesce on-demand draws into a single rAF
    'function schedule(){if(pending)return;pending=true;requestAnimationFrame(function(){pending=false;render();});}',
    // continuous loop ONLY while a match is live; self-terminates otherwise
    'function startBlink(){if(RM||blinkRAF||!hasLive())return;',
    '  (function f(){if(!hasLive()){blinkRAF=0;render(1);return;}render();blinkRAF=requestAnimationFrame(f);})();}',
    'function resize(){',
    '  var w=document.getElementById("graph-wrap");if(!w||w.offsetParent===null)return;',
    '  GW=w.clientWidth;GH=w.clientHeight;DPR=Math.min(window.devicePixelRatio||1,3);',
    '  var gc=document.getElementById("gcanvas"),lc=document.getElementById("lcanvas");',
    '  gc.width=Math.round(GW*DPR);gc.height=Math.round(GH*DPR);gc.style.width=GW+"px";gc.style.height=GH+"px";',
    '  lc.width=Math.round(GW*DPR);lc.height=Math.round(GH*DPR);lc.style.width=GW+"px";lc.style.height=GH+"px";',
    '  gctx=ctx2d(gc);lctx=ctx2d(lc);build(GW,GH);render();',
    '}',
    'function interact(){',
    '  var el=document.getElementById("graph-wrap");if(!el)return;',
    '  el.addEventListener("touchstart",function(e){',
    '    if(e.touches.length===1){LT={x:e.touches[0].clientX,y:e.touches[0].clientY};PINCH=false;}',
    '    else if(e.touches.length===2){PINCH=true;LD=Math.hypot(e.touches[0].clientX-e.touches[1].clientX,e.touches[0].clientY-e.touches[1].clientY);}',
    '  },{passive:true});',
    '  el.addEventListener("touchmove",function(e){',
    '    if(e.touches.length===1&&LT&&!PINCH){pan.x+=e.touches[0].clientX-LT.x;pan.y+=e.touches[0].clientY-LT.y;LT={x:e.touches[0].clientX,y:e.touches[0].clientY};schedule();}',
    '    else if(e.touches.length===2&&LD){var d=Math.hypot(e.touches[0].clientX-e.touches[1].clientX,e.touches[0].clientY-e.touches[1].clientY);Z=Math.min(3,Math.max(0.4,Z*(d/LD)));LD=d;schedule();}',
    '  },{passive:true});',
    '  el.addEventListener("touchend",function(){LT=null;LD=null;},{passive:true});',
    '  el.addEventListener("click",function(e){',
    '    var r=el.getBoundingClientRect(),mx=((e.clientX-r.left)-pan.x)/Z,my=((e.clientY-r.top)-pan.y)/Z;',
    '    var hit=null;for(var i=0;i<nodes.length;i++){if(Math.hypot(nodes[i].x-mx,nodes[i].y-my)<16){hit=nodes[i];break;}}',
    '    if(hit){var nav=document.querySelector(\'nav a[data-t="matches"]\');showTab("matches",nav);',
    '      setTimeout(function(){var c=document.getElementById("card-"+hit.id);if(c)c.scrollIntoView({behavior:"smooth",block:"center"});},60);}',
    '  });',
    '  window.addEventListener("resize",function(){clearTimeout(window._r);window._r=setTimeout(function(){resize();startBlink();},80);});',
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
      <span class="sl sl-m" style="margin-left:auto">${done} done${live ? ' · ' + live + ' live' : ''} · pinch to zoom</span>
    </div>
    <div id=graph-wrap><canvas id=gcanvas></canvas><canvas id=lcanvas></canvas></div>
    <div class=legend>
      <span class=leg><i style="background:#51c4ff"></i>upcoming</span>
      <span class=leg><i style="background:#7bd88f"></i>advanced</span>
      <span class=leg><i style="background:#f47067"></i>live</span>
      <span class=leg><i style="background:#3a3a3a"></i>eliminated</span>
    </div>
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
