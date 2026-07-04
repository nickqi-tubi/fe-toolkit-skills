---
name: web-vitals-verify
description: Verify a Web Vitals optimization on adRise/www by optionally deploying a branch/PR to a web staging slot (staging-1..5), forcing each Statsig experiment arm via device-ID overrides on web-N.staging-public.tubi.io, measuring TTFB/FCP/LCP with Playwright (non-headless), and appending relative arm-vs-control results to the PR description. Use when the user runs /fe-toolkit:web-vitals-verify, wants staging Web Vitals verification, Playwright before/after measurement, or to update a PR with staging verification results. Independent from web-vitals-experiment.
allowed-tools:
  - Bash(git rev-parse:*)
  - Bash(git branch:*)
  - Bash(git diff:*)
  - Bash(git ls-remote:*)
  - Bash(gh auth status:*)
  - Bash(gh workflow run:*)
  - Bash(gh run list:*)
  - Bash(gh run watch:*)
  - Bash(gh run view:*)
  - Bash(gh pr view:*)
  - Bash(gh pr edit:*)
---

# Web Vitals staging verification skill

You verify an already-implemented Web Vitals optimization on a **real SSR web staging slot** (`web-N.staging-public.tubi.io`). You measure TTFB, FCP, and LCP per Statsig experiment arm using a **non-headless** browser, report **relative arm-vs-control deltas** (not production/GSC absolutes), and append results to the PR description.

**Deployment is optional** — the developer may already have the branch deployed and only want to re-run measurement. **The target Statsig experiment is always confirmed explicitly** at GATE B.

This skill is **independent** from `web-vitals-experiment` (proposal + ship pipeline). It works on any `www` PR/branch with a Statsig experiment, not only ones this toolkit produced.

The read-only and pre-approved commands (`git`, `gh`) run via this skill's `allowed-tools` frontmatter. Playwright runs via the `user-playwright` MCP server. GATE stops are conversational pauses — wait for explicit developer choice.

## Operating constraints

- **Web platform only.** Deploy with `PLATFORM=new-web`; measure on `https://web-<N>.staging-public.tubi.io/`. Never use OTT dev pages (e.g. `/dev` on `ott-firetv-hyb-*`) for overrides — the web Browse-menu modal must run on the same domain being measured.
- **Relative results only.** Staging infra differs from production; only arm-vs-control deltas measured in the same session are defensible.
- **Setup experiments.** Natural bucketing fails while an experiment is in `setup` (everyone gets control). Always use **deterministic device-ID overrides**: **batch-set all arms once** in a single multi-entry Console API PATCH using **well-known stable deviceIds** (`00000000-0000-0000-0000-00000000000N`, N=1 control, N=2 first variant, ...). Then measure each arm by switching the `deviceId` cookie — never re-override per round.
- **Keep overrides (no cleanup).** The well-known test deviceIds persist so developers can reuse them for manual testing. Do not delete them after measuring.
- **Never start experiments.** Only set device-ID overrides; leave `setup` experiments in `setup`.

For gh invocations, staging URL table, override API shapes, Playwright snippets, and PR body merge logic, consult [reference.md](reference.md).

## Workflow checklist

```
- [ ] Step 0: Pre-flight (www repo, gh workflow scope, branch/PR resolved)
- [ ] GATE A: deploy now vs already deployed — STOP
- [ ] Step 1: Confirm staging slot (deploy path only)
- [ ] Step 2: Deploy via release.yaml (deploy path only)
- [ ] Staleness sanity check (already-deployed path only)
- [ ] Step 3: Resolve staging URL + content/UA pre-checks
- [ ] GATE B: confirm target Statsig experiment exists — STOP
- [ ] Step 4: Batch-set all arms in ONE multi-entry Console API PATCH (well-known deviceIds), confirm the whole set with one GET
- [ ] Step 5: Measure per arm by switching the deviceId cookie (fresh contexts, discard round 1)
- [ ] Step 6: Aggregate relative arm-vs-control deltas
- [ ] Step 6.5: Override persistence (no cleanup) — leave the well-known deviceIds in place
- [ ] Step 7: Write/replace ## Staging verification in PR body
- [ ] Step 8: Report back
```

### Step 0 — Pre-flight

1. Confirm inside `adRise/www` (`git rev-parse --show-toplevel`, `src/common/utils/webVitalsRoutes.ts` exists).
2. Confirm `gh auth status` includes `workflow` scope.
3. Resolve target branch:
   - From `pr` arg: `gh pr view <pr> --json headRefName,headRepository,baseRepository`.
   - Else: `git branch --show-current`.
4. If deploy path may be needed: confirm branch exists on origin (`git ls-remote --heads origin <branch>`). Fork-only PR branches cannot be dispatched via `gh workflow run --ref` on the upstream repo — stop and tell the developer if that's the case.
5. Confirm Playwright MCP (`user-playwright`) is available.

### GATE A — Deploy now, or already deployed? (hard stop)

