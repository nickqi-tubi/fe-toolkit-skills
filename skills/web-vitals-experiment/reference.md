# Web Vitals experiment reference

Load this on demand from `SKILL.md`. It holds the Core Web Vitals P75 thresholds, the SQL cookbook behind `query_web_vitals.sh`, the ROUTE_ID map, and the `www` experimentV2 config/selector pattern with a worked example.

## Core Web Vitals P75 thresholds (Google)

The GSC Core Web Vitals report buckets a URL group by the field-data **P75** of each metric. A URL group is only "Good" when all of LCP, INP, CLS are Good.

| metric | unit | Good (P75 ≤) | Poor (P75 >) | GSC-ranked? |
|--------|------|-------------:|-------------:|:-----------:|
| LCP  | ms    | 2500 | 4000 | yes |
| INP  | ms    | 200  | 500  | yes |
| CLS  | ratio | 0.10 | 0.25 | yes |
| FCP  | ms    | 1800 | 3000 | diagnostic only |
| TTFB | ms    | 800  | 1800 | diagnostic only |

`needs-improvement` = between Good and Poor. The headline experiment metric is always one of LCP / INP / CLS; FCP and TTFB are diagnostics that help explain LCP and serve as guardrails.

These thresholds are duplicated in `query_web_vitals.sh` (the `good_thr` / `poor_thr` CASE expressions). Keep the two in sync if Google updates them.

## Prioritization model

For each `(device_type, metric_type, dimension_key)` over the look-back window (default 28 days — chosen as 4 weekly-release cycles and a multiple of 7 to cancel day-of-week seasonality, while giving lower-traffic routes enough samples for a stable weighted P75; it is **not** tied to any GSC window, since the data is our own telemetry, not a GSC export):

```
w_p75        = SUM(p75 * sample_count) / SUM(sample_count)   -- weighted-mean approximation of period P75
total_samples = SUM(sample_count)
score        = MAX((w_p75 - good_thr) / good_thr, 0) * total_samples
confidence   = 'low' if total_samples < min_samples else 'ok'  -- min_samples default 10000
```

- `w_p75` is an approximation: a true period P75 cannot be recomputed from per-day P75s. It is good enough for ranking and for a rough before-number; the real verdict comes from the experiment's own P75.
- Dividing the gap by `good_thr` makes the score comparable across metrics that have different units.
- Multiplying by traffic favors routes whose worst band moves fastest.
- `confidence = low` marks cohorts with too few window samples for the weighted P75 **itself** to be a trustworthy ranking number (default floor: 10k cumulative cold-navigate samples over the window, roughly a few hundred/day). This is deliberately a low, ranking-reliability-only bar — it is not a proxy for "can an experiment on this target reach a verdict quickly." That is a separate, per-target question that Step 3.5 "Traffic sufficiency" answers later with full context, once a single target has been picked; conflating the two would flag the majority of legitimate mid-traffic routes as unreliable when their ranking is actually fine.
- Ranking is per device. Mobile is usually the SEO-critical bucket; still rank desktop separately.

## SQL cookbook

`query_web_vitals.sh --mode rank` runs (filters injected from flags):

```sql
WITH win AS (
  SELECT device_type, metric_type, dimension_key, p75, sample_count
  FROM core_dev.dsa.perf_web_vitals_daily
  WHERE platform = 'web'
    AND ts >= date_sub(current_date(), 28)
    AND device_type IN ('mobile','desktop')
    -- AND metric_type = 'LCP' / device_type = 'mobile' / dimension_key = 'MD'
),
agg AS (
  SELECT device_type, metric_type, dimension_key,
         SUM(p75 * sample_count) / NULLIF(SUM(sample_count), 0) AS w_p75,
         SUM(sample_count) AS total_samples,
         COUNT(*) AS days_present
  FROM win
  GROUP BY device_type, metric_type, dimension_key
)
SELECT device_type, metric_type, dimension_key, ROUND(w_p75, 3) AS w_p75,
       total_samples, days_present,
       CASE WHEN w_p75 <= good_thr THEN 'good'
            WHEN w_p75 <= poor_thr THEN 'needs-improvement' ELSE 'poor' END AS status,
       ROUND(GREATEST((w_p75 - good_thr)/good_thr, 0) * total_samples, 1) AS score,
       CASE WHEN total_samples < :min_samples THEN 'low' ELSE 'ok' END AS confidence
FROM agg /* + good_thr/poor_thr CASE per metric */
ORDER BY score DESC, total_samples DESC;
```

`--mode trend` (needs `--metric`, `--device`, `--route`) returns the daily P75 + sample_count series, for baselining a target before launch and for reading the verdict after:

