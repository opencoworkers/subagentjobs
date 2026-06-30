# wc2026-bracket — agent operating manual (no human in the loop)

This worker (**subagentdata.com**) is built to be operated **agent-to-agent**.
Any future Claude / A2A agent has everything it needs to read, update, migrate,
and deploy it **without asking a human**. The machine-readable source of truth is
[`src/agent-context.json`](src/agent-context.json), also served live at
<https://subagentdata.com/.well-known/agent-context.json> (augmented with live
binding presence).

## Identity & bindings (from agent-context.json)

| | |
| --- | --- |
| Cloudflare account | `e6294e3ea89f8207af387d459824aaae` (alex@jadecli.com) |
| Worker | `wc2026-bracket` · route `subagentdata.com/*` |
| `DB` (D1) | `subagentjobs-dwh` · `305ed041-5dae-44e5-ab1f-8a63efd8627e` · tables `dim_team`, `fact_match` |
| `UPDATE_SECRET` | Secrets Store `subagentjobs` / `WC2026_UPDATE_SECRET` (resolve store_id from the CF API by name) |
| `SCORES_SOURCE_URL` | var — autonomous ingestion source for the cron |
| tag | `github:opencoworkers/subagentjobs` |

## Updating scores — three human-free channels

1. **Autonomous cron (preferred).** Set `SCORES_SOURCE_URL` to any agent-published
   JSON endpoint returning `{ "matches": [delta, …] }`. The worker's `scheduled()`
   handler ingests it every 10 min and writes D1 — no auth, no human.
2. **Agent-to-agent push.** `POST /api/update` with `Authorization: Bearer <UPDATE_SECRET>`
   and body `{ "matches": [delta, …] }`.
3. **Direct D1 write.** Use the Cloudflare D1 connector/API against the account +
   `database_id` above (e.g. `UPDATE fact_match …`). This is how the data was seeded.

A **delta** is:
```json
{ "id": "M07", "status": "final", "home_score": 2, "away_score": 1, "winner": "ENG", "note": "AET" }
```
`id` ∈ `fact_match.match_id` (`M01`–`M16`); `status` ∈ `scheduled|in_progress|final`.

## Migrate

`migrations/*.sql` are idempotent (`CREATE IF NOT EXISTS` / `UPDATE`). Apply via the
D1 connector or `make migrate-bracket`. Current data: 32 teams, 16 matches.

## Build / verify / deploy

- **Build**: `make build-bracket` (typecheck + wrangler dry-run bundle).
- **Verify**: `make bracket-render-test` (Chrome Canary, iPhone 16 Pro emulation).
- **Deploy**: `.github/workflows/wc2026.yml` deploys `wc2026-bracket` on merge to
  `main`. The Secrets Store `store_id` should be resolved from the CF API by name
  at deploy time (a repo variable is only a fallback) — never pasted by a human.

## A2A

- Discovery: `GET /.well-known/agent-card.json` (skills `get_bracket`, `update_bracket`;
  `contextUrl` points peers at the context document).
- `POST /a2a` (`tasks/send`) → returns the bracket as a data artifact.
