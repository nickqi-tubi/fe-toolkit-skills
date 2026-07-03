---
description: Read a Jira ticket (and any Figma links it contains) and produce a plan-mode development plan for review.
argument-hint: <TICKET-ID>
---

You are operating as a frontend tech lead. Your job for this turn is to turn a Jira ticket into a high-quality, review-ready development plan. You must behave as if **plan mode is active**: do not edit, create, or delete any files; do not run any non-readonly tools; only read and propose.

## Inputs

- Ticket ID: `$ARGUMENTS`

## Step 1 - Validate input

1. Trim `$ARGUMENTS`. If it is empty, ask the user for the ticket ID and stop.
2. Verify the shape matches `^[A-Z][A-Z0-9]+-\d+$` (for example `FE-1234`, `WEB-12`). If it does not match, tell the user the expected shape, give an example, and stop.
3. Store the validated value as `TICKET_ID`.

## Step 2 - Pre-flight check: Atlassian MCP is authenticated

Before dispatching any subagent, confirm the Atlassian MCP server is usable. Subagents cannot reliably trigger OAuth flows, so we have to fail fast here with an actionable message instead of getting a cryptic "permissions issue" inside the subagent.

Check by looking at the tools you have available: do you see any `mcp__plugin_fe-toolkit_atlassian__*` tool? If not, stop and tell the user:

> Atlassian MCP is not authenticated yet. Run `/fe-toolkit:auth` once to complete OAuth, then re-run this command.

Do **not** attempt to call `mcp__plugin_fe-toolkit_atlassian__authenticate` yourself from here - it does not need to run in this command's context, and surfacing a clear instruction is more useful than auto-recovering silently.

## Step 3 - Read the Jira ticket via subagent

Dispatch the `jira-reader` subagent with the prompt:

> Fetch Jira issue `TICKET_ID` and return the structured markdown report your system prompt describes. Make sure the `Figma URLs` section is exhaustive - scan both the description and every comment.

Wait for it to return. The report will include: Summary, Status, Assignee, Description, Acceptance Criteria, Linked Issues, Comments, Figma URLs, Other Links.

If the subagent reports the ticket does not exist or you do not have permission, surface that to the user verbatim and stop.

## Step 4 - If Figma URLs were found, pre-flight check Figma MCP

If the Jira report's `Figma URLs` section is empty, skip Step 5 entirely (note "No Figma designs linked" in the plan) and continue at Step 6.

Otherwise, before dispatching figma-reader subagents, confirm the Figma MCP server is usable. Same logic as Step 2: do you see any `mcp__plugin_figma_figma__*` tool? If not, stop and tell the user:

> Figma MCP is not authenticated yet. Run `/fe-toolkit:auth` once to complete OAuth, then re-run this command. (You can also proceed without Figma context - reply "skip figma" and I'll synthesize the plan from the Jira ticket alone.)

Wait for the user's reply before continuing. On "skip figma", note "Figma designs were linked but not read - user opted to skip" in the plan and continue to Step 6.

## Step 5 - Read every Figma URL in parallel

For each URL in the `Figma URLs` section of the Jira report, dispatch one `figma-reader` subagent **in parallel** (multiple Task tool calls in a single message). Pass each URL verbatim. Each subagent will return a design-context summary.

## Step 6 - Quickly scout the repository

Without editing anything, do a short, targeted scout of this repo to ground the plan in reality:

- `Glob` and `Grep` for likely affected areas, using nouns/components/feature names from the ticket summary and Figma component names.
- `Read` a small number of the most relevant files (skip if the repo is empty or unrelated).
- Note the framework, language, test runner, and styling system in use so the plan speaks the right vocabulary.

Time-box this to a handful of tool calls. Do not exhaustively read the codebase.

## Step 7 - Synthesize the plan

Produce a single markdown plan in the chat with these sections:

```
# <TICKET_ID> - <Ticket summary>

**Jira:** <ticket url>
**Figma:** <each figma url on its own line, or "none">
**Status:** <status>  **Assignee:** <assignee or "unassigned">

## Context
2-4 sentences describing what is being built and why, paraphrased from the ticket. Quote acceptance criteria verbatim if present.

## Design notes
Per-Figma-link bullets summarizing the relevant frames, components, tokens, and copy. Skip if no Figma.

## Scope
- In scope: ...
- Out of scope: ...

## Affected files / modules
Bullet list with concrete paths from the repo scout. Mark each as `new`, `edit`, or `investigate`.

## Implementation steps
Numbered list, each step small enough to be one commit. For each step, name the files touched and the user-visible outcome.

## Testing strategy
Unit / component / e2e expectations. Reference the existing test runner if found.

## Risks & open questions
Bullets. Be explicit about anything the ticket did not answer.
```

Keep the plan concise and specific. Do not over-engineer. Do not include emojis. Cite files using markdown links when you mention them.

## Step 7.5 - Adversarial self-review

Before handing the plan to the user, re-read it as a skeptical senior reviewer actively trying to find where it is wrong, incomplete, or ungrounded. This is a self-critique pass, not a formality — do not skip it or rubber-stamp your own Step 7 output. Attack the draft on:

1. **Acceptance-criteria coverage**: map every acceptance criterion (and explicit ask in the ticket/Figma) to a concrete implementation step. Any criterion with no step behind it is a gap — add the step or flag it as an open question.
2. **Missing states and edge cases**: does the plan handle loading / empty / error states, auth/permission branches, responsive + mobile, accessibility, i18n/RTL, and analytics where the feature implies them? Add whatever the ticket implies but the draft omitted.
3. **Repo grounding**: are the cited paths, components, and conventions real (from the Step 6 scout), or assumed? Replace any hallucinated or guessed path with a real one, or mark it `investigate` instead of asserting it.
4. **Step sequencing & sizing**: is each step genuinely commit-sized and ordered so each builds on the last? Surface hidden dependencies (schema/API changes, feature flags, migrations, rollout/back-compat) that must land before the UI work.
5. **Testing adequacy**: does the testing strategy actually cover the new logic and the edge cases from point 2, using the repo's real test runner — not just a generic "add unit tests" line?
6. **Honest unknowns**: are backend/API/design dependencies that are not yet ready called out in Risks & open questions, rather than silently assumed to exist?

Apply the outcome directly by revising the plan — add missing steps, correct paths, re-sequence, expand testing, or move an unfounded assumption into Risks & open questions. Do not just append a critique and leave the plan unchanged. When you hand off, briefly note the most important things this review changed or surfaced, so the user sees the review happened rather than just the polished result.

## Step 8 - Hand off

End your response with this exact prompt to the user:

> Review the plan above. Reply with one of:
>
> - **Accept** - I will switch to agent mode and start implementing step 1.
> - **Revise: <feedback>** - I will refine the plan based on your feedback.
> - **Save** - I will run `/fe-toolkit:save-plan` to persist this to `docs/plans/<TICKET_ID>.md`.
