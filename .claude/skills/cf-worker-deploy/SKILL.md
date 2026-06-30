---
name: cf-worker-deploy
description: >
  Deploy and operate Cloudflare Workers in the subagentjobs monorepo
  (workers/wc2026-bracket, workers/web, workers/cron) -- wrangler, D1
  migrations, Secrets Store, and GitHub Actions CI secrets -- executed on the
  user's actual Mac via a terminal-automation tool (Desktop Commander or
  equivalent), not a sandboxed agent shell. Use this skill whenever the user
  asks to deploy a Cloudflare Worker in this repo, run `make deploy-bracket` /
  `migrate-bracket` / `bracket-secret`, apply D1 migrations, provision or
  rotate a Secrets Store secret, wire CLOUDFLARE_API_TOKEN or
  CLOUDFLARE_ACCOUNT_ID into GitHub Actions, or troubleshoot a
  wrangler/D1/secrets-store command that hangs, times out, or behaves
  unexpectedly when run through terminal automation. Also trigger on "ship
  the worker", "push to subagentdata.com", "redeploy wc2026", or any `npm
  install` that mysteriously installs nothing in this repo.
---

# Cloudflare Worker deploy (subagentjobs)

Operational runbook for deploying any Worker under `workers/*` in this repo
(wrangler + D1 + Secrets Store), distilled from the wc2026-bracket production
deploy. General Cloudflare/wrangler mechanics are covered by the `cloudflare`
and `wrangler` skills -- this skill is the stuff specific to *this* repo and
*this* Mac that isn't in any docs.

## Run it on the Mac, not a sandboxed shell

wrangler and gh are authenticated via this Mac's keychain/OAuth session
(account `e6294e3ea89f8207af387d459824aaae`, alex@jadecli.com). A sandboxed
agent shell won't have either installed or authenticated. If you're an agent
without direct access to this Mac's terminal, use a Mac-execution tool (e.g.
Desktop Commander's `start_process`/`interact_with_process`) for every
wrangler/gh/make command below -- don't try to install/authenticate wrangler
fresh in a sandbox, it won't have the credentials.

Confirm you're pointed at the right place before doing anything else:

```
cd workers/<worker-name> && wrangler whoami
```

Should show account `e6294e3ea89f8207af387d459824aaae`. If it shows a
different account or "not logged in", stop and check with the user --
don't run `wrangler login` unprompted, it opens an interactive browser
OAuth flow.

## Gotcha: NODE_ENV=production silently skips devDependencies

This Mac's shell exports `NODE_ENV=production`. Every worker's
`package.json` lists wrangler, typescript, esbuild, and
`@cloudflare/workers-types` as **devDependencies**, so a plain `npm install`
reports "up to date, audited 1 package" and installs nothing -- then `npm
run check` (tsc) fails with `Cannot find type definition file for
'@cloudflare/workers-types'`. It looks like a missing package; it's actually
npm respecting `NODE_ENV` and omitting all dev deps.

Fix, in the specific `workers/<worker-name>/` directory:

```
npm install --include=dev
```

Run this any time a fresh `npm install` reports suspiciously few packages,
before assuming the package.json or registry is broken.

## Gotcha: Secrets Store, not classic `wrangler secret`

Workers here bind secrets via `[[secrets_store_secrets]]` in
`wrangler.toml` (Cloudflare Secrets Store), not the older per-Worker
`wrangler secret put`. Verified against the installed wrangler (4.77.0) in
this repo:

1. Find the **real** store -- don't trust a friendly name from a Makefile
   comment:

   ```
   wrangler secrets-store store list --remote
   ```

   This account already has one store, `default_secrets_store`. Running
   `store create <name>` *without* `--remote` creates a local-only
   placeholder and silently no-ops -- that's why a Makefile target that
   looks like it provisions a store can print "already exists" with no real
   remote store behind it.

2. Create the secret in that store:

   ```
   wrangler secrets-store secret create <real-store-id> --name NAME \
     --scopes workers --remote --comment "..."
   ```

   The interactive value prompt this opens does not reliably render through
   terminal-automation tools -- it can block indefinitely with no visible
   prompt text (a non-fully-interactive PTY issue, not a "wrong store"
   issue). If it hangs, terminate the process rather than waiting it out.

3. Workaround, in order of preference:
   - Pipe the value via stdin redirection if the subcommand accepts it
     (check `--help` first -- flags vary by wrangler version).
   - Otherwise `--value <value>` works but lands the secret in shell
     history. Generate a fresh, single-purpose random value
     (`openssl rand -hex 32`) so the exposure is to something easily
     rotated, and tell the user it touched shell history so they can rotate
     it if they want zero exposure. Never reuse an existing/sensitive
     secret this way.

4. Paste the **store_id** (the UUID-looking string from step 1), not the
   friendly store name, into `wrangler.toml`'s `store_id` field.

## Gotcha: verify D1 by real column names, don't assume

Migration filenames and Makefile comments describe intent, not the literal
schema. Before writing a verification query, get the real columns:

```
wrangler d1 execute <db> --remote --command "PRAGMA table_info(<table>)"
```

(e.g. `fact_match`'s key is `match_id`, not `id`; team columns are
`home_code`/`away_code`, not `home_team`/`away_team`). This repo's migration
runner also treats *any* per-file error as non-fatal ("already applied") and
keeps going -- so a clean `make migrate-bracket` exit doesn't by itself prove
the data is correct. Always follow a migration run with a direct query
against the actual rows (counts, a couple of specific IDs) rather than
trusting exit code 0.

## Deploy checklist

Pattern verified end-to-end on wc2026-bracket; check each worker's own
Makefile targets and package.json scripts before assuming the exact target
names carry over to workers/web or workers/cron.

```
cd workers/<worker-name>
wrangler whoami                      # confirm account
make bracket-secret                  # provision/confirm Secrets Store secret
# paste the real store_id into wrangler.toml (see gotcha above)
make migrate-bracket                 # apply D1 migrations, then verify manually
make deploy-bracket                  # build (tsc) + wrangler deploy
# or: make deploy-bracket-full       # build -> migrate -> deploy -> tag, one shot
```

Verify the live result with `curl` against the actual routes/API endpoints --
don't just trust "Deployed" in the wrangler output. If the deploy touches
anything described as "real-world" data (scores, prices, current events),
spot-check at least one or two values against a live web search before
calling it verified -- migration files or an issue/PR description can be
stale or wrong even when the SQL itself runs cleanly.

## Wiring GitHub Actions

`gh` is pre-authenticated on this Mac (`gh auth status` to confirm).
`CLOUDFLARE_ACCOUNT_ID` and any non-secret IDs (e.g.
`WC2026_SECRETS_STORE_ID`) can be set directly:

```
gh secret set CLOUDFLARE_ACCOUNT_ID --body <id> --repo opencoworkers/subagentjobs
gh variable set WC2026_SECRETS_STORE_ID --body <id> --repo opencoworkers/subagentjobs
```

`CLOUDFLARE_API_TOKEN` is the one piece you can't derive from the existing
`wrangler login` session -- that's a short-lived OAuth login tied to this
Mac, not a static token meant for CI. Ask the user to paste one (scoped to
Workers Scripts:Edit + D1:Edit + Secrets Store:Edit on this account) rather
than trying to repurpose the OAuth session or mint one unilaterally.

## Related skills

- `wrangler` -- general CLI reference (all subcommands, config shapes).
- `cloudflare` -- platform-wide decision tree (KV, R2, Queues, etc. beyond
  what this repo currently uses).

Both installed alongside this skill from
[cloudflare/skills](https://github.com/cloudflare/skills).

## Gotcha: `make migrate-bracket` replays *every* migration, including the seed

`migrate-bracket` loops over every file in `migrations/*.sql`, not just new
ones -- there's no applied-migrations tracking table. `0005_real_bracket.sql`
is a baseline seed (final scores for whatever was final *when that file was
written*, scheduled/null for everything else). Running `make migrate-bracket`
again after pushing live results via `/api/update` replays 0005 and silently
resets any match it seeds back to that baseline -- wiping out real-time
updates for matches that were "scheduled" in the seed but have since gone
live or final. This actually happened once: adding migration 0006 via the
normal `make migrate-bracket` flow reset M05 and M06 from final/live back to
scheduled, and the live scores had to be re-pushed via `/api/update`.

Until the Makefile tracks which migrations are already applied, treat
`make migrate-bracket` as unsafe to run again once any match has gone live:

- Apply a *new* migration file directly instead of looping all of them:
  ```
  wrangler d1 execute subagentjobs-dwh --remote --file migrations/000N_x.sql
  ```
- If you do run the full `migrate-bracket` target after kickoff, immediately
  re-check `/api/status` against what it should be and re-push any matches
  it clobbered.
- Longer term, the real fix is a `_migrations_applied` log table so the
  Makefile only runs files it hasn't seen -- flag this to the user as a
  follow-up rather than assuming it's in scope of the task at hand.

## Gotcha: deterministic kickoff-based live flip (migration 0006+)

`fact_match.kickoff_utc` (added in migration 0006) holds the real-world UTC
kickoff instant for each match, cross-verified by checking that the ET / PT
/ BST kickoff times quoted by a source all convert to the same UTC moment
before trusting them. The `scheduled()` cron handler (runs every 10 minutes
via the existing `[triggers]` in `wrangler.toml` -- no new Cloudflare cron
trigger needed) flips `status: 'scheduled' -> 'in_progress'` once
`kickoff_utc <= now`, independent of `SCORES_SOURCE_URL`. This only turns
the live flag *on* -- it doesn't know the score or final result, so a real
feed or an `/api/update` push is still required to report what actually
happened and to move a match to `'final'`. Before trusting any kickoff time
pulled from a single article, prefer a source that states the same kickoff
in three timezones (e.g. ET/PT/BST) and verify they all land on the same UTC
instant -- single-timezone mentions in search summaries have been wrong here
before (e.g. one source said a Mexico City kickoff was "01:00 local" when it
was actually 19:00 local / 01:00 UTC).
