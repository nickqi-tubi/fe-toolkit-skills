---
name: web-vitals-experiment
description: Analyze P75 Web Vitals field data from Databricks (core_dev.dsa.perf_web_vitals_daily) and propose a per-device (mobile vs desktop) optimization experiment for the adRise/www web app. Use when the user wants to improve Core Web Vitals / Google Search Console performance, asks about LCP, INP, CLS, FCP, or TTFB by route, mentions perf_web_vitals_daily or webVitals route IDs, or runs /fe-toolkit:web-vitals-experiment.
---

# Web Vitals Optimization Experiment skill

You turn Web Vitals **field data** into a concrete, review-ready **optimization experiment proposal** for the Tubi web app (`adRise/www`). You optimize for **P75**, because the Google Search Console (GSC) Core Web Vitals report classifies URL groups by field-data P75. You design **mobile and desktop as separate experiments** — they share a metric but their bottlenecks and implementations differ.

This skill **proposes**; it does not change `www` behavior, create Statsig experiments, or open PRs. The only files you write are the per-device proposal docs. You pause at three approval gates and never skip past one without an explicit user choice.

## Operating constraints

- Read-only on `www` source. The single allowed write is the proposal doc(s) under `doc/web-vitals/` in the www repo (www's existing docs convention is the singular `doc/`, not `docs/`).
- Web platform only (`platform = 'web'`). The table has no other platform.
- Headline target is one of the three **GSC-ranked** Core Web Vitals: **LCP, INP, CLS**. Treat **FCP** and **TTFB** as diagnostics / guardrails only — never as the headline metric.
- Always keep mobile and desktop separate. If the user did not pin a device, produce one proposal per device for the chosen route+metric.

## Data model (memorize)

Table `core_dev.dsa.perf_web_vitals_daily`, one row per day per cohort:

| column | meaning |
|--------|---------|
| `ts` | date (UTC day) |
| `platform` | always `web` |
| `device_type` | `mobile`, `desktop`, or null (null = unsplit rollup — ignore for ranking) |
| `metric_type` | `LCP`, `INP`, `CLS`, `FCP`, `TTFB` |
| `dimension_key` | the **ROUTE_ID** (e.g. `H`, `MD`, `TS1`); empty string = all-routes rollup; `OTH` = the "other" bucket |
| `p50/p75/p90/p99` | daily percentiles (ms; unitless ratio for CLS) |
| `sample_count` | first-cold-navigate samples that day |

Data provenance: `src/web/utils/reportWebVitals.ts` only reports on cold first navigation (`navigationType === 'navigate'`), which is exactly the SEO/GSC first-impression cohort. So this table is the right proxy for what GSC sees.

## Workflow

Copy this checklist and track progress:

```
- [ ] Step 0: Build the ROUTE_ID -> route map from www
- [ ] Step 1: Query + rank targets (mobile & desktop separately)
- [ ] GATE 1: present candidate shortlist + recommendation, STOP; developer picks route x metric (x device)
- [ ] Step 2: Discover code paths in www for the route
- [ ] Step 3: Rank optimization hypotheses
- [ ] GATE 2: user picks a hypothesis
- [ ] Step 4: Render per-device experiment proposal doc(s)
- [ ] GATE 3 (optional): scaffold experimentV2 config + selector stubs
```

### Step 0 - Build the ROUTE_ID -> route map

Read `src/common/utils/webVitalsRoutes.ts` in the www repo. The `ROUTE_IDS` object maps each `WEB_ROUTES.*` template to a short ID (`H`, `M`, `MD`, `TS1`, ...). Invert it so you can translate every `dimension_key` the data returns into a human route name + path template. Keep the map in memory for the rest of the run.

- `''` (empty) → "all routes (rollup)" — exclude from a route-specific proposal.
- `OTH` → "other / unmapped routes" — exclude from a route-specific proposal (it is not a single page).

### Step 1 - Query and rank

Run the bundled script (it owns the SQL, the GSC P75 thresholds, and the scoring). Always prefix with `bash` so it works on plugin caches that drop the exec bit:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/web-vitals-experiment/scripts/query_web_vitals.sh" \
  --mode rank --days 28
```

Add `--metric`, `--device`, or `--route` to narrow when the user gave a hint. The script returns TSV: `device_type, metric_type, dimension_key, w_p75, total_samples, days_present, status, score`.

- `w_p75` is a **sample-weighted mean of daily P75** over the window — a documented approximation of the period P75 (a true period P75 is not recoverable from daily P75s). State this caveat when you present numbers.
- `status` is `good` / `needs-improvement` / `poor` vs Google's thresholds.
- `score` ranks ROI: `max((w_p75 - good_threshold)/good_threshold, 0) * total_samples`. The relative gap makes the score comparable across metrics with different units; multiplying by traffic favors the routes that move a GSC group the fastest.

Present **two ranked tables, mobile and desktop separately**, each filtered to the GSC-ranked metrics (LCP/INP/CLS) at the top, with FCP/TTFB shown below as diagnostics. Translate every `dimension_key` to its route name via the Step 0 map. Drop empty / `OTH` rows from the headline ranking (mention them once as caveats). Flag any `dimension_key` that is not in the map as "unmapped — verify webVitalsRoutes.ts".

### GATE 1 - Pick the target

**This is a hard stop. You present options; the developer decides. Never auto-advance to Step 2 on your own judgement.**

Below the two ranked tables, output a short **candidate shortlist** — the top 3-5 `route x metric x device` targets — as a numbered list the developer can pick from. For each candidate give one line of rationale so the choice is informed, not blind:

```
Recommended targets (pick one, or name your own route x metric x device):

1. [RECOMMENDED] movieDetail (MD) · LCP · mobile — w_p75 4.8s (poor), 1.2M samples/28d.
   Highest score: worst GSC band on the highest-traffic SEO route; moving it flips a whole GSC group.
2. home (H) · LCP · mobile — w_p75 3.1s (needs-improvement), 3.4M samples/28d.
   Most traffic overall; smaller gap but a small win touches the most users.
3. tvShowDetail (TS) · CLS · desktop — w_p75 0.28 (poor), 240k samples/28d.
   Only poor CLS route; layout-shift fixes are usually low-risk.

Which target should the experiment optimize? (reply with a number, or your own route/metric/device)
```

Rules for this gate:

- **If the user pinned all three of route + metric + device via `$ARGUMENTS`**, treat that as the choice: echo the matching row for confirmation and you may proceed once confirmed.
- **If the user pinned only some dimensions** (e.g. just a route, or just a metric), filter the shortlist to what they pinned and still stop for them to choose among the remaining candidates. Do not fill in the missing dimensions yourself.
- **If the user passed no args**, always present the shortlist above and stop. Do not pick for them even when there is an obvious top score — label your top pick `[RECOMMENDED]` and explain why, but wait for their reply.
- Prefer `poor` status and high `total_samples` when ordering the shortlist and choosing which one to mark `[RECOMMENDED]`.
- Do not proceed to Step 2 until the developer has explicitly named a target. If they want both devices for one route+metric, produce two proposals.

### Step 2 - Discover code paths

For the chosen route, scout `www` read-only and time-boxed (a handful of tool calls):

1. Resolve the route template from `WEB_ROUTES` (the `webVitalsRoutes.ts` import) to its `path`.
2. Find the route handler / page container and the data-fetching entry (`fetchData`, loaders, react-query hooks). `Grep` the route constant and the container name.
3. Identify what plausibly drives the chosen metric on the chosen device:
   - **LCP**: hero/poster image (size, format, `loading`/`fetchpriority`, responsive `srcset`), SSR vs client render of the largest element, blocking fonts/CSS, TTFB upstream.
   - **INP**: heavy event handlers, hydration cost, long tasks, large client bundles on that route.
   - **CLS**: images/embeds without reserved dimensions, late-injected banners, font swap.
4. Note mobile vs desktop differences you actually see in code (responsive components, image sizes, mobile-only modules).

Cite concrete `path:line` references. Do not read the whole codebase.

### Step 3 - Rank optimization hypotheses

Produce 2-4 hypotheses for the chosen target, each as a row with: description, expected impact on the target P75, confidence, complexity, implementation risk, validation strategy, rollback. One hypothesis = one optimization = one experiment group (per the team workflow: one change at a time). Keep mobile and desktop hypotheses distinct where the fix differs.

### GATE 2 - Pick a hypothesis

Recommend the best impact-to-risk hypothesis and ask the user to confirm or pick another. Do not proceed until they pick.

### Step 4 - Render the experiment proposal

Read the template at [templates/experiment-proposal.md](templates/experiment-proposal.md) and render **one doc per device**. For experimentV2 config/selector shape and a worked example, consult [reference.md](reference.md).

Write to www's existing docs directory (the singular `doc/`, not `docs/`):

```
doc/web-vitals/<route-id>-<metric>-<device>-<hypothesis-slug>.md
```

- `<hypothesis-slug>` is a short kebab-case summary of the chosen optimization (e.g. `priority-poster`, `defer-carousel-hydration`). It both names the experiment and prevents collisions when the same `route x metric x device` is revisited with a different hypothesis. Example: `doc/web-vitals/H-LCP-desktop-priority-poster.md`.
- Create `doc/web-vitals/` if it does not exist.
- **Before writing, check whether the target file already exists.** If it does, do not silently overwrite: show the user a one-line summary of the existing file and ask whether to overwrite it, write a new file with a `-<YYYY-MM-DD>` suffix, or cancel. Pick a different slug if the collision is actually a distinct hypothesis.

Each proposal must include:

- Target: route (name + path), metric, device, current `w_p75` + status, target P75 (the next better GSC band, e.g. poor → needs-improvement, or into `good`), and the P75 caveat.
- Hypothesis & rationale, grounded in the Step 2 code citations.
- Proposed `ExperimentDescriptor`: a `webott_web_*` snake_case `name`, the parameter(s) and their union types, and `defaultParams` set to control. Plus the selector file path under `src/common/selectors/experiments/`.
- Variant structure: `control` + one variant per optimization, scoped to one experiment group.
- Primary success metric: P75 of the target metric for that exact route+device cold-navigate cohort, read from this table; include the `query_web_vitals.sh --mode trend` command to baseline it.
- Guardrail metrics: the other two CWVs on the route, plus `sample_count` (no traffic regression) and the FCP/TTFB diagnostics.
- Exposure / bucketing: pin bots to control until there is a verdict (SEO safety) — follow the precedent in `webottWebEpisodeSsrPerf` / `episodeSeriesSsrModeSelector`.
- Rollback plan.

After writing, list the doc paths as markdown links.

### GATE 3 - Optional scaffold

Only if the user explicitly asks, scaffold the **inert** experimentV2 wiring (no behavior change): the config file under `src/common/experimentV2/configs/` and a selector stub under `src/common/selectors/experiments/`, both defaulting to `control`. Do not wire the param into any render path, do not create the Statsig experiment, do not open a PR. Confirm before writing, and follow reference.md exactly.

## Hard rules

- NEVER auto-select the target at GATE 1 when the developer has not pinned all of route + metric + device. Present the candidate shortlist with a labelled recommendation and STOP for their explicit choice — a clear top score is a recommendation to surface, not a decision to make for them. The same "recommend, then wait" rule holds at GATE 2.
- NEVER write outside `doc/web-vitals/` unless GATE 3 scaffolding was explicitly approved.
- NEVER silently overwrite an existing proposal doc; confirm with the user first.
- NEVER pick LCP/INP/CLS *and* a diagnostic (FCP/TTFB) as co-headline metrics — one headline CWV per experiment.
- NEVER merge mobile and desktop into one proposal.
- NEVER auto-start a stopped SQL warehouse; if none is running, tell the user.
- ALWAYS state the weighted-P75 approximation caveat when quoting window numbers.
- ALWAYS map every `dimension_key` through `webVitalsRoutes.ts`; flag unmapped keys instead of guessing.
