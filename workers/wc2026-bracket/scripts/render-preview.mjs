// Build an offline preview of the bracket page for device-emulated render tests.
// Bundles src/index.ts with esbuild, calls the exported page(), and writes a
// self-contained fixture under tests/.preview/ (index.html + bracket.json).
import { build } from 'esbuild';
import { mkdir, writeFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const outDir = join(root, 'tests', '.preview');

// Full Round-of-32, mirroring the live D1/KV data (migrations 0001+0002):
// M01–M06 final, M07–M08 live, the rest scheduled.
const T = {
  CAN: ['Canada', '🇨🇦'], RSA: ['South Africa', '🇿🇦'], USA: ['United States', '🇺🇸'], JPN: ['Japan', '🇯🇵'],
  MEX: ['Mexico', '🇲🇽'], KOR: ['South Korea', '🇰🇷'], BRA: ['Brazil', '🇧🇷'], NGA: ['Nigeria', '🇳🇬'],
  ARG: ['Argentina', '🇦🇷'], AUS: ['Australia', '🇦🇺'], FRA: ['France', '🇫🇷'], SEN: ['Senegal', '🇸🇳'],
  ENG: ['England', '🏴'], ECU: ['Ecuador', '🇪🇨'], ESP: ['Spain', '🇪🇸'], MAR: ['Morocco', '🇲🇦'],
  GER: ['Germany', '🇩🇪'], CRC: ['Costa Rica', '🇨🇷'], POR: ['Portugal', '🇵🇹'], URU: ['Uruguay', '🇺🇾'],
  NED: ['Netherlands', '🇳🇱'], CRO: ['Croatia', '🇭🇷'], BEL: ['Belgium', '🇧🇪'], SUI: ['Switzerland', '🇨🇭'],
  ITA: ['Italy', '🇮🇹'], COL: ['Colombia', '🇨🇴'], POL: ['Poland', '🇵🇱'], QAT: ['Qatar', '🇶🇦'],
  DEN: ['Denmark', '🇩🇰'], GHA: ['Ghana', '🇬🇭'], SRB: ['Serbia', '🇷🇸'], IRN: ['Iran', '🇮🇷'],
};
const team = (c) => ({ c, n: T[c][0], f: T[c][1] });
// [id,date,venue,status,home,away,hs,as,w,p,note,g]
const raw = [
  ['M01', 'Jun 28', 'Toronto', 'final', 'CAN', 'RSA', 1, 0, 'CAN', 61, null, 1],
  ['M02', 'Jun 28', 'Los Angeles', 'final', 'USA', 'JPN', 2, 1, 'USA', 54, null, 1],
  ['M03', 'Jun 29', 'Mexico City', 'final', 'MEX', 'KOR', 0, 0, 'MEX', 58, 'pens 4-3', 2],
  ['M04', 'Jun 29', 'New York', 'final', 'BRA', 'NGA', 3, 1, 'BRA', 72, null, 2],
  ['M05', 'Jun 30', 'Miami', 'final', 'ARG', 'AUS', 2, 0, 'ARG', 77, null, 3],
  ['M06', 'Jun 30', 'Dallas', 'final', 'FRA', 'SEN', 2, 1, 'FRA', 68, null, 3],
  ['M07', 'Jul 01', 'Seattle', 'in_progress', 'ENG', 'ECU', 1, 0, null, 70, "62'", 4],
  ['M08', 'Jul 01', 'Atlanta', 'in_progress', 'ESP', 'MAR', 0, 0, null, 64, "18'", 4],
  ['M09', 'Jul 02', 'Houston', 'scheduled', 'GER', 'CRC', null, null, null, 75, null, 5],
  ['M10', 'Jul 02', 'Boston', 'scheduled', 'POR', 'URU', null, null, null, 59, null, 5],
  ['M11', 'Jul 03', 'Philadelphia', 'scheduled', 'NED', 'CRO', null, null, null, 57, null, 6],
  ['M12', 'Jul 03', 'Kansas City', 'scheduled', 'BEL', 'SUI', null, null, null, 60, null, 6],
  ['M13', 'Jul 04', 'San Francisco', 'scheduled', 'ITA', 'COL', null, null, null, 55, null, 7],
  ['M14', 'Jul 04', 'Guadalajara', 'scheduled', 'POL', 'QAT', null, null, null, 63, null, 7],
  ['M15', 'Jul 05', 'Vancouver', 'scheduled', 'DEN', 'GHA', null, null, null, 58, null, 8],
  ['M16', 'Jul 05', 'Monterrey', 'scheduled', 'SRB', 'IRN', null, null, null, 56, null, 8],
];
const matches = raw.map(([id, date, venue, status, h, a, hs, as, w, p, note, g], i) => ({
  id, seq: i + 1, status, date, venue,
  home: team(h), away: team(a),
  s: hs == null ? null : { h: hs, a: as }, w, p: p == null ? null : { h: p }, note,
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
const { page } = await import('file://' + tmp);
await writeFile(join(outDir, 'index.html'), page(payload.matches), 'utf8');
await writeFile(join(outDir, 'bracket.json'), JSON.stringify(payload), 'utf8');
await rm(tmp, { force: true });
console.log('preview written →', outDir);
