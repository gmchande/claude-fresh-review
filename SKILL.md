---
name: claude-fresh-review
description: Run an independent Claude Code review of the current diff, plan, or repo artifact, then force Codex to triage before editing. Use when the user asks for Claude review, fresh eyes, second opinion, review this diff, check Codex's work, or a balanced non-enterprise code review.
---

# Claude Fresh Review

Use this skill to get a fresh-eyes review from Claude Code without turning Claude into the decision-maker. Claude is another agent: it may miss main-session context, over-engineer, or be wrong. Codex must treat the review as input to evaluate, not authority to execute.

## Hard Gate

This is a review workflow first. After Claude responds, Codex must verify, summarize, and stop for Gaurav's approval before changing files.

Before the triage checkpoint is sent and Gaurav approves implementation, do not call `apply_patch`, run formatters/generators/autofixers, stage, commit, push, or otherwise modify repo files.

Allowed before the checkpoint: `git diff`, `rg`, `sed`, `nl`, non-writing test dry-runs, and targeted code inspection. If a validation command may write generated files, ask first or defer it.

Exception: if Gaurav's same message explicitly says to review and then fix accepted findings without stopping, send the triage checkpoint immediately before edits so he can interrupt.

## Inputs And Outputs

Inputs: current repo/artifact, optional `--plan PATH`, optional `--intent "..."`.

Outputs: Claude handoff, Codex triage checkpoint, and only after approval, narrow fixes plus focused validation.

## Reviewer Posture

Ask Claude for pragmatic review of serious small projects, experiments, plans, workflow docs, and agent/tooling setup.

Claude should care about correctness, broken flows, data loss, privacy/security footguns, confusing structure, missing essential checks, instruction conflicts, brittle assumptions, and poor fit with project style.

Claude should reject enterprise SaaS assumptions, style nits, speculative scale concerns, broad rewrites, purity refactors, needless abstraction, and "this might matter someday" findings.

When a plan or intent exists, Claude should critique both the plan and whether the diff follows it.

## Run The Helper

1. Confirm the repo root. Do not run from a parent directory containing unrelated repos.
2. Prefer intent-rich review:
   - Use `--plan PATH` for a real plan/PRD.
   - Use `--intent "..."` when the plan lives in conversation.
   - Use diff-only review mainly for trivial or mechanical changes.
3. Run the helper from this skill directory:

```sh
scripts/claude_fresh_review.rb --intent "Short description of the change"
```

Useful options:

```sh
scripts/claude_fresh_review.rb --plan docs/plan.md
scripts/claude_fresh_review.rb --base main
scripts/claude_fresh_review.rb --base HEAD~1
scripts/claude_fresh_review.rb --zellij-session feature-review
scripts/claude_fresh_review.rb --dry-run
```

The helper starts Claude in a visible one-off Zellij session, passes repo status/diff/plan/intent, and prints the handoff path, done marker, attach command, and completion check. It grants Claude `Bash`, `WebSearch`, and `WebFetch` under `--permission-mode bypassPermissions`; use only in trusted local repos.

Observation: let Gaurav be the live observer. First check the done marker after 2-3 minutes, then poll the marker cheaply and read the handoff once it exists. Inspect the pane only on explicit request, a bounded checkpoint, or to verify a concrete finding. Prefer viewport-only `dump-screen`; avoid repeated full transcript dumps.

## Triage Checkpoint

After Claude responds:

1. Read the handoff.
2. Verify and classify each finding as accepted, rejected, or deferred.
3. Send this checkpoint and stop:

```md
Claude found:
- [short list of findings]

I agree with:
- [finding]: [why it is real and worth fixing]

I reject or defer:
- [finding]: [why it is noise, speculative, already handled, or not worth fixing now]

Implementation plan:
- [smallest concrete edits]
- [focused checks to run]

Waiting for your go-ahead before I edit.
```

Keep it short. If there are no actionable findings, say so and include any residual risk or test gap.

## After Approval

- Fix only accepted, concrete, in-scope issues.
- Keep edits narrow and consistent with the repo.
- Re-run focused checks.
- Summarize changed files and validation.
- If fixes materially change the diff, one follow-up Claude review is reasonable; avoid review loops.