Always ask first:

> Do you need me to deploy `<branch>` to a staging slot now, or is it already deployed and you just want to (re-)run the measurement?

- **Deploy** → Step 1 → Step 2.
- **Already deployed** → ask which `staging-N`, run staleness check, skip to Step 3.

Never assume deployment is needed.

### Step 1 — Confirm staging slot (deploy path only)

Show the developer:

- Candidate or chosen `env` (`staging-1`..`staging-5`), or ask them to pick.
- Recent activity on that slot:

```bash
gh run list --workflow=release.yaml -L 10 \
  --json displayTitle,headBranch,createdAt,status,conclusion,url
```

Filter rows whose `displayTitle` matches `Deploy to new-web(<ENV>)` (from `release.yaml` `run-name:`).

**Never deploy without explicit confirmed slot.**

If `USE_PROD_API=true` is requested with `staging-5`, warn that `release.yaml` blocks `new-web` + `staging-5` + `USE_PROD_API=true` — pick another slot.

### Step 2 — Deploy (deploy path only)

```bash
gh workflow run release.yaml --ref <branch> \
  -f ENV=<staging-N> -f PLATFORM=new-web -f USE_PROD_API=<true|false>
```

Poll: `gh run list --workflow=release.yaml -L 5 --json databaseId,status,displayTitle,createdAt` (find the run just dispatched), then `gh run watch <id> --exit-status`.

On failure: stop, report failed step/logs link (`gh run view <id> --log-failed`). **Never auto-retry** (shared slot).

Capture the workflow run URL for the report.

### Staleness sanity check (already-deployed path only)

1. `gh run list --workflow=release.yaml -L 5 --json displayTitle,headBranch,createdAt,status,conclusion,url` — find latest **successful** run with `displayTitle` matching `new-web(<staging-N>)`.
2. Compare `headBranch` to target branch and `createdAt` to now.
3. On mismatch or suspicious age, **surface explicitly and ask** the developer to confirm before proceeding. Never silently trust a stale slot.

### Step 3 — Resolve staging URL + content/UA pre-checks

1. **Staging base URL:** `https://web-<N>.staging-public.tubi.io/` where `<N>` is the digit from `staging-N` (see [reference.md](reference.md) "Staging URL derivation").
2. **Target page URL:** append route path from linked `doc/web-vitals/*.md` proposal, PR description, or `webVitalsRoutes.ts` map. For content-detail routes, pick a **known-stable content id** and confirm HTTP 200 before measuring (staging catalog gaps can 404).
3. **Non-bot UA guard:** in a throwaway Playwright context, read `navigator.userAgent`. SSR selectors pin bots to `control` via `isbot(ua)` before experiment evaluation (see `webottWebEpisodeSsrPerfSelector.ts`). If UA is headless/bot-like (`HeadlessChrome`, etc.), create contexts with a real desktop or mobile Chrome UA for override + measurement, and note it in the report.

### GATE B — Confirm target Statsig experiment (hard stop, always)

Never proceed on an unconfirmed guess, even if only one candidate exists.

1. **Candidate discovery** (collect all found):
   - Explicit `experiment` arg.
   - `git diff master...HEAD --name-only` → new/changed files under `src/common/experimentV2/configs/` → read each for experiment id, groups, param shape.
   - `doc/web-vitals/*.md` whose Shipping status Branch/PR matches this branch/PR → Statsig link.
2. **Present and stop:** show candidates (id, groups, param(s), source) or "no experiment auto-detected". Ask developer to confirm or name a different id.
3. **Verify in Statsig:** `Get_Experiment_Details_by_ID` (Statsig MCP). Must resolve with status `setup` or `active`, `idType: device_id`. Capture **exact group names** verbatim for `groupID` in overrides. If experiment exists only in local config but not Statsig, stop — run ship pipeline Step 6 or create manually first.

### Step 4 — Batch-set every arm's override in one PATCH

Natural bucketing fails in `setup`. Assign each arm a **well-known stable deviceId** and set them **all at once** in a single multi-entry Console API PATCH, then confirm the whole set with one GET.

1. Build the arm→deviceId map deterministically: `00000000-0000-0000-0000-00000000000N`, where `N=1` is control, `N=2` the first variant, `N=3` the next, and so on (see [reference.md](reference.md) "Well-known deviceId convention"). Record `{ arm, deviceId, groupID }` for measurement and the report.
2. **Primary — one multi-entry PATCH** (`STATSIG_CONSOLE_KEY` required): send a single `userIDOverrides` array with **one entry per arm** (`{ groupID, ids: [deviceId], unitType: 'device_id' }`). This fully replaces the override list with the complete desired state in one call. See [reference.md](reference.md) "Console API batch override (primary)".
3. **Confirm once:** `GET .../experiments/{id}/overrides` and verify every arm's deviceId maps to its expected `groupID`. A single confirmation covers all arms — no per-arm, per-round re-confirmation needed.
4. Optionally confirm SSR output differs per arm (strongest signal for SSR experiments).

