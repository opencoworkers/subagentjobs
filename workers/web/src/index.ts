/**
 * subagentjobs-web
 * Design: terminal aesthetic, matches coworkers.subagentknowledge.com
 * Mobile: optimised for iPhone 16 Pro (430px, Dynamic Island safe-areas)
 * Perf:   initial payload <50KB — jobs+graph fetched client-side on demand
 */

export interface Env {
  DB: D1Database;
}

const sha = async (s: string): Promise<string> => {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map(x => x.toString(16).padStart(2, '0')).join('');
};

const cors = { 'access-control-allow-origin': '*' } as const;

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const u = new URL(req.url);

    // ── /api/jobs ─────────────────────────────────────────────────────────────
    if (u.pathname === '/api/jobs') {
      const co    = u.searchParams.get('company');
      const skill = u.searchParams.get('skill');
      let sql: string;
      const params: string[] = [];

      if (skill) {
        sql = `SELECT DISTINCT f.job_post_id,f.title,f.location_name,f.location_type,
                      f.company_name,f.first_published,f.updated_at
               FROM fact_job_posting f
               JOIN bridge_job_skill b ON f.job_post_id=b.job_post_id
               JOIN dim_skill s        ON b.skill_key=s.skill_key
               WHERE s.name=? ORDER BY f.company_name,f.title LIMIT 200`;
        params.push(skill);
      } else if (co) {
        sql = `SELECT job_post_id,title,location_name,location_type,company_name,first_published,updated_at
               FROM fact_job_posting WHERE company_name=? ORDER BY title LIMIT 200`;
        params.push(co);
      } else {
        sql = `SELECT job_post_id,title,location_name,location_type,company_name,first_published,updated_at
               FROM fact_job_posting ORDER BY company_name,title LIMIT 500`;
      }

      const stmt = params.length ? env.DB.prepare(sql).bind(...params) : env.DB.prepare(sql);
      const { results } = await stmt.all();
      const jobs = await Promise.all(
        (results as any[]).map(async j => ({
          ...j,
          sha256: await sha(j.job_post_id + ':' + j.title + ':' + j.updated_at),
        }))
      );
      return Response.json({ jobs, total: jobs.length }, { headers: cors });
    }

    // ── /api/stats ────────────────────────────────────────────────────────────
    if (u.pathname === '/api/stats') {
      const [boards, byType, n] = await Promise.all([
        env.DB.prepare(`SELECT board_token,name,platform,job_count,last_crawled_at
                        FROM dim_board WHERE job_count>0 ORDER BY job_count DESC`).all(),
        env.DB.prepare(`SELECT location_type,COUNT(*) as c FROM fact_job_posting
                        GROUP BY location_type ORDER BY c DESC`).all(),
        env.DB.prepare(`SELECT COUNT(*) as n FROM fact_job_posting`).first<{ n: number }>(),
      ]);
      return Response.json(
        { total: n!.n, boards: boards.results, by_type: byType.results },
        { headers: cors }
      );
    }

    // ── /api/graph ────────────────────────────────────────────────────────────
    if (u.pathname === '/api/graph') {
      const [nodes, edges] = await Promise.all([
        env.DB.prepare(`SELECT s.name,s.category,COUNT(*) as v
                        FROM bridge_job_skill b JOIN dim_skill s ON b.skill_key=s.skill_key
                        GROUP BY s.skill_key ORDER BY v DESC`).all(),
        env.DB.prepare(`SELECT s1.name as source,s2.name as target,COUNT(*) as w
                        FROM bridge_job_skill a
                        JOIN bridge_job_skill b ON a.job_post_id=b.job_post_id AND a.skill_key<b.skill_key
                        JOIN dim_skill s1 ON a.skill_key=s1.skill_key
                        JOIN dim_skill s2 ON b.skill_key=s2.skill_key
                        GROUP BY a.skill_key,b.skill_key HAVING w>=15
                        ORDER BY w DESC LIMIT 80`).all(),
      ]);
      return Response.json({ nodes: nodes.results, edges: edges.results }, { headers: cors });
    }

    // ── /jobs/:hash ───────────────────────────────────────────────────────────
    if (u.pathname.startsWith('/jobs/')) {
      const h = u.pathname.slice(7);
      const { results } = await env.DB.prepare(
        `SELECT job_post_id,title,location_name,location_type,company_name,first_published,updated_at
         FROM fact_job_posting`
      ).all();
      for (const j of results as any[]) {
        if (await sha(j.job_post_id + ':' + j.title + ':' + j.updated_at) === h) {
          const skills = await env.DB
            .prepare(`SELECT s.name,s.category FROM bridge_job_skill b
                      JOIN dim_skill s ON b.skill_key=s.skill_key WHERE b.job_post_id=?`)
            .bind(j.job_post_id).all();
          return new Response(detail(j, h, skills.results as any[]), {
            headers: { 'content-type': 'text/html;charset=utf-8' },
          });
        }
      }
      return new Response('Not found', { status: 404 });
    }

    // ── / dashboard (lightweight — no jobs embedded) ──────────────────────────
    const [boards, byType, n, topSkills] = await Promise.all([
      env.DB.prepare(`SELECT board_token,name,platform,job_count,last_crawled_at
                      FROM dim_board WHERE job_count>0 ORDER BY job_count DESC`).all(),
      env.DB.prepare(`SELECT location_type,COUNT(*) as c FROM fact_job_posting
                      GROUP BY location_type ORDER BY c DESC`).all(),
      env.DB.prepare(`SELECT COUNT(*) as n FROM fact_job_posting`).first<{ n: number }>(),
      env.DB.prepare(`SELECT s.name,s.category,COUNT(*) as v
                      FROM bridge_job_skill b JOIN dim_skill s ON b.skill_key=s.skill_key
                      GROUP BY s.skill_key ORDER BY v DESC LIMIT 30`).all(),
    ]);

    return new Response(
      main(n!.n, boards.results as any[], byType.results as any[], topSkills.results as any[]),
      { headers: { 'content-type': 'text/html;charset=utf-8' } }
    );
  },
};

