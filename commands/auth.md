---
description: One-shot auth check for everything fe-toolkit needs - OAuth into the MCP servers (Atlassian + Figma + Statsig) and verify the Databricks CLI for the tubi-dev workspace. Run this once after install.
---

Authenticate every backend that fe-toolkit needs in one shot, and verify each one with a real call. MCP OAuth flows open in your browser and cache tokens in the system keychain; the Databricks CLI uses its own login and `~/.databrickscfg`.

## What gets verified

| Logical name | Tool prefix / binary | Provided by | Endpoint |
|---|---|---|---|
| `plugin:fe-toolkit:atlassian` | `mcp__plugin_fe-toolkit_atlassian__*` | this plugin's `.mcp.json` | `https://mcp.atlassian.com/v1/mcp/authv2` |
| `plugin:figma:figma` | `mcp__plugin_figma_figma__*` | the `figma@claude-plugins-official` dependency | `https://mcp.figma.com/mcp` |
| `plugin:fe-toolkit:statsig` | `mcp__plugin_fe-toolkit_statsig__*` | this plugin's `.mcp.json` | `https://api.statsig.com/v1/mcp` |
| `databricks` (CLI) | `databricks` binary | the Databricks CLI (used by `/fe-toolkit:web-vitals-experiment`) | `https://tubi-dev.cloud.databricks.com` |

Statsig is authenticated up front even though today's `/fe-toolkit:web-vitals-experiment` only *proposes* experiments — it never calls a write tool. Getting OAuth out of the way now means a future skill that actually creates the Statsig experiment (gate, group, params) can do so without a fresh auth detour.

## Procedure

For **each** of `plugin:fe-toolkit:atlassian`, `plugin:figma:figma`, and `plugin:fe-toolkit:statsig`, in order:

1. Check whether the server already has a working session by attempting a trivial read-only tool call:
   - For atlassian, prefer the smallest "ping"-like tool the server exposes (e.g. `mcp__plugin_fe-toolkit_atlassian__getAccessibleAtlassianResources`, `mcp__plugin_fe-toolkit_atlassian__getAtlassianUserInfo`, or whatever the server lists as cheapest in its tool descriptions). Pick by description, not by hard-coded name.
   - For figma, prefer the smallest read tool (e.g. `mcp__plugin_figma_figma__get_me`, `mcp__plugin_figma_figma__list_files`, or similar — again, pick by description).
   - For statsig, prefer the smallest read-only list tool (e.g. `mcp__plugin_fe-toolkit_statsig__Get_List_of_Experiments` or `mcp__plugin_fe-toolkit_statsig__Get_List_of_Gates` — again, pick by description; never call a `Create_*`/`Update_*`/`Delete_*` tool just to probe auth).
   - If the call returns data successfully, mark the server as **already authenticated** and move on.

2. If the trivial call fails with a permissions / auth / not-authenticated error, invoke the auto-generated authenticate tool:
   - `mcp__plugin_fe-toolkit_atlassian__authenticate` for atlassian
   - `mcp__plugin_figma_figma__authenticate` for figma
   - `mcp__plugin_fe-toolkit_statsig__authenticate` for statsig

   This will open a browser tab to the provider's OAuth consent page. Tell the user in chat:

   > A browser tab has opened to authenticate `<server>`. Sign in and approve the requested scopes; this window will resume automatically when the OAuth callback completes.

3. After the authenticate tool returns, re-run the trivial read-only call from step 1 to confirm the token works. If it still fails, surface the verbatim error and stop — do not loop.

## Databricks CLI (workspace data access)

The `/fe-toolkit:web-vitals-experiment` command reads Web Vitals data through the `databricks` CLI, which authenticates separately from the MCP servers and must point at the **tubi-dev** workspace (`https://tubi-dev.cloud.databricks.com`). Verify it like this:

1. Confirm the CLI is installed: run `command -v databricks`. If it is missing, mark databricks as `✘ CLI not installed` and tell the user:

   > Install the Databricks CLI (`brew install databricks`, or see the Databricks docs), then run `databricks auth login --host https://tubi-dev.cloud.databricks.com`.

   Stop the databricks check here.

2. List profiles and look for the tubi-dev workspace: run `databricks auth profiles`. It prints `Name  Host  Valid`. Find the row whose **Host** is `https://tubi-dev.cloud.databricks.com` (match on the host, not the profile name — the name is user-chosen). Note that profile's name as `<profile>`.

   - **No row for that host** → databricks is `✘ no tubi-dev profile`. Tell the user:

     > Run `databricks auth login --host https://tubi-dev.cloud.databricks.com`. A browser tab opens for OAuth; accept the default profile name or pick one.

   - **Row exists but `Valid` is `NO`** (expired/revoked) → databricks is `✘ token expired`. Tell the user to re-run the same `databricks auth login --host https://tubi-dev.cloud.databricks.com`.

   - **Row exists and `Valid` is `YES`** → continue to step 3.

3. Confirm with a real call (mirrors the MCP post-auth verification): run `databricks current-user me -p <profile>`. If it returns the user, mark databricks as `✓ tubi-dev as <user>`. If it errors, surface the verbatim error and point the user at `databricks auth login --host https://tubi-dev.cloud.databricks.com`.

Do not read, paste, or modify any Databricks token or `~/.databrickscfg` contents yourself — the only legitimate path is `databricks auth login`.

## Output

When all servers are confirmed authenticated, reply with a short status block. Use this exact format so downstream commands can parse it if needed:

```
fe-toolkit auth status
- atlassian:  ✓ authenticated as <user/account if known>
- figma:      ✓ authenticated as <user/account if known>
- statsig:    ✓ authenticated as <user/account if known>
- databricks: ✓ tubi-dev as <user>

Ready. You can now run /fe-toolkit:plan-ticket <TICKET-ID> or /fe-toolkit:web-vitals-experiment.
```

If any target failed, still emit the block with the failed one marked `✘ <error>`, and tell the user the concrete next step (e.g. "Re-open `/mcp` interactively and click Authenticate on the figma row", "Check `claude mcp list` to confirm the server is registered", or "Run `databricks auth login --host https://tubi-dev.cloud.databricks.com`"). The databricks and statsig targets are only required for `/fe-toolkit:web-vitals-experiment` (statsig is forward-looking — see above), so a databricks-only or statsig-only failure does not block the Jira/Figma workflow.

## Hard rules

- NEVER attempt to inject, paste, or read any OAuth bearer token directly. The only legitimate path is the browser flow triggered by `mcp__<server>__authenticate`.
- NEVER skip the post-auth verification call in step 3. Claude Code has known bugs where the UI says "authenticated" but the token isn't actually honored (see Claude Code issue #60260); the verification call catches this.
- NEVER call a Statsig write tool (`Create_*`, `Update_*`, `Delete_*`, `*_Review`, `Commit_*`, `Approve_*`, `Reject_*`) as part of this auth check — only read-only list/get tools are used to verify the session.
- If the user has not yet installed the `figma@claude-plugins-official` plugin (i.e. `mcp__plugin_figma_figma__*` tools are not visible at all), say so explicitly and tell them to run `claude plugin marketplace update tubi-fe && claude plugin update fe-toolkit@tubi-fe` to pick up the dependency.
