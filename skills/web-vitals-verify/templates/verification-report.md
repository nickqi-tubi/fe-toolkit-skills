<!-- fe-toolkit:web-vitals-verify:start -->

## Staging verification

_Verified on <staging_url> · <verified_at_utc> · experiment `<experiment_id>`_

> **Note:** Numbers below are **relative staging deltas** measured in the same session on the same staging slot. They are **not** comparable to production or Google Search Console field-data P75.

### Context

| Field          | Value                                             |
| -------------- | ------------------------------------------------- |
| Branch         | `<branch>`                                        |
| PR             | <pr_link_or_number>                               |
| Staging slot   | `<staging_env>`                                   |
| Deploy         | <deploy_status>                                   |
| Workflow run   | <workflow_run_link_or_na>                         |
| Target page    | <full_target_url>                                 |
| Rounds per arm | <rounds> (round 1 discarded; median of remainder) |
| User-agent     | <user_agent_note>                                 |

### Experiment arms (device-ID overrides)

| Arm        | deviceId | Confirmed groupID | Override confirmed via |
| ---------- | -------- | ----------------- | ---------------------- |
| <arm_rows> |

_Example row: `control` · `00000000-0000-0000-0000-000000000001` · `Control` · Console API GET_

### Web Vitals (relative to control)

_Control baseline measured in same session._

| Arm            | TTFB (ms) | FCP (ms) | LCP (ms) | Δ TTFB vs control | Δ FCP vs control | Δ LCP vs control |
| -------------- | --------: | -------: | -------: | ----------------: | ---------------: | ---------------: |
| <results_rows> |

### Verdict

<verdict_paragraph>

### Methodology

1. <deploy_or_reuse_summary>
2. Batch-set all arms via one multi-entry Statsig Console API PATCH using well-known deviceIds (`00000000-0000-0000-0000-00000000000N`); confirmed with a single GET (<console_api_fallback_note>).
3. Measured cold navigations in fresh browser contexts with pre-seeded `deviceId` cookies (switch cookie per arm); non-headless browser with <ua_description>.
4. Captured TTFB (Navigation Timing L2 `responseStart`), FCP, LCP (PerformanceObserver, finalized on `visibilitychange` → hidden).
5. Overrides left in place for reuse (<override_persistence_note>).

### Override persistence

<override_persistence_detail>

<!-- fe-toolkit:web-vitals-verify:end -->