// ── Shared CSS ───────────────────────────────────────────────────────────────
function sharedCss(): string {
  return `
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;padding:0;
  font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;
  background:#0a0a0a;color:#d4d4d4;-webkit-font-smoothing:antialiased;font-size:13px}
#hdr{padding:10px 16px;
  padding-top:calc(10px + env(safe-area-inset-top));
  border-bottom:1px solid #1f1f1f;
  display:flex;align-items:center;gap:12px;
  position:sticky;top:0;
  background:rgba(10,10,10,.94);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);z-index:20}
#hdr h1{margin:0;font-size:14px;font-weight:600;letter-spacing:1px;color:#f4f4f4}
.hdr-meta{font-size:11px;color:#51c4ff}
.hdr-badge{margin-left:auto;font-size:9px;text-transform:uppercase;letter-spacing:1px;
  border:1px solid #2a2a2a;padding:2px 7px;color:#6a6a6a}
nav{display:flex;overflow-x:auto;border-bottom:1px solid #1f1f1f;scrollbar-width:none;
  background:rgba(10,10,10,.94);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);
  position:sticky;top:calc(41px + env(safe-area-inset-top));z-index:19}
nav::-webkit-scrollbar{display:none}
nav a{padding:8px 14px;font-size:11px;color:#6a6a6a;text-decoration:none;
  white-space:nowrap;border-bottom:2px solid transparent;
  min-height:36px;display:flex;align-items:center;flex-shrink:0}
nav a.active,nav a:hover{color:#51c4ff;border-bottom-color:#51c4ff}
main{padding:12px 16px;padding-bottom:calc(48px + env(safe-area-inset-bottom))}
.section{margin-bottom:24px}
.sh{display:flex;align-items:baseline;gap:10px;padding:6px 0;
  border-bottom:1px solid #1f1f1f;margin-bottom:10px}
.sl{font-size:10px;text-transform:uppercase;letter-spacing:1px;font-weight:600;color:#51c4ff}
.sl-g{color:#7bd88f}.sl-a{color:#f4a73b}.sl-m{color:#6a6a6a;font-weight:400}
.stag{font-size:9px;padding:2px 8px;border:1px solid #2a2a2a;color:#6a6a6a;
  text-transform:uppercase;letter-spacing:.5px;cursor:pointer;
  transition:border-color .15s,color .15s;user-select:none;display:inline-block}
.stag:hover{border-color:#51c4ff44;color:#51c4ff}
.stag.lang{border-color:#51c4ff33;color:#51c4ff}
.stag.fw{border-color:#c084fc33;color:#c084fc}
.stag.plat{border-color:#7bd88f33;color:#7bd88f}
.stag.dom{border-color:#f4a73b33;color:#f4a73b}
`.trim();
}

