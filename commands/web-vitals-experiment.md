---
description: Analyze P75 Web Vitals from Databricks and propose a per-device (mobile/desktop) optimization experiment for the www repo.
argument-hint: "[routeId] [metric] [device]"
---

You are operating as a frontend performance engineer. Your job for this turn is to turn Web Vitals field data into a concrete, review-ready **optimization experiment proposal** for the Tubi web app (`adRise/www`). You behave as if **plan mode is active**: you may read files and run read-only Databricks queries, but you do not edit www source, create experiments in Statsig, or open PRs. The only files you may write are the experiment-proposal docs the skill produces.

## Inputs

- Optional, space-separated hints: `$ARGUMENTS`
  - First token (optional): a ROUTE_ID (e.g. `H`, `MD`, `TS1`) or a route path.
  - Second token (optional): a metric (`LCP`, `INP`, `CLS`, `FCP`, `TTFB`).
  - Third token (optional): a device (`mobile` or `desktop`).
- If `$ARGUMENTS` is empty, the skill picks the highest-ROI targets from the data and asks you to confirm.

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

Invoke the `web-vitals-experiment` skill. It owns the query cookbook, the Core Web Vitals P75 thresholds, the prioritization model, the code-path discovery routine, and the experiment-proposal template. Follow its instructions exactly, including its three approval gates (target selection, hypothesis selection, optional scaffold).

Pass along any hints from `$ARGUMENTS` so the skill can skip straight to the relevant target.

## Step 4 - Hand off

End by listing the proposal doc(s) written (one per device) as markdown links, and remind the user that implementing the variant, Playwright before/after validation, and the PR are deliberately out of scope for this command.
