---
description: Persist the most recently produced plan to docs/plans/<TICKET-ID>.md.
argument-hint: "[TICKET-ID]"
---

Persist the development plan that was just produced in this conversation to a markdown file under `docs/plans/`.

## Inputs

- Optional ticket ID override: `$ARGUMENTS`
- Otherwise, infer the ticket ID from the most recent plan in this conversation (it should appear in the plan's title and a `**Jira:**` line).

The ticket ID (from either source) must match `^[A-Z][A-Z0-9]+-\d+$` before it is used - the `save-plan` skill re-validates this because the value becomes part of the write path. If `$ARGUMENTS` is a non-conforming value, do not pass it through; ask the user for a canonical key.

## Procedure

Invoke the `save-plan` skill. The skill knows the template, the destination path, and how to handle overwrites. Follow its instructions exactly.

If no plan exists in this conversation yet, tell the user to run `/fe-toolkit:plan-ticket <TICKET-ID>` first, and stop.

When the file has been written, reply with:

- The path that was written (as a markdown link).
- A one-sentence reminder that the plan is now in version control reach and can be committed via `/fe-toolkit:commit`.