**Fallback — no `STATSIG_CONSOLE_KEY`:** the web Browse-menu modal's `saveOverrides` sends a **single-entry, full-replace** body, so it **cannot batch** — each save clobbers the previous arm. Without a key you must fall back to processing **one arm at a time** (set via modal → confirm → measure that arm immediately → next arm), per [reference.md](reference.md) "Web modal override sequence (per-arm fallback)". Prefer supplying a key so you can batch.

### Step 5 — Measure per arm (switch the cookie)

With all arms already overridden (Step 4), measure each arm by **switching the `deviceId` cookie value** — never re-override. For each arm's fixed `deviceId`, run `rounds` cold navigations (default 6) in a **non-headless** browser. Each round: **fresh incognito context** with that arm's `deviceId` cookie + non-bot UA, then refresh/navigate.

The batch override was confirmed once in Step 4; do not re-confirm per round. (If you are on the no-key per-arm fallback, confirm that arm's override right before its rounds, since a later modal save would have replaced it.)

Metrics (see [reference.md](reference.md) "Web Vitals capture"):

- **TTFB:** Navigation Timing L2 `responseStart`.
- **FCP:** `performance.getEntriesByType('paint')` → `first-contentful-paint`.
- **LCP:** buffered PerformanceObserver, finalize via `visibilitychange` → hidden.

- Discard round 1 (warm-up); report **median** of remaining rounds.
- **Concurrent-redeploy guard:** read build marker (`build ~ <sha>` in footer) at start and end; if changed, discard and warn.

### Step 6 — Aggregate + compare (relative only)

Build a table: arm, TTFB/FCP/LCP (median + spread), **delta vs control** (same session). Caption: **relative staging deltas, not GSC/production absolutes**.

Verdict: does the variant move the target metric in the hypothesized direction? Is delta beyond control run-to-run noise? If too noisy, say so — do not over-claim.

### Step 6.5 — Override persistence (no cleanup)

**Do not delete the overrides.** The well-known test deviceIds are meant to persist so developers can reuse them for manual testing (set the cookie to `...0001`/`...0002`/... and refresh). Report the arm→deviceId map so others can reuse it.

Caveats to note in the report:

- **Clobber risk:** anyone doing a web-modal `saveOverrides` on this experiment (single-entry, full-replace) will wipe the batch. To restore, re-run the Step 4 multi-entry PATCH.
- **Launch cleanliness:** these are fictitious low-entropy UUIDs, so honoring them is harmless if the experiment is later started, but note they exist before starting the experiment for real.

### Step 7 — Write results into the PR

1. Resolve PR number (from arg, proposal doc Shipping status, or ask developer).
2. `gh pr view <pr> --json body -q .body`
3. Render [templates/verification-report.md](templates/verification-report.md) with collected data.
4. Replace or insert the delimited `## Staging verification` section (HTML comment markers — see [reference.md](reference.md) "PR body merge").
5. `gh pr edit <pr> --body-file -`

Never overwrite unrelated PR body content.

### Step 8 — Report back

Summarize: deploy-or-reuse, staging URL, workflow run link (if any), experiment + arms, the well-known deviceId/group mapping (kept for reuse), relative results table, PR link. Remind: shared staging slot, no deployment cleanup, overrides intentionally left in place (reusable but clobberable by a modal save), relative numbers only.

## Hard rules

- NEVER deploy without explicit developer confirmation of which staging slot.
- NEVER assume deployment is needed — always GATE A first; support reuse-existing-deployment path.
- NEVER trust "already deployed" blindly — staleness sanity check + explicit confirm on mismatch.
- NEVER auto-retry a failed deploy.
- NEVER pick or assume the Statsig experiment without GATE B confirmation; verify it exists in Statsig before overrides.
- NEVER rely on natural bucketing — always device-ID overrides (works in `setup`).
- ALWAYS batch-set every arm in ONE multi-entry Console API PATCH (well-known deviceIds), then confirm the whole set with one GET — do not re-override per round.
- ALWAYS use the well-known stable deviceIds (`00000000-0000-0000-0000-00000000000N`) so overrides are reusable by developers.
- NEVER rely on the web modal's `saveOverrides` to batch — it is single-entry, full-replace; each save clobbers the previous arm. It is only the no-key, one-arm-at-a-time fallback.
- NEVER drive overrides from OTT `/dev` or another platform — always the Console API PATCH (or web Browse menu fallback) on `web-N.staging-public.tubi.io`.
- NEVER start, activate, or change experiment status/allocation/config — overrides only.
- NEVER delete the overrides — leave the well-known deviceIds in place for reuse; report the map.
- NEVER run headless without UA override — bot pinning traps all arms in control.
- NEVER present staging numbers as production/GSC values — relative deltas only.
- NEVER overwrite unrelated PR sections — only the delimited verification section.
- ALWAYS fresh context per cold-navigate round; discard round 1; median the rest.
