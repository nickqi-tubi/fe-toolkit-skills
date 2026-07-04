# Web Vitals staging verification reference

Load this on demand from `SKILL.md`. It holds gh workflow invocations, staging URL derivation, the well-known deviceId convention, the batch multi-entry override PATCH (primary) and web-modal per-arm fallback, bucket confirmation, Playwright snippets, override persistence, and PR body merge logic.

## Staging URL derivation

From [www/.github/workflows/release.yaml](https://github.com/adRise/www/blob/master/.github/workflows/release.yaml) (Setup environment step):

| `ENV` input | `PLATFORM` | Public URL                              |
| ----------- | ---------- | --------------------------------------- |
| `staging-1` | `new-web`  | `https://web-1.staging-public.tubi.io/` |
| `staging-2` | `new-web`  | `https://web-2.staging-public.tubi.io/` |
| `staging-3` | `new-web`  | `https://web-3.staging-public.tubi.io/` |
| `staging-4` | `new-web`  | `https://web-4.staging-public.tubi.io/` |
| `staging-5` | `new-web`  | `https://web-5.staging-public.tubi.io/` |

`dns_name` = platform with `new-` prefix stripped (`new-web` → `web`). Append the target route path for the page under test.

**Guard:** `new-web` + `staging-5` + `USE_PROD_API=true` is blocked by `release.yaml` — use another slot for prod API data.

## GitHub Actions deploy

Dispatch (requires `workflow` scope on `gh` token):

```bash
gh workflow run release.yaml --ref <branch> \
  -f ENV=staging-N \
  -f PLATFORM=new-web \
  -f USE_PROD_API=false
```

Poll recent runs:

```bash
gh run list --workflow=release.yaml -L 10 \
  --json displayTitle,headBranch,createdAt,status,conclusion,url,databaseId
```

Watch a specific run:

```bash
gh run watch <run-id> --exit-status
gh run view <run-id> --log-failed
```

**Run name filter:** `displayTitle` matches `Deploy to new-web(staging-N)` (from workflow `run-name: Deploy to ${{ inputs.PLATFORM }}(${{ inputs.ENV }})`).

**Fork PR guard:** `gh workflow run --ref <branch>` resolves refs on the upstream repo. Confirm with `git ls-remote --heads origin <branch>` before dispatching.

## Staleness check (already-deployed path)

Before trusting a slot the developer says is "already deployed", don't take it on faith:

```bash
gh run list --workflow=release.yaml -L 5 \
  --json displayTitle,headBranch,createdAt,status,conclusion,url
```

1. Find the latest run with `conclusion: "success"` whose `displayTitle` matches `Deploy to new-web(<staging-N>)`.
2. Compare its `headBranch` against the resolved target branch, and its `createdAt` against "now".
3. Flag it if: the branch doesn't match, the run failed/is missing entirely for that slot, or `createdAt` is suspiciously old (someone may have redeployed `master` or a different PR over it since). Surface the mismatch explicitly and ask the developer to confirm they still want to proceed — don't block outright (they may know about a manual redeploy the run history doesn't show), but never silently proceed past a detected mismatch.

If no successful run is found for that slot at all, say so plainly rather than guessing at a URL.

## Experiment candidate discovery

```bash
git diff master...HEAD --name-only -- 'src/common/experimentV2/configs/*.ts'
```

Read each changed config for:

- `name` field (Statsig experiment id, e.g. `webott_web_episode_ssr_perf`)
- `defaultParams` / group union types → param names and variant values
- Cross-check with `doc/web-vitals/*.md` Shipping status (Statsig console link, branch, PR)

**Statsig MCP verify** (after developer confirms id at GATE B):

- `Get_Experiment_Details_by_ID` with `path_id: "<experiment id>"`
- Require `status` in `setup` | `active`, `idType: device_id`
- Capture `groups[].name` exactly — these are `groupID` values for overrides

## Why not natural bucketing?

Experiments created by `web-vitals-experiment` ship pipeline stay in **`setup`** (never started). Natural allocation yields **control for everyone**. Device-ID overrides work in `setup` and are honored server-side for SSR.

## Well-known deviceId convention

Assign each arm a fixed, low-entropy UUID so overrides are deterministic and reusable (developers can set the cookie by hand for manual testing):

| Arm | deviceId |
|-----|----------|
| control (arm 1) | `00000000-0000-0000-0000-000000000001` |
| first variant (arm 2) | `00000000-0000-0000-0000-000000000002` |
| next variant (arm 3) | `00000000-0000-0000-0000-000000000003` |
| ... | `00000000-0000-0000-0000-00000000000N` |

`N` follows the arm order from the Statsig GET response (control first). Record the concrete arm→deviceId→`groupID` map for the report and PR so others can reuse it. These ids are intentionally **kept** — never cleaned up (see "Override persistence").

## Device-ID override — www implementation

Source: [src/common/features/StatsigExperimentsDev/statsigExperimentsApi.ts](https://github.com/adRise/www/blob/master/src/common/features/StatsigExperimentsDev/statsigExperimentsApi.ts)

- Cookie: `deviceId` (`COOKIE_DEVICE_ID`)
- API: `PATCH https://statsigapi.net/console/v1/experiments/{experimentName}/overrides`
- The endpoint's `userIDOverrides` is a **list of `{ groupID, ids, unitType }` entries** — one PATCH can carry **all arms at once**, and the PATCH **replaces** the whole list with what you send (it is not additive).
- Confirm: `GET .../experiments/{experimentName}/overrides` → each arm's `deviceId` appears under its expected `groupID`.

The Statsig MCP has **no override tool** (no override field on any experiment tool either), so overrides must go through the Console API PATCH (primary) or the web modal (fallback).

**Confirmed — `saveOverrides` is single-entry, full-replace.** The exported `saveOverrides(experimentName, groupName, deviceId, idType)` always sends `overrides: []` plus a **single-entry** `userIDOverrides: [{ groupID, ids: [deviceId], unitType }]`. Because that body replaces the whole list, each call sets exactly one arm and **drops every previously-set arm**. The modal therefore **cannot batch** — this is a hard property of the function, not a suspicion. To hold all arms simultaneously you must issue **one multi-entry PATCH yourself** (below). Note the console key is compiled into the bundle (`__STATSIG_CONSOLE_KEY__`), inside a module closure, so it is not readable from `page.evaluate` — the multi-entry PATCH needs a developer-supplied key.

### Console API batch override (primary)

Requires developer-supplied `STATSIG_CONSOLE_KEY` (same key as `STATSIG_CONSOLE_API_KEY` for codegen). Set **every arm in one PATCH** — this replaces the override list with the complete desired state:

```bash
curl -X PATCH "https://statsigapi.net/console/v1/experiments/${EXPERIMENT_ID}/overrides" \
  -H "STATSIG-API-KEY: ${STATSIG_CONSOLE_KEY}" \
  -H "STATSIG-API-VERSION: 20240601" \
  -H "Content-Type: application/json" \
  -d '{
    "overrides": [],
    "userIDOverrides": [
      { "groupID": "Control",   "ids": ["00000000-0000-0000-0000-000000000001"], "unitType": "device_id" },
      { "groupID": "Variant 1", "ids": ["00000000-0000-0000-0000-000000000002"], "unitType": "device_id" }
    ]
  }'
```

Use **exact** group names from the Statsig GET response. Then confirm once:

```bash
curl -s "https://statsigapi.net/console/v1/experiments/${EXPERIMENT_ID}/overrides" \
  -H "STATSIG-API-KEY: ${STATSIG_CONSOLE_KEY}" \
  -H "STATSIG-API-VERSION: 20240601"
```

Verify every arm's deviceId is present under its expected `groupID`. One GET confirms all arms — no per-arm, per-round re-confirmation.

### Web modal override sequence (per-arm fallback)

Use only when no `STATSIG_CONSOLE_KEY` is available. Because `saveOverrides` is single-entry/full-replace (above), the modal **cannot batch** — you must process one arm at a time (set → confirm → measure that arm → next arm), re-confirming each arm right before its rounds.

Web has **no dedicated URL** for Statsig overrides (unlike OTT `/dev`). The modal opens from the Browse dropdown via `statsigModalOpener?.()` in [BrowseMenu.hook.ts](https://github.com/adRise/www/blob/master/src/web/components/TopNav/Browse/BrowseMenu/BrowseMenu.hook.ts).

Menu item title (exact): **`🔨 Statsig Experiments`** ([BrowseMenu.tsx](https://github.com/adRise/www/blob/master/src/web/components/TopNav/Browse/BrowseMenu/BrowseMenu.tsx)).

Playwright sequence per arm on `https://web-N.staging-public.tubi.io/<route-path>`:

1. `browser_run_code_unsafe`: navigate to target URL (or set `deviceId` cookie then `page.goto`).
2. Open Browse dropdown (click nav Browse trigger — use `browser_snapshot` to locate).
3. `browser_click` element with accessible name `🔨 Statsig Experiments` → opens `StatsigExperimentsModal`.
4. Fill search input with experiment id; click target group radio; click **Save Override(s) & Reload** (PATCH + reload).
5. Re-open modal → click **Check override** for that experiment row → UI shows stored `groupID`.

**Never** use OTT `ott-firetv-hyb-N.staging-public.tubi.io/dev` for web experiments — cross-domain cookie jars require manual copying with no benefit.

### Override persistence (no cleanup)

**Do not remove the overrides after measuring.** The well-known deviceIds persist on purpose so developers can reuse them (set the `deviceId` cookie to `...0001`/`...0002`/... and refresh). Report the arm→deviceId→`groupID` map in the final summary.

- **Clobber risk:** a later web-modal `saveOverrides` on this experiment (single-entry, full-replace) wipes the batch. To restore, re-run the multi-entry PATCH above.
- **Launch cleanliness:** the ids are fictitious low-entropy UUIDs, so honoring them is harmless if the experiment is later started; still, note their existence before the experiment is started for real.

## Bucket confirmation

Confirm the **whole set once** right after the batch PATCH (Step 4) — a single `GET .../overrides` that shows every arm's deviceId under its expected `groupID`. Do not re-confirm per arm or per round on the batch path. (On the no-key per-arm modal fallback, confirm each arm right before its rounds, since a later modal save replaces it.)

Confirmation signals, in order of preference:

1. **Console API GET** / `fetchCurrentOverride(experiment, deviceId)` returns expected `groupID` for each arm.
2. **SSR output difference** — e.g. meta tags, HTML structure, or element attributes that differ by arm (strongest for SSR perf experiments). Optional: many experiments produce no visible HTML difference, so absence of a diff is not a failure.
3. **`window.__EXPERIMENT_INITIALIZE_RESPONSE__`** — secondary only; config keys may be hashed. Do not rely on this alone.

**Bot guard:** [webottWebEpisodeSsrPerfSelector.ts](https://github.com/adRise/www/blob/master/src/common/selectors/experiments/webottWebEpisodeSsrPerfSelector.ts) returns `control` when `isbot(ua)` before reading experiment. Headless UAs may be bot-flagged — use real Chrome UA on context.

Suggested UAs:

- Desktop: `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36`
- Mobile: `Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/124.0.0.0 Mobile/15E148 Safari/604.1`

## Web Vitals capture (Playwright)

Use `browser_run_code_unsafe` with fresh `browser.newContext()` per round. Pre-seed cookie:

```javascript
async (page) => {
  const context = page.context();
  await context.addCookies([
    {
      name: "deviceId",
      value: "<deviceId-uuid>",
      domain: "web-N.staging-public.tubi.io",
      path: "/",
    },
  ]);
  // Optional: await context.setExtraHTTPHeaders or create context with userAgent
  await page.goto("<full-url>", { waitUntil: "load" });

  // Short network-idle settle so late-loading LCP candidates (e.g. hero images)
  // finish before we force-finalize — raw LCP right at `load` can still mutate.
  await page.waitForLoadState("networkidle").catch(() => {});
  await page.waitForTimeout(500);

  // Finalize LCP
  await page.evaluate(() => {
    Object.defineProperty(document, "visibilityState", {
      get: () => "hidden",
      configurable: true,
    });
    document.dispatchEvent(new Event("visibilitychange"));
  });

  return await page.evaluate(() => {
    const nav = performance.getEntriesByType("navigation")[0];
    const fcp = performance
      .getEntriesByType("paint")
      .find((e) => e.name === "first-contentful-paint");
    const lcpEntries = performance.getEntriesByType("largest-contentful-paint");
    const lcp = lcpEntries[lcpEntries.length - 1];
    return {
      ttfb: nav ? nav.responseStart : null,
      fcp: fcp ? fcp.startTime : null,
      lcp: lcp ? lcp.startTime : null,
    };
  });
};
```

- **TTFB:** `navigation[0].responseStart` (ms, Navigation Timing L2).
- **FCP / LCP:** ms from `startTime`.
- Discard round 1; **median** rounds 2..N.
- **Build marker:** scrape footer link text `build ~ <sha>` before/after session for redeploy detection.

## PR body merge

Section markers (idempotent replace):

```markdown
<!-- fe-toolkit:web-vitals-verify:start -->

## Staging verification

... rendered template ...

<!-- fe-toolkit:web-vitals-verify:end -->
```

Algorithm:

1. `gh pr view <pr> --json body -q .body` → save to temp file.
2. If markers exist, replace content between them; else append at end (before AI watermark if present).
3. `gh pr edit <pr> --body-file -` (pipe the merged body on stdin — matches `SKILL.md` Step 7).

Never modify content outside the markers.

## Relative results framing

Caption every table:

> Staging relative deltas (same session, same slot). Not comparable to production/GSC field data P75.

Compare variant median vs control median for TTFB/FCP/LCP. Include spread (min–max or IQR) when sample is small.

## Statsig MCP read-only usage

Allowed for GATE B verification only:

- `Get_Experiment_Details_by_ID`
- `Get_List_of_Experiments`

**Never** call start/launch/update that changes experiment status, allocation, or config — overrides are separate from experiment definition.