// ── Dashboard ─────────────────────────────────────────────────────────────────
function main(total: number, boards: any[], byType: any[], topSkills: any[]): string {
  const remoteCount = byType.find((t: any) => t.location_type === 'Remote')?.c ?? 0;

  const boardCards = boards.map((b: any) =>
    '<div class="bcard" onclick="filterCo(' + JSON.stringify(b.name || b.board_token) + ')">' +
      '<div class="bcnt">' + b.job_count + '</div>' +
      '<div class="bnm">' + esc(b.name || b.board_token) + '</div>' +
      '<div class="bplat">' + (b.platform || 'greenhouse') + '</div>' +
    '</div>'
  ).join('');

  const skillTags = topSkills.map((s: any) => {
    const cls = s.category === 'language' ? 'lang' : s.category === 'framework' ? 'fw' :
                s.category === 'platform'  ? 'plat' : 'dom';
    return '<span class="stag ' + cls + '" onclick="filterSkill(' + JSON.stringify(s.name) + ')">' +
      s.name + ' <span style="opacity:.45">' + s.v + '</span></span>';
  }).join('');

  // Client-side JS: NO template literals — avoids TS template-in-template escaping
  const clientJs = [
    'var allJobs=[],graphLoaded=false;',

    'function showTab(name,el){',
    '  document.querySelectorAll("nav a").forEach(function(a){a.classList.remove("active");});',
    '  el.classList.add("active");',
    '  ["overview","jobs","graph"].forEach(function(t){',
    '    var s=document.getElementById("tab-"+t);',
    '    if(s)s.style.display=(t===name?"":"none");',
    '  });',
    '  if(name==="jobs"&&!allJobs.length)loadJobs();',
    '  if(name==="graph"&&!graphLoaded)loadGraph();',
    '}',

    'function loadJobs(){',
    '  fetch("/api/jobs").then(function(r){return r.json();}).then(function(d){',
    '    allJobs=d.jobs;',
    '    var el=document.getElementById("job-count");',
    '    if(el)el.textContent=d.jobs.length;',
    '    renderJobs(d.jobs);',
    '  }).catch(function(){',
    '    var el=document.getElementById("job-table");',
    '    if(el)el.innerHTML=\'<div class="err">failed to load positions</div>\';',
    '  });',
    '}',

    'function renderJobs(jobs){',
    '  var el=document.getElementById("job-table");',
    '  if(!jobs.length){el.innerHTML=\'<div class="loading">no results</div>\';return;}',
    '  var rows=jobs.map(function(j){',
    '    var ty=j.location_type==="Remote"?\'<span class="ty-r">remote</span>\':',
    '           j.location_type==="On-site"?\'<span class="ty-o">on-site</span>\':',
    '           \'<span class="ty-cell">\'+(j.location_type||"—")+"</span>";',
    '    var lo=(j.location_name||"").split("|")[0].split(";")[0].trim();',
    '    return \'<tr onclick="location.href=\\"/jobs/\'+j.sha256+\'\\"">\'+',
    '      \'<td class="co-cell">\'+j.company_name+\'</td>\'+',
    '      \'<td class="ti-cell">\'+j.title+\'</td>\'+',
    '      \'<td class="lo-cell">\'+lo+\'</td>\'+',
    '      \'<td>\'+ty+\'</td></tr>\';',
    '  }).join("");',
    '  el.innerHTML=\'<table><thead><tr><th>company</th><th>role</th><th>location</th><th>type</th></tr></thead><tbody>\'+rows+\'</tbody></table>\';',
    '}',

    'function filterJobs(q){',
    '  if(!q){renderJobs(allJobs);return;}',
    '  var t=q.toLowerCase();',
    '  renderJobs(allJobs.filter(function(j){',
    '    return(j.title+" "+j.company_name+" "+(j.location_name||"")+" "+(j.location_type||"")).toLowerCase().indexOf(t)>=0;',
    '  }));',
    '}',

    'function filterCo(name){',
    '  var nav=document.querySelector(\'nav a[href="#jobs"]\');',
    '  showTab("jobs",nav);',
    '  var srch=document.getElementById("srch");',
    '  if(srch){srch.value=name;filterJobs(name);}',
    '  else{document.getElementById("srch").value=name;filterJobs(name);}',
    '}',

    'function filterSkill(skill){',
    '  var nav=document.querySelector(\'nav a[href="#jobs"]\');',
    '  showTab("jobs",nav);',
    '  fetch("/api/jobs?skill="+encodeURIComponent(skill))',
    '    .then(function(r){return r.json();})',
    '    .then(function(d){',
    '      allJobs=d.jobs;',
    '      var srch=document.getElementById("srch");',
    '      if(srch)srch.value="skill:"+skill;',
    '      var cnt=document.getElementById("job-count");',
    '      if(cnt)cnt.textContent=d.jobs.length;',
    '      renderJobs(d.jobs);',
    '    });',
    '}',

    'function loadGraph(){',
    '  graphLoaded=true;',
    '  var s=document.createElement("script");',
    '  s.src="https://cdn.jsdelivr.net/npm/echarts@5/dist/echarts.min.js";',
    '  s.onload=function(){',
    '    fetch("/api/graph").then(function(r){return r.json();}).then(function(d){',
    '      var cc={language:"#51c4ff",framework:"#c084fc",platform:"#7bd88f",domain:"#f4a73b"};',
    '      var el=document.getElementById("graph");',
    '      if(!el)return;',
    '      var chart=echarts.init(el,null,{renderer:"canvas"});',
    '      chart.setOption({',
    '        backgroundColor:"transparent",',
    '        tooltip:{trigger:"item",textStyle:{fontFamily:"monospace",fontSize:11},',
    '          formatter:function(p){return p.dataType==="node"?p.data.name+"\\n"+p.data.value+" jobs":""}},',
    '        series:[{type:"graph",layout:"force",',
    '          data:d.nodes.map(function(n){return{name:n.name,symbolSize:Math.max(8,Math.sqrt(n.v)*2.5),',
    '            category:n.category,value:n.v,itemStyle:{color:cc[n.category]||"#6a6a6a"}};}),',
    '          links:d.edges.map(function(e){return{source:e.source,target:e.target,',
    '            lineStyle:{width:Math.max(1,Math.sqrt(e.w)/4),opacity:.25,color:"#2a2a2a"}};}),',
    '          roam:true,',
    '          label:{show:true,color:"#9a9a9a",fontSize:10,fontFamily:"monospace"},',
    '          force:{repulsion:250,gravity:0.08,edgeLength:[60,200]},',
    '          emphasis:{focus:"adjacency",lineStyle:{width:3,opacity:.6}}',
    '        }]',
    '      });',
    '      var ldr=document.querySelector("#graph-wrap .loading");',
    '      if(ldr)ldr.remove();',
    '      window.addEventListener("resize",function(){chart.resize();});',
    '    });',
    '  };',
    '  document.head.appendChild(s);',
    '}',
  ].join('\n');

  return `<!DOCTYPE html>
<html lang=en>
<head>
<meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name=apple-mobile-web-app-capable content=yes>
<meta name=theme-color content=#0a0a0a>
<title>subagentjobs — ${total} open positions</title>
<style>
${sharedCss()}
.stats-row{display:flex;gap:6px;margin-bottom:20px}
.stat{border:1px solid #2a2a2a;padding:10px 12px;background:#111;flex:1;min-width:70px}
.stat .n{font-size:22px;font-weight:700;color:#51c4ff;line-height:1}
.stat .l{font-size:9px;text-transform:uppercase;letter-spacing:1px;color:#6a6a6a;margin-top:3px}
.board-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:6px;margin-bottom:20px}
.bcard{border:1px solid #2a2a2a;padding:10px 12px;background:#111;cursor:pointer;transition:border-color .15s}
.bcard:hover,.bcard:active{border-color:#51c4ff66}
.bcnt{font-size:20px;font-weight:700;color:#51c4ff;line-height:1}
.bnm{font-size:10px;color:#9a9a9a;margin-top:3px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.bplat{font-size:9px;color:#3a3a3a;margin-top:2px}
.skills-wrap{display:flex;flex-wrap:wrap;gap:4px;margin-bottom:20px}
.srch{width:100%;padding:10px 14px;background:#111;border:1px solid #2a2a2a;
  color:#d4d4d4;font-family:inherit;font-size:16px;margin-bottom:8px;
  outline:none;-webkit-appearance:none;border-radius:0}
.srch:focus{border-color:#51c4ff}
.srch::placeholder{color:#3a3a3a}
table{width:100%;border-collapse:collapse}
th{padding:6px 8px;font-size:9px;color:#6a6a6a;text-transform:uppercase;
  letter-spacing:.5px;border-bottom:1px solid #1f1f1f;text-align:left;font-weight:600;background:#0a0a0a}
td{padding:9px 8px;border-bottom:1px solid #141414;vertical-align:middle}
tr:hover td{background:#111}
.co-cell{color:#51c4ff;font-size:11px;font-weight:600}
.ti-cell{color:#f4f4f4;font-size:12px}
.lo-cell{color:#6a6a6a;font-size:10px}
.ty-r{color:#7bd88f;font-size:10px}
.ty-o{color:#f4a73b;font-size:10px}
.ty-cell{color:#6a6a6a;font-size:10px}
.loading{padding:20px;text-align:center;font-size:11px;color:#3a3a3a}
.err{padding:12px;border:1px solid #f4706733;color:#f47067;font-size:11px;background:#111}
#graph-wrap{height:420px;position:relative;border:1px solid #2a2a2a;background:#111}
#graph-wrap .loading{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%)}
#graph{width:100%;height:100%}
.footer{text-align:center;padding:20px 16px;font-size:10px;color:#3a3a3a;border-top:1px solid #1a1a1a}
.footer a{color:#51c4ff;text-decoration:none}
@media(max-width:480px){
  .board-grid{grid-template-columns:repeat(auto-fill,minmax(85px,1fr))}
  .stats-row{gap:4px}
  table thead{display:none}
  table,tbody,tr,td{display:block}
  tr{border:1px solid #1f1f1f;margin-bottom:4px;padding:8px 10px;background:#111;cursor:pointer}
  tr:hover{background:#141414}
  td{border:none;padding:1px 0}
  .co-cell{margin-bottom:2px}
  .ti-cell{font-size:12px;color:#f4f4f4;font-weight:500;margin-bottom:2px}
  .lo-cell,.ty-r,.ty-o,.ty-cell{font-size:10px;display:inline;margin-right:8px}
}
</style>
</head>
<body>
<div id=hdr>
  <h1>subagentjobs</h1>
  <span class=hdr-meta>${total} jobs</span>
  <span class=hdr-badge>live</span>
</div>
<nav>
  <a href=#overview class=active onclick="showTab('overview',this);return false">overview</a>
  <a href=#jobs onclick="showTab('jobs',this);return false">jobs</a>
  <a href=#graph onclick="showTab('graph',this);return false">graph</a>
  <a href=https://subagentknowledge.com target=_blank style="margin-left:auto">knowledge ↗</a>
</nav>
<main>

<section id=tab-overview>
  <div class=section>
    <div class=sh><span class=sl>stats</span></div>
    <div class=stats-row>
      <div class=stat><div class=n>${total}</div><div class=l>jobs</div></div>
      <div class=stat><div class=n>${boards.length}</div><div class=l>companies</div></div>
      <div class=stat><div class=n>${remoteCount}</div><div class=l>remote</div></div>
    </div>
  </div>
  <div class=section>
    <div class=sh>
      <span class=sl>companies</span>
      <span class="sl sl-m" style="margin-left:auto">${boards.length}</span>
    </div>
    <div class=board-grid>${boardCards}</div>
  </div>
  <div class=section>
    <div class=sh>
      <span class=sl>skills</span>
      <span class="sl sl-m" style="margin-left:auto">${topSkills.length}</span>
    </div>
    <div class=skills-wrap>${skillTags}</div>
  </div>
</section>

<section id=tab-jobs style=display:none>
  <div class=section>
    <div class=sh>
      <span class=sl>positions</span>
      <span id=job-count class="sl sl-m" style="margin-left:auto"></span>
    </div>
    <input class=srch id=srch placeholder="search roles, companies, locations…" oninput="filterJobs(this.value)" autocomplete=off autocorrect=off autocapitalize=off spellcheck=false>
    <div id=job-table><div class=loading>loading positions…</div></div>
  </div>
</section>

<section id=tab-graph style=display:none>
  <div class=section>
    <div class=sh>
      <span class=sl>skill graph</span>
      <span class="sl sl-m" style="margin-left:auto">force-directed · pinch to zoom</span>
    </div>
    <div id=graph-wrap>
      <div class=loading>loading graph…</div>
      <div id=graph></div>
    </div>
  </div>
</section>

</main>
<div class=footer>
  <a href=/api/jobs>jobs api</a> · <a href=/api/graph>graph api</a> · <a href=/api/stats>stats api</a>
</div>
<script>${clientJs}</script>
</body>
</html>`;
}

