# subagentjobs-wc2026 — subagentdata.com

World Cup 2026 Round-of-32 **radial bracket**, built to the same design system
as `workers/web` (subagentjobs.com): TypeScript module Worker, **D1-backed**,
**server-rendered HTML**, terminal aesthetic (`#0a0a0a` / `#51c4ff`), and an
A2A agent card.

## Storage — Cloudflare D1 (not KV)

Match data lives in the shared `subagentjobs-dwh` D1 database as a Kimball star
(`migrations/0001_bracket.sql`):

| Table        | Grain                | Notes                                        |
| ------------ | -------------------- | -------------------------------------------- |
| `dim_team`   | one national team    | `team_code`, `name`, `flag`                  |
| `fact_match` | one R32 match        | scores, status, winner, `r16_group`, prob    |

The Worker JOINs `fact_match` to `dim_team` (home + away) and shapes rows for the
page and the JSON API. Score updates are plain SQL `UPDATE`s — **no redeploy**.

## Auth — Cloudflare Secrets Store

`/api/update` is gated by `WC2026_UPDATE_SECRET`, bound from the **Secrets Store**
(`[[secrets_store_secrets]]` in `wrangler.toml`), not a plaintext `[vars]` value.
Code reads it with `await env.UPDATE_SECRET.get()`. Provision it with
`make bracket-secret`, then paste the printed `store_id` into `wrangler.toml`.

## Resource tagging

Worker, D1 dataset, and secret are tagged `github:opencoworkers/subagentjobs`
(from `cloudflare.toml` `[meta].tag`) via `make tag-resources` →
`scripts/cf-tag-resources.sh`, so the deployment's resources are discoverable
as a group. The new worker is also registered in `cloudflare.toml`.

## Routes

| Route                          | Method | Description                                  |
| ------------------------------ | ------ | -------------------------------------------- |
| `/`                            | GET    | Server-rendered bracket + matches page       |
| `/api/bracket`                 | GET    | Bracket JSON (matches + r16 pairs + meta)    |
| `/api/status`                  | GET    | Summary counts + final results               |
| `/api/update`                  | POST   | Apply score/status deltas — `Bearer` secret  |
| `/health`                      | GET    | Liveness probe                               |
| `/.well-known/agent-card.json` | GET    | A2A agent card (`get_bracket` skill)         |
| `/a2a`                         | POST   | A2A `tasks/send` → bracket data artifact     |

## Makefile (run from repo root)

```bash
make migrate-bracket   # apply dim_team/fact_match + seed to D1
make bracket-secret    # provision Secrets Store WC2026_UPDATE_SECRET (prints store_id)
make deploy-bracket    # wrangler deploy
make tag-resources     # tag Worker + D1 + secret with the repo tag
make bracket-update    # update live scores via a `claude -p` subagent worker
```

`make bracket-update` runs a **`claude -p` subagent worker** that fetches the
latest results, diffs them against `/api/bracket`, and POSTs only the changed
matches to `/api/update` — the same agent-driven pattern as `make review` / `make pr`.