```sql
SELECT ts, device_type, metric_type, dimension_key, ROUND(p75, 3) AS p75, sample_count
FROM core_dev.dsa.perf_web_vitals_daily
WHERE platform = 'web' AND ts >= date_sub(current_date(), 28)
  AND metric_type = :metric AND device_type = :device AND dimension_key = :route
ORDER BY ts;
```

To run ad-hoc SQL outside the script, submit via the CLI. **Always pass `-p <profile>`** where `<profile>` is the local profile whose host is `https://tubi-dev.cloud.databricks.com` (the script resolves this automatically; `databricks auth profiles` lists candidates):

```bash
databricks api post -p <profile> /api/2.0/sql/statements --json '{"warehouse_id":"<id>","statement":"<sql>","wait_timeout":"30s","format":"JSON_ARRAY","disposition":"INLINE"}'
```

Find a running warehouse with `databricks warehouses list -p <profile>` (the script picks the first `RUNNING` row).

## ROUTE_ID map

`dimension_key` == the ROUTE_ID defined in `src/common/utils/webVitalsRoutes.ts`. Always read that file at runtime (it is the source of truth and changes); this snapshot is only for orientation:

| ID | route | ID | route |
|----|-------|----|-------|
| `H` | home | `MD` | movieDetail |
| `H1` | deprecatedHome | `TS` | tvShowDetail |
| `L` | landing | `SD` | seriesDetail |
| `M` | movies | `SS` | seriesSeasonDetail |
| `TS1` | tvShows | `LD` | liveDetail |
| `L1` | live | `P` | person |
| `MS` | myStuff | `WS` | watchSchedule |
| `S` | search | `C` | collection |
| `SK` | searchKeywords | `U` | upcoming |
| `CI` | categoryIdTitle | `E` | embedIdTitle |
| `CI1` | channelId | `CR` | creators |
| `HU` | hub | `OTH` | other (not a single page) |

Empty `dimension_key` = all-routes rollup. `OTH` and empty are not valid experiment targets — they are not a single page.

## experimentV2 config + selector pattern

A `www` experiment is two small files plus the read at the call site.

1. **Config** — `src/common/experimentV2/configs/<camelCaseName>.ts`:

```ts
import type { ExperimentDescriptor } from './types';

export const webottWebMovieDetailLcp: ExperimentDescriptor<{
  movie_detail_lcp_mode: 'control' | 'priority_poster';
}> = {
  name: 'webott_web_movie_detail_lcp', // Statsig experiment name (snake_case)
  defaultParams: {
    movie_detail_lcp_mode: 'control',
  },
};
```

2. **Selector** — `src/common/selectors/experiments/<camelCaseName>Selector.ts`. Pin bots to control for SEO safety until the experiment has a verdict (precedent: `episodeSeriesSsrModeSelector`):

```ts
import { isbot } from 'isbot';

import { getExperiment, experimentUserSelector } from 'common/experimentV2';
import { webottWebMovieDetailLcp } from 'common/experimentV2/configs/webottWebMovieDetailLcp';
import { userAgentSelector } from 'common/selectors/ui';
import type { StoreState } from 'common/types/storeState';

export type MovieDetailLcpMode = 'control' | 'priority_poster';

export const movieDetailLcpModeSelector = (state: StoreState): MovieDetailLcpMode => {
  if (isbot(userAgentSelector(state).ua)) {
    return 'control';
  }
  const user = experimentUserSelector(state);
  return getExperiment(webottWebMovieDetailLcp, { user }).get('movie_detail_lcp_mode');
};
```

3. **Call site** — the page/component reads the selector and branches the optimization (this wiring is out of scope for the proposal; it is what the eventual implementation PR does).

### Mobile vs desktop in one experiment

Two ways to split, pick per hypothesis:

- **Separate experiments** (preferred when the code paths differ a lot): one `*_mobile` and one `*_desktop` config/Statsig experiment, each scoped via the device selector. Cleanest attribution.
- **One experiment, device-scoped exposure**: a single config, but the selector only opts the targeted device into a non-control variant (read `isMobileDeviceSelector`). Use when the change is shared but you only want to expose one device.

State which split the proposal uses and why.

## Notes

- LCP attribution sub-parts (`lcpTimeToFirstByte`, `lcpResourceLoadDelay`, `lcpResourceLoadDuration`, `lcpElementRenderDelay`, element tag/id/class) are emitted to raw client logs by `reportWebVitals.ts` but are **not** in `perf_web_vitals_daily`. If a hypothesis needs them, note that a raw-client-log query is required — out of scope for this skill's daily-table queries.
- The reported cohort is cold first navigation only, so the table already excludes reloads, bfcache, and SPA transitions — this first-impression / SEO-entry population closely resembles (but is not sourced from) what GSC later reports on.