// ── Job detail page ───────────────────────────────────────────────────────────
function detail(j: any, h: string, skills: any[]): string {
  const tags = skills.map((s: any) => {
    const cls = s.category === 'language' ? 'lang' : s.category === 'framework' ? 'fw' :
                s.category === 'platform'  ? 'plat' : 'dom';
    return '<span class="stag ' + cls + '" style="font-size:11px;padding:3px 10px">' + esc(s.name) + '</span>';
  }).join(' ');

  const published = j.first_published
    ? new Date(j.first_published).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
    : '—';

  return `<!DOCTYPE html>
<html lang=en>
<head>
<meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name=theme-color content=#0a0a0a>
<title>${esc(j.title)} — ${esc(j.company_name)}</title>
<style>
${sharedCss()}
.detail{max-width:720px;margin:16px auto;border:1px solid #2a2a2a;padding:20px;background:#111}
.d-co{font-size:10px;text-transform:uppercase;letter-spacing:1px;color:#51c4ff;margin-bottom:8px}
.d-title{font-size:20px;color:#f4f4f4;font-weight:700;margin-bottom:16px;line-height:1.3}
.d-meta{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:20px}
.d-tag{font-size:10px;padding:3px 10px;border:1px solid #2a2a2a;color:#6a6a6a}
.d-hash{font-size:9px;color:#2a2a2a;word-break:break-all;margin-top:20px;
  border-top:1px solid #1f1f1f;padding-top:12px}
.skills-wrap{display:flex;flex-wrap:wrap;gap:4px}
</style>
</head>
<body>
<div id=hdr>
  <h1><a href=/ style="color:#f4f4f4;text-decoration:none">subagentjobs</a></h1>
  <span class=hdr-meta>← back</span>
</div>
<main style=padding:12px>
  <div class=detail>
    <div class=d-co>${esc(j.company_name)}</div>
    <div class=d-title>${esc(j.title)}</div>
    <div class=d-meta>
      <span class=d-tag>📍 ${esc(j.location_name || '—')}</span>
      <span class=d-tag>${esc(j.location_type || '—')}</span>
      <span class=d-tag>${published}</span>
    </div>
    <div class=sh><span class=sl>extracted skills</span></div>
    <div class=skills-wrap>${tags || '<span style="color:#3a3a3a;font-size:11px">no skills matched</span>'}</div>
    <div class=d-hash>sha256: ${h}</div>
  </div>
</main>
</body>
</html>`;
}

// Minimal HTML-escape to prevent XSS in server-rendered fields
function esc(s: string): string {
  return (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
