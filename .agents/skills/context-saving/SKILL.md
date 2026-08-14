---
name: context-saving
description: Save a compact, durable handoff of the current work session when the user asks to preserve context, save progress, create a handoff, prepare for compaction, or resume later.
disable-model-invocation: false
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
---

# Context Saving

## Goal

Maintain a concise continuation document at:

`./agents/context-saving/context.md`

This document must preserve only the information a future agent needs to resume work effectively after compaction, a new chat, or an interrupted session.

## Trigger Conditions

Use this skill when the user asks to:

- Save session state or progress
- Preserve decisions or next steps
- Create a handoff note
- Prepare for context compaction
- Make work resumable in a later session

## Procedure

1. Inspect the current conversation and workspace changes for durable, actionable context.
2. Read `./agents/context-saving/context.md` if it exists.
3. Create `./agents/context-saving/` if it does not exist.
4. Merge useful existing information with the current session state.
5. Remove stale, superseded, duplicated, speculative, or already-resolved details.
6. Overwrite `./agents/context-saving/context.md` with the complete updated document.
7. Verify the saved document includes every required heading below.
8. Do not modify any other file unless required to create the target directory.

## Privacy Rules

Never store:

- Passwords, API keys, tokens, credentials, cookies, or connection strings
- Raw private user data unless the user explicitly requests it
- Full chat transcripts
- Large logs or copied source files

Instead, store concise summaries, sanitized identifiers, file paths, and instructions for where to retrieve necessary information.

## Required File Format

Write `./agents/context-saving/context.md` exactly in this structure:

```md
# Session Context

## Objective
- Current user goals, limited to 1–5 bullets

## Current State
- Work completed
- Relevant files, systems, components, or environments
- Important constraints and assumptions

## Decisions
- Decisions that affect future work
- Rejected approaches only when their rejection matters

## Open Questions
- Unresolved blockers or decisions
- Use `- None` when there are no meaningful open questions

## Next Steps
- The next 3–7 highest-value actions, ordered by priority

## Important Artifacts
- Relevant workspace-relative paths
- Commands, branch names, ticket IDs, URLs, or identifiers needed to continue
- References to external systems, without secrets
```

## Writing Rules

- Prefer concise, factual bullets over prose.
- Write so the document remains useful without access to the previous chat.
- Include concrete names and paths where available.
- Preserve decisions and constraints, not conversational history.
- Use `- None` for required sections that have no applicable content.
- Keep the file compact; prioritize signal over completeness.
- Do not claim that an action was completed unless it was actually completed in the workspace.

## Completion Response

After saving, respond with:

`Saved durable session context to ./agents/context-saving/context.md.`

Also mention one sentence on what was captured, or state that no meaningful new context was available.