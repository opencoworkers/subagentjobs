// Symmetric radial bracket layout — powered by d3-hierarchy (the standard,
// maintained tree-layout package). We build the full tournament as a balanced
// binary tree (32 teams → 16 R32 → 8 R16 → 4 QF → 2 SF → final) and let
// d3.cluster() place it: leaves evenly on the outer ring, every parent centred
// on its children → guaranteed left/right symmetry, by construction. The layout
// runs in the Worker; the client just draws the precomputed polar coordinates,
// so d3 never ships to the browser.
import { hierarchy, cluster } from 'd3-hierarchy';
import type { ShapedMatch } from './index';

export type NodeState = 'up' | 'adv' | 'live' | 'elim' | 'struct';
export interface GraphNode {
  k: 'final' | 'sf' | 'qf' | 'r16' | 'match' | 'team';
  ang: number;       // radians; -π/2 is the top of the circle
  r: number;         // 0 (centre/trophy) … 1 (outer team ring)
  st: NodeState;
  flag?: string;     // team leaves
  code?: string;
  score?: string;    // match nodes, e.g. "0(4)-0(3)"
  live?: boolean;
  mid?: string;      // match id (team leaves + match nodes) for click navigation
}
export interface Graph { nodes: GraphNode[]; links: [number, number][] }

interface TNode { k: GraphNode['k']; st: NodeState; flag?: string; code?: string; score?: string; live?: boolean; mid?: string; children?: TNode[] }

function scoreText(m: ShapedMatch): string | undefined {
  if (!m.s) return undefined;
  return `${m.s.h}${m.pk ? `(${m.pk.h})` : ''}-${m.s.a}${m.pk ? `(${m.pk.a})` : ''}`;
}

function teamLeaf(m: ShapedMatch, side: 'home' | 'away'): TNode {
  const t = m[side];
  const fin = m.status === 'final';
  const won = fin && m.w === t.c;
  const st: NodeState = fin ? (won ? 'adv' : 'elim') : m.status === 'in_progress' ? 'live' : 'up';
  return { k: 'team', st, flag: t.f, code: t.c, mid: m.id };
}

function matchNode(m: ShapedMatch): TNode {
  const st: NodeState = m.status === 'final' ? 'adv' : m.status === 'in_progress' ? 'live' : 'up';
  return { k: 'match', st, score: scoreText(m), live: m.status === 'in_progress', mid: m.id,
    children: [teamLeaf(m, 'home'), teamLeaf(m, 'away')] };
}

// Pair an even-length list into parent nodes of the given kind.
function pairUp(kids: TNode[], k: GraphNode['k']): TNode[] {
  const out: TNode[] = [];
  for (let i = 0; i < kids.length; i += 2) {
    out.push({ k, st: 'struct', children: [kids[i], kids[i + 1]].filter(Boolean) });
  }
  return out;
}

export function bracketGraph(matches: ShapedMatch[], r16: [string, string][]): Graph {
  const byId = new Map(matches.map((m) => [m.id, m]));
  // R16 nodes: each r16 pair → a node holding its two R32 matches.
  const r16nodes: TNode[] = r16.map((pair) => ({
    k: 'r16', st: 'struct',
    children: pair.map((id) => byId.get(id)).filter(Boolean).map((m) => matchNode(m as ShapedMatch)),
  }));
  const qf = pairUp(r16nodes, 'qf');
  const sf = pairUp(qf, 'sf');
  const root: TNode = { k: 'final', st: 'struct', children: sf };

  const h = hierarchy<TNode>(root);
  cluster<TNode>().size([Math.PI * 2, 1]).separation(() => 1)(h);
  const nLeaves = h.leaves().length || 1;
  const close = (nLeaves - 1) / nLeaves; // remap so leaf 0 and leaf n don't overlap (closed ring)

  const nodes: GraphNode[] = [];
  const index = new Map<object, number>();
  h.each((d: any) => {
    index.set(d, nodes.length);
    nodes.push({
      k: d.data.k, st: d.data.st, ang: d.x * close - Math.PI / 2, r: d.y,
      flag: d.data.flag, code: d.data.code, score: d.data.score, live: d.data.live, mid: d.data.mid,
    });
  });
  const links: [number, number][] = [];
  h.each((d: any) => { if (d.parent) links.push([index.get(d.parent)!, index.get(d)!]); });
  return { nodes, links };
}
