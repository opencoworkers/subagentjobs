// Build an offline preview of the bracket page for device-emulated render tests.
// Bundles src/index.ts with esbuild, calls the exported page(), and writes a
// self-contained fixture under tests/.preview/ (index.html + bracket.json).
import { build } from 'esbuild';
import { mkdir, writeFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const outDir = join(root, 'tests', '.preview');

// Real FIFA World Cup 2026 Round of 32, as of 2026-06-30 (mirrors migrations
// 0001 + 0005). Four ties complete (two decided on penalties); the rest are
// scheduled — the Jun 30 trio kick off 1/5/9pm ET, so none are live yet.
// Sources: FIFA match centre, Wikipedia "2026 FIFA World Cup knockout stage", CBS bracket.
const T = {
  CAN: ['Canada', '🇨🇦'], RSA: ['South Africa', '🇿🇦'], BRA: ['Brazil', '🇧🇷'], JPN: ['Japan', '🇯🇵'],
  GER: ['Germany', '🇩🇪'], PAR: ['Paraguay', '🇵🇾'], NED: ['Netherlands', '🇳🇱'], MAR: ['Morocco', '🇲🇦'],
  CIV: ['Ivory Coast', '🇨🇮'], NOR: ['Norway', '🇳🇴'], FRA: ['France', '🇫🇷'], SWE: ['Sweden', '🇸🇪'],
  MEX: ['Mexico', '🇲🇽'], ECU: ['Ecuador', '🇪🇨'], ENG: ['England', '🏴'], COD: ['DR Congo', '🇨🇩'],
  USA: ['United States', '🇺🇸'], BIH: ['Bosnia & Herzegovina', '🇧🇦'], BEL: ['Belgium', '🇧🇪'], SEN: ['Senegal', '🇸🇳'],
  ESP: ['Spain', '🇪🇸'], AUT: ['Austria', '🇦🇹'], POR: ['Portugal', '🇵🇹'], CRO: ['Croatia', '🇭🇷'],
  AUS: ['Australia', '🇦🇺'], EGY: ['Egypt', '🇪🇬'], SUI: ['Switzerland', '🇨🇭'], ALG: ['Algeria', '🇩🇿'],
  ARG: ['Argentina', '🇦🇷'], CPV: ['Cape Verde', '🇨🇻'], COL: ['Colombia', '🇨🇴'], GHA: ['Ghana', '🇬🇭'],
};
const team = (c) => ({ c, n: T[c][0], f: T[c][1] });
// [id,date,venue,status,home,away,hs,as,w,p,note,g,ph,pa]  (ph/pa = penalty goals)
const raw = [
  ['M01', 'Jun 28', 'Inglewood', 'final', 'CAN', 'RSA', 1, 0, 'CAN', 58, null, 1],
  ['M02', 'Jun 29', 'Houston', 'final', 'BRA', 'JPN', 2, 1, 'BRA', 64, null, 3],
  ['M03', 'Jun 29', 'Foxborough', 'final', 'GER', 'PAR', 1, 1, 'PAR', 60, 'pens', 2, 3, 4],
  ['M04', 'Jun 29', 'Guadalupe', 'final', 'NED', 'MAR', 1, 1, 'MAR', 62, 'pens', 1, 2, 3],
  ['M05', 'Jun 30', 'Arlington', 'scheduled', 'CIV', 'NOR', null, null, null, 42, null, 3],
  ['M06', 'Jun 30', 'East Rutherford', 'scheduled', 'FRA', 'SWE', null, null, null, 66, null, 2],
  ['M07', 'Jun 30', 'Mexico City', 'scheduled', 'MEX', 'ECU', null, null, null, 52, null, 4],
  ['M08', 'Jul 01', 'Atlanta', 'scheduled', 'ENG', 'COD', null, null, null, 74, null, 4],
  ['M09', 'Jul 01', 'Seattle', 'scheduled', 'BEL', 'SEN', null, null, null, 55, null, 6],
  ['M10', 'Jul 01', 'Santa Clara', 'scheduled', 'USA', 'BIH', null, null, null, 60, null, 6],
  ['M11', 'Jul 02', 'Inglewood', 'scheduled', 'ESP', 'AUT', null, null, null, 70, null, 5],
  ['M12', 'Jul 02', 'Vancouver', 'scheduled', 'SUI', 'ALG', null, null, null, 53, null, 8],
  ['M13', 'Jul 02', 'Toronto', 'scheduled', 'POR', 'CRO', null, null, null, 56, null, 5],
  ['M14', 'Jul 03', 'Arlington', 'scheduled', 'AUS', 'EGY', null, null, null, 47, null, 7],
  ['M15', 'Jul 03', 'Miami', 'scheduled', 'ARG', 'CPV', null, null, null, 82, null, 7],
  ['M16', 'Jul 03', 'Kansas City', 'scheduled', 'COL', 'GHA', null, null, null, 62, null, 8],
];
const matches = raw.map(([id, date, venue, status, h, a, hs, as, w, p, note, g, ph, pa], i) => ({
  id, seq: i + 1, status, date, venue,
  home: team(h), away: team(a),
  s: hs == null ? null : { h: hs, a: as },
  pk: ph == null ? null : { h: ph, a: pa },
  w, p: p == null ? null : { h: p }, note,
  _g: g,
}));
const groups = new Map();
for (const m of matches) { const arr = groups.get(m._g) || []; arr.push(m.id); groups.set(m._g, arr); }
const r16 = [...groups.values()].filter((a) => a.length === 2);
const payload = { matches: matches.map(({ _g, ...m }) => m), r16,
  meta: { updated: '2026-06-30T18:00:00Z', stage: 'Round of 32', final_date: 'Jul 19, 2026', final_venue: 'MetLife Stadium' } };

const tmp = join(outDir, 'bundle.mjs');
await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });
await build({
  entryPoints: [join(root, 'src', 'index.ts')],
  bundle: true, format: 'esm', platform: 'neutral', outfile: tmp, logLevel: 'silent',
});
const { page, bracketGraph } = await import('file://' + tmp);
payload.graph = bracketGraph(payload.matches, payload.r16); // symmetric radial tree (d3-hierarchy)
await writeFile(join(outDir, 'index.html'), page(payload.matches), 'utf8');
await writeFile(join(outDir, 'bracket.json'), JSON.stringify(payload), 'utf8');
await rm(tmp, { force: true });
console.log('preview written →', outDir);
