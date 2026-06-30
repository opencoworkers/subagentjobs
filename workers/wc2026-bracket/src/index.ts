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
 *   GET  /.well-known/agent-card.json → A2A discovery
 *   POST /a2a                       → A2A tasks/send → bracket artifact
 */

export interface Env {
  DB: D1Database;
  // Cloudflare Secrets Store binding — read with await env.UPDATE_SECRET.get()
  UPDATE_SECRET?: { get(): Promise<string> };
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
      const matches = await loadMatches(env);
      const upd = await env.DB.prepare(`SELECT MAX(updated_at) AS u FROM fact_match`).first<{ u: string | null }>();
      const by = (st: string) => matches.filter((m) => m.status === st);
      return Response.json({
        updated: upd?.u ?? null,
        done: by('final').length,
        live: by('in_progress').length,
        upcoming: by('scheduled').length,
        total: matches.length,
        results: by('final').map(
          (m) =>
            m.home.c +
            (m.s ? ` ${m.s.h}-${m.s.a}` : '') +
            ` vs ${m.away.c}` +
            (m.w ? ` W:${m.w}` : '') +
            (m.note ? ` (${m.note})` : '')
        ),
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

      const now = new Date().toISOString();
      const stmts = (body.matches as any[])
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

      const matches = await loadMatches(env);
      const by = (st: string) => matches.filter((m) => m.status === st).length;
      return Response.json({ ok: true, updated: now, done: by('final'), live: by('in_progress') }, { headers: cors });
    }

    if (u.pathname === '/health') return Response.json({ ok: true, ts: Date.now() }, { headers: cors });

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
};

// ── Shared CSS (design tokens copied from workers/web) ─────────────────────────
function sharedCss(): string {
  return `
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;padding:0;
  font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;
  background:#0a0a0a;color:#d4d4d4;-webkit-font-smoothing:antialiased;font-size:13px}
#hdr{padding:10px 16px;padding-top:calc(10px + env(safe-area-inset-top));
  border-bottom:1px solid #1f1f1f;display:flex;align-items:center;gap:12px;
  position:sticky;top:0;background:rgba(10,10,10,.94);
  backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);z-index:20}
#hdr h1{margin:0;font-size:14px;font-weight:600;letter-spacing:1px;color:#f4f4f4}
.hdr-meta{font-size:11px;color:#51c4ff}
.hdr-badge{margin-left:auto;font-size:9px;text-transform:uppercase;letter-spacing:1px;
  border:1px solid #2a2a2a;padding:2px 7px;color:#6a6a6a}
.hdr-badge.live{color:#f47067;border-color:#f4706744}
nav{display:flex;overflow-x:auto;border-bottom:1px solid #1f1f1f;scrollbar-width:none;
  background:rgba(10,10,10,.94);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);
  position:sticky;top:calc(41px + env(safe-area-inset-top));z-index:19}
nav::-webkit-scrollbar{display:none}
nav a{padding:8px 14px;font-size:11px;color:#6a6a6a;text-decoration:none;white-space:nowrap;
  border-bottom:2px solid transparent;min-height:36px;display:flex;align-items:center;flex-shrink:0;
  background:none;border-left:none;border-right:none;border-top:none;font-family:inherit;cursor:pointer}
nav a.active,nav a:hover{color:#51c4ff;border-bottom-color:#51c4ff}
main{padding:12px 16px;padding-bottom:calc(48px + env(safe-area-inset-bottom))}
.section{margin-bottom:24px}
.sh{display:flex;align-items:baseline;gap:10px;padding:6px 0;border-bottom:1px solid #1f1f1f;margin-bottom:10px}
.sl{font-size:10px;text-transform:uppercase;letter-spacing:1px;font-weight:600;color:#51c4ff}
.sl-m{color:#6a6a6a;font-weight:400}
.footer{text-align:center;padding:16px;font-size:10px;color:#3a3a3a;border-top:1px solid #1a1a1a}
.footer a{color:#51c4ff;text-decoration:none}
/* graph */
#graph-wrap{height:min(78vw,440px);position:relative;border:1px solid #2a2a2a;background:#111;overflow:hidden}
#gcanvas,#lcanvas{position:absolute;top:0;left:0;width:100%;height:100%}
#gcanvas{touch-action:none}#lcanvas{pointer-events:none}
.legend{display:flex;flex-wrap:wrap;gap:8px 14px;padding:10px 2px;font-size:9px;
  letter-spacing:.5px;color:#6a6a6a;text-transform:uppercase}
.leg{display:flex;align-items:center;gap:5px}.leg i{width:7px;height:7px;border-radius:50%;display:inline-block}
/* match cards */
.mcard{border:1px solid #1f1f1f;background:#111;padding:10px 12px;margin-bottom:8px;position:relative}
.mcard.live{border-color:#f4706744;background:#160d0d}
.mcard.final{border-color:#2a2a2a}
.mmeta{display:flex;justify-content:space-between;font-size:9px;letter-spacing:.5px;
  color:#6a6a6a;text-transform:uppercase;margin-bottom:8px}
.mteam{display:flex;align-items:center;gap:8px;padding:3px 0;font-size:13px}
.mteam .fl{font-size:16px;line-height:1}
.mteam .nm{flex:1;color:#d4d4d4}
.mteam .sc{font-size:14px;font-weight:600;color:#51c4ff;min-width:16px;text-align:right}
.mteam .sc.dim{font-size:10px;color:#3a3a3a}
.mteam.won .nm{color:#51c4ff;font-weight:600}
.mteam.lost .nm{color:#6a6a6a}
.msep{height:1px;background:#1f1f1f;margin:2px 0}
.pbar{height:2px;background:#1f1f1f;margin-top:9px;overflow:hidden}
.pfill{height:100%;background:#51c4ff;opacity:.6}
.pip{position:absolute;top:0;right:0;font-size:8px;letter-spacing:.5px;padding:2px 6px;text-transform:uppercase}
.pip.ft{background:#10262e;color:#51c4ff}
.pip.lv{background:#2a0f0f;color:#f47067}
.note{position:absolute;top:0;left:0;font-size:8px;letter-spacing:.5px;padding:2px 6px;
  background:#1a1a0d;color:#f4a73b;text-transform:uppercase}
`.trim();
}

// ── Server-rendered page ──────────────────────────────────────────────────────
function page(matches: ShapedMatch[]): string {
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
  const js = [
    'var DATA=null,nodes=[],pan={x:0,y:0};',
    'var Z=1,LT=null,LD=null,PINCH=false;',
    'function showTab(name,el){',
    '  document.querySelectorAll("nav a").forEach(function(a){a.classList.remove("active");});',
    '  el.classList.add("active");',
    '  ["bracket","matches"].forEach(function(t){',
    '    var s=document.getElementById("tab-"+t);if(s)s.style.display=(t===name?"":"none");',
    '  });',
    '  if(name==="bracket"){requestAnimationFrame(resize);}',
    '}',
    'function loadGraph(){',
    '  fetch("/api/bracket").then(function(r){return r.json();}).then(function(d){',
    '    DATA=d;resize();',
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
    '  var c=document.getElementById("gcanvas"),ctx=c.getContext("2d");if(!ctx)return;',
    '  var dpr=window.devicePixelRatio||1;ctx.clearRect(0,0,W*dpr,H*dpr);',
    '  ctx.save();ctx.scale(dpr,dpr);ctx.translate(pan.x,pan.y);ctx.scale(Z,Z);',
    '  var cx=W/2,cy=H/2,R=Math.min(W,H)*0.38;',
    '  ctx.beginPath();ctx.arc(cx,cy,R,0,Math.PI*2);ctx.strokeStyle="#1f1f1f";ctx.lineWidth=1;ctx.stroke();',
    '  ctx.beginPath();ctx.arc(cx,cy,R*0.62,0,Math.PI*2);ctx.strokeStyle="#161616";ctx.setLineDash([2,6]);ctx.stroke();ctx.setLineDash([]);',
    '  if(DATA.r16)DATA.r16.forEach(function(p){',
    '    var a=gn(p[0]),b=gn(p[1]);if(!a||!b)return;var Rr=R*0.62,d=b.ang-a.ang;',
    '    if(d>Math.PI)d-=Math.PI*2;if(d<-Math.PI)d+=Math.PI*2;',
    '    ctx.beginPath();d>=0?ctx.arc(cx,cy,Rr,a.ang,a.ang+d):ctx.arc(cx,cy,Rr,a.ang,a.ang+d,true);',
    '    ctx.strokeStyle="#13241a";ctx.lineWidth=1.5;ctx.stroke();',
    '  });',
    '  nodes.forEach(function(nd){',
    '    ctx.beginPath();ctx.moveTo(cx,cy);ctx.lineTo(nd.x,nd.y);',
    '    ctx.strokeStyle=nd.done?"#15321f":nd.live?"#2a0f0f":"#161616";ctx.lineWidth=1;ctx.stroke();',
    '  });',
    '  nodes.forEach(function(nd){',
    '    var a=nd.live?(0.55+0.45*blink):1;ctx.globalAlpha=a;',
    '    ctx.beginPath();ctx.arc(nd.x,nd.y,nd.sz,0,Math.PI*2);',
    '    ctx.fillStyle=nd.live?"#2a0f0f":nd.done?"#0f2417":"#111";ctx.fill();',
    '    ctx.strokeStyle=nd.live?"#f47067":nd.done?"#7bd88f":"#51c4ff";ctx.lineWidth=1.2;ctx.stroke();',
    '    ctx.globalAlpha=1;',
    '  });',
    '  ctx.restore();',
    '}',
    'function labels(W,H){',
    '  var lc=document.getElementById("lcanvas"),x=lc.getContext("2d");',
    '  var dpr=window.devicePixelRatio||1;x.clearRect(0,0,W*dpr,H*dpr);',
    '  x.save();x.scale(dpr,dpr);var cx=W/2,cy=H/2,R=Math.min(W,H)*0.38;',
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
    'function render(W,H,blink){if(!DATA)return;build(W,H);draw(W,H,blink||0.8);labels(W,H);}',
    'function resize(){',
    '  var w=document.getElementById("graph-wrap");if(!w)return;',
    '  var W=w.clientWidth,H=w.clientHeight,dpr=window.devicePixelRatio||1;',
    '  ["gcanvas","lcanvas"].forEach(function(id){',
    '    var c=document.getElementById(id);c.width=Math.round(W*dpr);c.height=Math.round(H*dpr);',
    '    c.style.width=W+"px";c.style.height=H+"px";',
    '  });render(W,H);',
    '}',
    'function loop(t){',
    '  var blink=0.5+0.5*Math.sin((t/1000)*Math.PI*1.2);',
    '  var w=document.getElementById("graph-wrap");',
    '  if(w&&w.offsetParent!==null&&DATA)render(w.clientWidth,w.clientHeight,blink);',
    '  requestAnimationFrame(loop);',
    '}',
    'function interact(){',
    '  var el=document.getElementById("graph-wrap");if(!el)return;',
    '  el.addEventListener("touchstart",function(e){',
    '    if(e.touches.length===1){LT={x:e.touches[0].clientX,y:e.touches[0].clientY};PINCH=false;}',
    '    else if(e.touches.length===2){PINCH=true;LD=Math.hypot(e.touches[0].clientX-e.touches[1].clientX,e.touches[0].clientY-e.touches[1].clientY);}',
    '  },{passive:true});',
    '  el.addEventListener("touchmove",function(e){',
    '    if(e.touches.length===1&&LT&&!PINCH){pan.x+=e.touches[0].clientX-LT.x;pan.y+=e.touches[0].clientY-LT.y;LT={x:e.touches[0].clientX,y:e.touches[0].clientY};}',
    '    else if(e.touches.length===2&&LD){var d=Math.hypot(e.touches[0].clientX-e.touches[1].clientX,e.touches[0].clientY-e.touches[1].clientY);Z=Math.min(3,Math.max(0.4,Z*(d/LD)));LD=d;}',
    '  },{passive:true});',
    '  el.addEventListener("touchend",function(){LT=null;LD=null;},{passive:true});',
    '  el.addEventListener("click",function(e){',
    '    var r=el.getBoundingClientRect(),mx=((e.clientX-r.left)-pan.x)/Z,my=((e.clientY-r.top)-pan.y)/Z;',
    '    var hit=null;for(var i=0;i<nodes.length;i++){if(Math.hypot(nodes[i].x-mx,nodes[i].y-my)<16){hit=nodes[i];break;}}',
    '    if(hit){var nav=document.querySelector(\'nav a[data-t="matches"]\');showTab("matches",nav);',
    '      setTimeout(function(){var c=document.getElementById("card-"+hit.id);if(c)c.scrollIntoView({behavior:"smooth",block:"center"});},60);}',
    '  });',
    '  window.addEventListener("resize",function(){clearTimeout(window._r);window._r=setTimeout(resize,80);});',
    '}',
    'interact();loadGraph();requestAnimationFrame(loop);',
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
