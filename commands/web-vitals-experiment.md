---
description: Analyze P75 Web Vitals from Databricks and propose a per-device (mobile/desktop) optimization experiment for the www repo. After proposal approval, can optionally ship end-to-end (Jira, Statsig setup, implementation, draft PR).
argument-hint: "[routeId] [metric] [device]"
allowed-tools:
  - Bash(git rev-parse:*)
  - Bash(git fetch:*)
  - Bash(git checkout:*)
  - Bash(git branch:*)
  - Bash(git add:*)
  - Bash(git commit:*)
  - Bash(git push:*)
  - Bash(git diff:*)
  - Bash(git status:*)
  - Bash(gh pr create:*)
  - Bash(gh auth status:*)
  - Bash(command -v databricks)
  - Bash(databricks auth profiles:*)
  - Bash(bash *query_web_vitals.sh*)
  - Bash(npx browserslist:*)
  - Bash(npx -y browserslist:*)
  - Bash(npx modern-web-guidance@latest:*)
  - Bash(npx -y modern-web-guidance@latest:*)
  - Bash(npx prettier:*)
  - Bash(npx -y prettier:*)
  - Bash(yarn jest:*)
  - Bash(yarn lint:base:*)
---

You are operating as a frontend performance engineer. Your job for this turn is to turn Web Vitals field data into a concrete, review-ready **optimization experiment proposal** for the Tubi web app (`adRise/www`). By default you may read files and run read-only Databricks queries, and write only the experiment-proposal docs under `doc/web-vitals/`. If the developer approves **GATE 3 ("Ship it?")**, the skill continues into the full shipping pipeline (Jira ticket, Statsig experiment in `setup`, www implementation, draft PR).

## Inputs

- Optional, space-separated hints: `$ARGUMENTS`
  - First token (optional): a ROUTE_ID (e.g. `H`, `MD`, `TS1`) or a route path.
  - Second token (optional): a metric (`LCP`, `INP`, `CLS`, `FCP`, `TTFB`).
  - Third token (optional): a device (`mobile` or `desktop`).
- If `$ARGUMENTS` is empty, the skill does **not** decide for you: it ranks the data, presents a shortlist of the highest-ROI `route x metric x device` candidates (each with a one-line rationale and a labelled recommendation), and stops at GATE 1 for you to choose. Partial hints (e.g. only a route) just narrow that shortlist — the skill still stops for you to pick the rest.

## Step 1 - Pre-flight: are we in the www repo?

This command only makes sense inside `adRise/www`, because it discovers code paths and proposes changes there.

Run `git rev-parse --show-toplevel` and confirm the file `src/common/utils/webVitalsRoutes.ts` exists under it. If it does not, stop and tell the user:

> This command must be run from inside the `adRise/www` repository (it needs `src/common/utils/webVitalsRoutes.ts` to map route IDs and to scout code paths). cd into your www checkout and re-run.

## Step 2 - Pre-flight: Databricks CLI is authenticated

The skill reads `core_dev.dsa.perf_web_vitals_daily` via the `databricks` CLI.

1. Confirm the CLI exists: `command -v databricks`. If missing, stop and tell the user to install the Databricks CLI and run `databricks auth login`.
2. Confirm a usable profile: `databricks auth profiles`. If no profile shows `VALID = YES`, stop and tell the user to run `databricks auth login` (or set `DATABRICKS_CONFIG_PROFILE`).

If a Databricks MCP server is available in this session, you may prefer it over the CLI, but the CLI path is the supported default.

## Step 3 - Invoke the skill

Invoke the `web-vitals-experiment` skill. It owns the query cookbook, the Core Web Vitals P75 thresholds, the prioritization model, the code-path discovery routine, the experiment-proposal template, **Modern Web Guidance** consultation gated by www's `browserslist`, and (when GATE 3 is approved) the shipping pipeline. Follow its instructions exactly, including its three approval gates (GATE 1: target selection, GATE 2: hypothesis selection, GATE 3: "Ship it?").

After code-path discovery, the skill searches and retrieves [Modern Web Guidance](https://github.com/GoogleChrome/modern-web-guidance) guides via `npx` (requires network). It reads www's `browserslist` from `package.json` (or `.browserslistrc`) and resolves it with `npx browserslist`; any optimization that uses a browser feature outside that matrix must include a concrete fallback so functionality is unaffected on unsupported browsers. If `npx`/network is unavailable, the skill skips MWG and notes that in the proposal.

Pass along any hints from `$ARGUMENTS` so the skill can skip straight to the relevant target.

## Step 4 - Hand off

End by listing the proposal doc(s) written (one per device) as markdown links.

- If GATE 3 was **not** approved: remind the user that implementing the variant, Playwright before/after validation, and the PR are out of scope until they approve GATE 3 on a follow-up run.
- If GATE 3 **was** approved: list the created Jira ticket, Statsig experiment (in `setup` — not started), branch, and draft PR links. Remind the user that **starting the Statsig experiment is manual** and should happen only after the code is tested and shipped to production.