## Modern Web Guidance integration

The skill consults [Modern Web Guidance](https://github.com/GoogleChrome/modern-web-guidance) (MWG) at Step 2.5 to ground hypotheses in current browser best practices. MWG is invoked via CLI (not a separate skill load):

```bash
npx -y modern-web-guidance@latest search "<metric> <symptom from code discovery>"
npx -y modern-web-guidance@latest retrieve "<id>"
```

If search results are vague or low-similarity, browse all guides:

```bash
npx -y modern-web-guidance@latest list
```

### Browserslist → custom policy

At Step 0, read www's `browserslist` and resolve it:

```bash
npx browserslist
```

Pass the resolved matrix to MWG as the custom browser-support policy (natural language in the agent's evaluation step). MWG guides include Baseline/browser-compat data; compare each recommended feature against the resolved output.

**Fallback rule:** if a guide recommends a feature **not** covered by the resolved browserslist, the hypothesis must specify a concrete fallback (feature detection + graceful degradation) so functionality is unaffected. If no acceptable fallback exists, drop or redesign the hypothesis. Do not write the policy into www's AGENTS.md/CLAUDE.md.

### Metric → starting guides

Use search first; these ids are common starting points when symptoms match:

| metric | MWG guide ids (performance) |
|--------|-------------------------------|
| LCP | `optimize-image-priority`, `optimize-preload-priority`, `optimize-script-priority`, `defer-rendering-heavy-content` |
| INP | `identify-inp-causes`, `break-up-long-tasks`, `schedule-tasks-by-priority`, `defer-work-until-scroll-ends`, `conditional-async-dependencies` |
| CLS | `defer-rendering-heavy-content` (plus layout-stability patterns in `guides/performance/performance.md` — explicit `width`/`height`, font fallbacks) |

### Network fallback

If `npx` or network is unavailable, skip MWG at Step 2.5 and note "MWG consultation skipped (network unavailable)" in the proposal. Hypotheses then rely on Step 2 code discovery only.

## Shipping pipeline (GATE 3 only)

Load this section when the developer approves GATE 3 ("Ship it?"). It holds frozen defaults for Jira, Statsig, branch naming, config codegen, and PR creation. The PR body is **not** templated here — delegate to www's `write-pr-description` skill (`.cursor/skills/write-pr-description/SKILL.md` or `.claude/skills/write-pr-description/SKILL.md` in the www checkout).

### Frozen defaults

| setting | value |
|---------|-------|
| Jira project | `TWEBGROWTH` ("Web Growth") |
| Jira Epic parent | `TWEBGROWTH-336` ("Web Vitals Optimizations") |
| Jira issue type | `Story` |
| Jira label | `platform-web` |
| Branch name | `<JIRA-KEY>-<short-slug>` (e.g. `TWEBGROWTH-512-movie-detail-lcp-mobile`) |
| Statsig org id (console URL) | `43UGszvUzuvL3Z3ispUMFe` |
| Statsig console URL | `https://console.statsig.com/43UGszvUzuvL3Z3ispUMFe/experiments/<id>/setup` |
| Statsig experiment id prefix | `webott_web_` (desktop) or `webott_web_mobile_` (mobile-only) |
| Statsig `idType` | `device_id` |
| Statsig `team` | `4M14G3IETR9JvxdnaUCl9W` ("User Identity & Registration") |
| Statsig `targetApps` | `["web", "web-node-proxy"]` |
| Statsig `allocation` | `100` |
| Statsig `duration` | `21` (days) |
| Statsig `defaultConfidenceInterval` | `"95"` |
| Statsig `bonferroniCorrection` | `false` |
| Statsig `targetingGateID` | `null` (device scoping lives in the selector) |
| Statsig `status` | **`"setup"` — never `"active"`** |

**Primary metrics** (both `user_warehouse`):

- `tvt`
- `qualified_view_days`

**Secondary metrics** (all `user_warehouse`):

- `session_conversion_5min`
- `conversion_5min_new_visitors_d1`
- `tvt_capped_daily`
- `revenue_unbudgeted`
- `visit_days`
- `conversion_5min`
- `registration_rate_active_visitors`

### Jira ticket creation (Step 5)

Use Atlassian MCP `createJiraIssue`:

```json
{
  "cloudId": "tubitv.atlassian.net",
  "projectKey": "TWEBGROWTH",
  "issueTypeName": "Story",
  "parent": "TWEBGROWTH-336",
  "summary": "<proposal title, e.g. Reduce movieDetail LCP via priority poster (+ experiment)>",
  "description": "<markdown: Context / Measurement / Root Cause / Experiment Design / Acceptance Criteria>",
  "additional_fields": { "labels": ["platform-web"] }
}
```

If `parent` is rejected, create the Story without it, then link under the Epic via `createIssueLink` or the Epic-link custom field, and verify the parent stuck.

The **returned ticket key** drives the branch name and all links. Jira URL: `https://tubitv.atlassian.net/browse/<KEY>`.

### Statsig experiment creation (Step 6)

**CRITICAL:** the experiment must **always** remain in `status: "setup"`. Never start it. Starting is manual, post-launch only.

#### 1. Create_Experiment (Statsig MCP)

```json
{
  "params": {
    "application/json": {
      "id": "webott_web_<slug>",
      "name": "webott_web_<slug>",
      "idType": "device_id",
      "hypothesis": "<belief + evidence + expected ranking + kill criteria>",
      "allocation": 100,
      "targetingGateID": null,
      "team": "4M14G3IETR9JvxdnaUCl9W",
      "targetApps": ["web", "web-node-proxy"],
      "groups": [
        {
          "name": "Control",
          "size": 50,
          "parameterValues": { "<param>": "control" }
        },
        {
          "name": "T1 <variant label>",
          "size": 50,
          "parameterValues": { "<param>": "<variant>" }
        }
      ],
      "primaryMetrics": [
        { "name": "tvt", "type": "user_warehouse" },
        { "name": "qualified_view_days", "type": "user_warehouse" }
      ]
    }
  }
}
```

For 3 groups, split sizes evenly with rounding remainder on Control (e.g. 33.4 / 33.3 / 33.3). For mobile-only targets, use id `webott_web_mobile_<slug>`.

#### 2. Fetch-then-update (Statsig MCP)

`Create_Experiment` does not accept `secondaryMetrics`, `duration`, or `status`. After create:

1. `Get_Experiment_Details_by_ID` with `path_id: "<experiment id>"`.
2. `Update_Experiment_Entirely` with `path_id` and `application/json` echoing back the **required** fields from the GET response (`description`, `idType`, `hypothesis`, `groups`, `allocation`, `targetingGateID`, `bonferroniCorrection`, `defaultConfidenceInterval`, `status`) and adding:

```json
{
  "secondaryMetrics": [
    { "name": "session_conversion_5min", "type": "user_warehouse" },
    { "name": "conversion_5min_new_visitors_d1", "type": "user_warehouse" },
    { "name": "tvt_capped_daily", "type": "user_warehouse" },
    { "name": "revenue_unbudgeted", "type": "user_warehouse" },
    { "name": "visit_days", "type": "user_warehouse" },
    { "name": "conversion_5min", "type": "user_warehouse" },
    { "name": "registration_rate_active_visitors", "type": "user_warehouse" }
  ],
  "duration": 21,
  "status": "setup"
}
```

Full-replace semantics: re-sending the fetched object avoids clobbering fields. **`status` MUST be `"setup"`** — if the GET returns `"active"`, treat that as an error.

### Config codegen (Step 7)

Replicate `scripts/codegen-experiment.ts` inline using the experiment payload from Step 6 (no API key needed):

1. **camelCase** the experiment id (lodash `camelCase` rule — `webott_web_foo_bar` → `webottWebFooBar`).
2. For each param key, collect all values across groups → union type (`'control' | 'variant'` or `boolean`).
3. `defaultParams` = control group's `parameterValues`.
4. Write to `src/common/experimentV2/configs/<camelCaseName>.ts`.
5. Write selector to `src/common/selectors/experiments/<camelCaseName>Selector.ts` (bots pinned to `control`).
6. `npx prettier --write` both files.

Template (from `codegen-experiment.ts`):

```ts
import type { ExperimentDescriptor } from './types';

export const <camelCaseName>: ExperimentDescriptor<{
  <param>: <union type from groups>
}> = {
  name: '<experiment id>',
  defaultParams: {
    <param>: 'control',
  },
};
```

### PR creation (Step 9)

Do **not** hand-write the PR body. Follow www's `write-pr-description` skill:

1. Read `.cursor/skills/write-pr-description/SKILL.md` (or `.claude/skills/` mirror).
2. Diff current branch vs `master`.
3. Pull context from the Jira ticket (Step 5).
4. Generate narrative "Which problem" + terse "Main changes", Conventional-Commits title, watermark.
5. Fill Ticket/documents/resources with Jira + Statsig console links.
6. `gh pr create --draft --base master --title <title> --body <body>`.

### Partial-failure recovery

On mid-pipeline failure, report every artifact already created (Jira key + URL, Statsig id + console URL, branch name, PR URL). Never auto-delete. Never silently retry a create. Developer can re-run from the failed step.
