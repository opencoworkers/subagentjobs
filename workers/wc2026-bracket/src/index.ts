/**
 * wc2026-bracket  —  subagentdata.com
 *
 * World Cup 2026 Round-of-32 radial bracket. The Worker is pure routing;
 * all content lives in KV, so the UI and scores can be updated without a
 * redeploy:
 *   KV `html`    — full page HTML (served at /)
 *   KV `bracket` — match-data JSON (served at /api/bracket)
 *
 * Routes:
 *   GET  /              → page HTML from KV
 *   GET  /api/bracket   → raw bracket JSON
 *   GET  /api/status    → summarised counts + final results
 *   POST /api/update    → replace bracket JSON (Bearer UPDATE_SECRET)
 *   GET  /health        → liveness probe
 */

export interface Env {
  KV: KVNamespace;
  UPDATE_SECRET?: string;
}

interface Score { h: number; a: number }
interface Side { c: string; n: string; f: string }
interface Match {
  id: string;
  status: 'scheduled' | 'in_progress' | 'final';
  home: Side;
  away: Side;
  s?: Score;
  w?: string;
  note?: string;
}
interface Bracket {
  matches: Match[];
  r16?: [string, string][];
  meta?: Record<string, unknown>;
}

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type,Authorization',
} as const;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...cors },
  });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const p = url.pathname;

    if (req.method === 'OPTIONS') return new Response(null, { headers: cors });

    // ── raw bracket data ──────────────────────────────────────────────────
    if (p === '/api/bracket') {
      const d = await env.KV.get('bracket');
      if (!d) return json({ error: 'no data' }, 404);
      return new Response(d, {
        headers: {
          'Content-Type': 'application/json',
          'Cache-Control': 'public,max-age=30,stale-while-revalidate=60',
          ...cors,
        },
      });
    }

    // ── summarised status ─────────────────────────────────────────────────
    if (p === '/api/status') {
      const raw = await env.KV.get('bracket');
      if (!raw) return json({ error: 'no data' }, 404);
      const bd = JSON.parse(raw) as Bracket;
      const by = (st: Match['status']) => bd.matches.filter((m) => m.status === st);
      return json({
        updated: bd.meta?.updated,
        done: by('final').length,
        live: by('in_progress').length,
        upcoming: by('scheduled').length,
        total: bd.matches.length,
        results: by('final').map(
          (m) =>
            m.home.c +
            (m.s ? ` ${m.s.h}-${m.s.a}` : '') +
            ` vs ${m.away.c}` +
            (m.w ? ` W:${m.w}` : '') +
            (m.note ? ` (${m.note})` : ''),
        ),
      });
    }

    // ── authenticated bracket update ──────────────────────────────────────
    if (p === '/api/update' && req.method === 'POST') {
      const auth = req.headers.get('Authorization') || '';
      const secret = env.UPDATE_SECRET || '';
      if (secret && auth !== `Bearer ${secret}`) return json({ error: 'unauthorized' }, 401);

      let body: Bracket;
      try {
        body = (await req.json()) as Bracket;
      } catch {
        return json({ error: 'invalid json' }, 400);
      }
      if (!body.matches) return json({ error: 'missing matches' }, 400);

      body.meta = {
        updated: new Date().toISOString(),
        stage: 'Round of 32',
        final_date: 'Jul 19, 2026',
        final_venue: 'MetLife Stadium',
        ...(body.meta || {}),
      };
      await env.KV.put('bracket', JSON.stringify(body));
      const by = (st: Match['status']) => body.matches.filter((m) => m.status === st);
      return json({
        ok: true,
        updated: body.meta.updated,
        done: by('final').length,
        live: by('in_progress').length,
      });
    }

    if (p === '/health') return json({ ok: true, ts: Date.now() });

    // ── page HTML ─────────────────────────────────────────────────────────
    const htmlPage = await env.KV.get('html');
    if (!htmlPage) {
      return new Response('loading...', { headers: { 'Content-Type': 'text/html' } });
    }
    return new Response(htmlPage, {
      headers: {
        'Content-Type': 'text/html;charset=UTF-8',
        'Cache-Control': 'public,max-age=300,stale-while-revalidate=600',
      },
    });
  },
};
