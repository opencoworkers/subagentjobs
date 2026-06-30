// Build an offline preview of the bracket page for device-emulated render tests.
// Bundles src/index.ts with esbuild, calls the exported page(), and writes a
// self-contained fixture under tests/.preview/ (index.html + bracket.json).
import { build } from 'esbuild';
import { mkdir, writeFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const outDir = join(root, 'tests', '.preview');

// Sample bracket: a few finals + one live match so the blink loop is exercised.
const T = {
  CAN: ['Canada', '🇨🇦'], RSA: ['South Africa', '🇿🇦'],
  USA: ['United States', '🇺🇸'], JPN: ['Japan', '🇯🇵'],
  MEX: ['Mexico', '🇲🇽'], KOR: ['South Korea', '🇰🇷'],
  BRA: ['Brazil', '🇧🇷'], NGA: ['Nigeria', '🇳🇬'],
};
const team = (c) => ({ c, n: T[c][0], f: T[c][1] });
const raw = [
  ['M01', 'final', 'CAN', 'RSA', 1, 0, 'CAN', 61, null, 1],
  ['M02', 'final', 'USA', 'JPN', 2, 1, 'USA', 54, null, 1],
  ['M03', 'final', 'MEX', 'KOR', 0, 0, 'MEX', 58, 'pens 4-3', 2],
  ['M04', 'in_progress', 'BRA', 'NGA', 2, 1, null, 72, null, 2],
];
const matches = raw.map(([id, status, h, a, hs, as, w, p, note, g], i) => ({
  id, seq: i + 1, status, date: 'Jun 28', venue: 'Toronto',
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
