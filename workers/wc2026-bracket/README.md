# wc2026-bracket — subagentdata.com

World Cup 2026 Round-of-32 **radial bracket** visualiser. Mobile-first,
terminal aesthetic, Canvas 2D with optional WebGPU upgrade.

## Architecture — fully KV-decomposed

The Worker (`src/index.ts`) is **pure routing**: it never embeds page HTML or
match data. Everything lives in the `KV` namespace, so the UI and scores can be
updated **with zero redeploys**.

| KV key    | Contents             | Approx size |
| --------- | -------------------- | ----------- |
| `html`    | Full page HTML       | ~17 KB      |
| `bracket` | Match-data JSON      | ~3.5 KB     |
| (script)  | Just routing logic   | ~2.6 KB     |

The canonical copy of the page HTML lives in `assets/index.html` and is the
source for the KV `html` key.

## Routes

| Route                 | Method | Description                                     |
| --------------------- | ------ | ----------------------------------------------- |
| `/`                   | GET    | Page HTML (from KV `html`)                      |
| `/api/bracket`        | GET    | Raw bracket JSON (from KV `bracket`)            |
| `/api/status`         | GET    | Summarised counts + final results              |
| `/api/update`         | POST   | Replace bracket JSON — `Bearer $UPDATE_SECRET`  |
| `/health`             | GET    | Liveness probe                                  |

`/api/status` returns e.g.:

```json
{ "updated": "...", "done": 3, "live": 1, "upcoming": 12, "total": 16,
  "results": ["RSA 0-1 CAN W:CAN", "..."] }
```

## Deploy & update

```bash
# Deploy the routing Worker
wrangler deploy

# Set the update secret (one-time)
wrangler secret put UPDATE_SECRET

# Update the page HTML (no redeploy needed)
npm run push:html          # wrangler kv key put --binding=KV html --path=assets/index.html

# Update scores (no redeploy needed)
curl -X POST https://subagentdata.com/api/update \
  -H "Authorization: Bearer $UPDATE_SECRET" \
  -H "Content-Type: application/json" \
  --data @bracket.json
```

`/api/update` stamps `meta.updated`, `meta.stage`, `meta.final_date` and
`meta.final_venue` automatically.
