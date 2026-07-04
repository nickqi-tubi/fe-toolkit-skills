---
description: Deploy (optionally) a www branch/PR to a web staging slot, measure Web Vitals per Statsig experiment arm via Playwright with device-ID overrides, and append relative results to the PR description.
argument-hint: "[pr] [env] [experiment] [rounds] [useProdApi]"
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

You are operating as a frontend performance engineer. Your job for this turn is to **verify** an already-implemented Web Vitals optimization on a real SSR staging slot: optionally deploy the branch, force each Statsig experiment arm via device-ID overrides, measure TTFB/FCP/LCP with a non-headless browser, and append the relative arm-vs-control results to the PR description.

This command is **independent** from `/fe-toolkit:web-vitals-experiment` (which proposes and optionally ships optimizations). Run it when the developer wants staging verification — including re-runs against an already-deployed slot.

## Inputs

Optional, space-separated hints: `$ARGUMENTS`

- First token (optional): a `www` PR number (used to resolve branch and write results back).
- Second token (optional): staging environment (`staging-1`..`staging-5`).
- Third token (optional): Statsig experiment id (e.g. `webott_web_episode_ssr_perf`) — treated as a **candidate** only; GATE B still requires explicit confirmation.
- Fourth token (optional): number of cold-navigate rounds per arm (default 6; round 1 discarded as warm-up).
- Fifth token (optional): `useProdApi` (`true`/`false`, default `false`) — only relevant on the deploy path, maps to the `USE_PROD_API` workflow input. Note `staging-5` + `new-web` + `USE_PROD_API=true` is blocked by `release.yaml`; the skill steers to a different slot if needed.

If `$ARGUMENTS` is empty or partial, the skill prompts for missing values at the appropriate gates — never auto-fill staging slot or experiment without developer confirmation.

## Step 1 - Pre-flight: are we in the www repo?

This command only makes sense inside `adRise/www`.

Run `git rev-parse --show-toplevel` and confirm `src/common/utils/webVitalsRoutes.ts` exists under it. If it does not, stop and tell the user:

> This command must be run from inside the `adRise/www` repository. cd into your www checkout and re-run.

## Step 2 - Pre-flight: GitHub CLI + workflow scope

1. Confirm `gh auth status` succeeds and the token includes the `workflow` scope (needed to dispatch `release.yaml`).
2. If `workflow` scope is missing, stop and tell the user to re-authenticate: `gh auth login -s workflow`.

## Step 3 - Pre-flight: Playwright MCP

The skill drives a real browser via the `user-playwright` MCP server (`browser_run_code_unsafe`, `browser_snapshot`, `browser_click`, `browser_navigate`, `browser_evaluate`). If Playwright MCP is not available in this session, stop and tell the user to enable it — this command cannot verify Web Vitals without a browser.

Prefer a **non-headless** Playwright configuration. If the server is headless-only, the skill may override the user-agent to a real Chrome UA (see skill hard rules).

## Step 4 - Invoke the skill

Invoke the `web-vitals-verify` skill. It owns the deploy/reuse gates, Statsig experiment confirmation, the batch device-ID override workflow (one multi-entry Console API PATCH that sets every arm at once using well-known stable deviceIds — `00000000-0000-0000-0000-00000000000N`), Web Vitals measurement (switch the `deviceId` cookie per arm), override persistence (kept for reuse — no cleanup), and PR body update. Follow its instructions exactly, including:

- **GATE A:** deploy now vs already deployed (hard stop).
- **GATE B:** confirm target Statsig experiment (hard stop — never proceed on an unconfirmed guess).

Pass along any hints from `$ARGUMENTS`. For experiment discovery, route URL resolution, and Playwright snippets, consult [reference.md](reference.md) on demand.

## Step 5 - Hand off

End with a concise summary:

- Whether a deploy happened or an existing staging slot was reused (with URL).
- Confirmed experiment id + arms, and the well-known arm→deviceId→groupID map (kept for reuse).
- Relative Web Vitals delta table (arm vs control, same session).
- Override persistence: the deviceIds were intentionally left in place (reusable for manual testing; re-run the batch PATCH if a later modal save clobbers them).
- PR link if the description was updated.

Remind the developer that staging slots are shared (no auto-cleanup of the deployment) and that staging numbers are **relative deltas only**, not production/GSC absolutes.
