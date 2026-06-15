---
name: claude-fresh-review
description: Claude Code review delegation for the current diff, plan, or repo artifact. Launches a visible Zellij review and has Codex verify, triage, and checkpoint findings before editing.
---

# Claude Fresh Review

This skill gets a fresh-eyes review from Claude Code without turning Claude into
the decision-maker. Claude is another agent: it may miss main-session context,
over-engineer, or be wrong. Codex must treat the review as input to evaluate,
not authority to execute.

## Hard Gate

This is a review workflow first. After Claude responds, Codex must verify, summarize, and stop for the user's approval before changing files.

Before the triage checkpoint is sent and the user approves implementation, do not call `apply_patch`, run formatters/generators/autofixers, stage, commit, push, or otherwise modify repo files.

Allowed before the checkpoint: `git diff`, `rg`, `sed`, `nl`, non-writing test dry-runs, and targeted code inspection. If a validation command may write generated files, ask first or defer it.

Exception: if the same user message explicitly says to review and then fix accepted findings without stopping, send the triage checkpoint immediately before edits so the user can interrupt.

## Inputs And Outputs

Inputs: current repo/artifact, optional `--plan PATH`, optional `--intent "..."`.

Outputs: Claude handoff, Codex triage checkpoint, and only after approval, narrow fixes plus focused validation.

## Reviewer Posture

Ask Claude for pragmatic review of serious small projects, experiments, plans, workflow docs, and agent/tooling setup.

Ask Claude to review the actual diff or artifact, not Codex's implementation summary. Claude should judge the work against, in order:

1. The plan or intent: whether the implementation follows it, and whether any deviation is called out and justified.
2. Project constraints: AGENTS.md/CLAUDE.md rules, stack, style, scope, and safety boundaries.
3. Correctness: bugs, broken flows, data loss, privacy/security footguns, confusing structure, missing essential checks, instruction conflicts, brittle assumptions, and poor fit with project style.

Claude should reject enterprise SaaS assumptions, style nits, speculative scale concerns, broad rewrites, purity refactors, needless abstraction, and "this might matter someday" findings.

When a plan or intent exists, Claude should critique both the plan and whether the diff follows it. A perfectly executed wrong plan is still a review finding.

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

The helper starts Claude in a visible one-off Zellij session, passes repo status/diff/plan/intent through a prompt file with `claude -p`, streams Claude's JSON events through a readable terminal formatter, and prints the handoff path, done marker, attach command, and completion check. It grants Claude `Read`, `Grep`, `Glob`, `Bash`, `WebSearch`, and `WebFetch` under `--permission-mode bypassPermissions`; use only in trusted local repos.

Observation: let the user be the live observer. The pane should show formatted Claude status, text, tool calls, and tool output while the run is active. First check the done marker after 2-3 minutes, then poll the marker cheaply and read the handoff once it exists. The marker holds Claude's exit code: `0` means read the handoff; non-zero means the run failed (crash, auth, interrupt), so inspect the pane and do not treat the handoff as complete. Inspect the pane only on explicit request, a bounded checkpoint, or to verify a concrete finding. Prefer viewport-only `dump-screen`; avoid repeated full transcript dumps.

## Triage Checkpoint

After Claude responds:

1. Read the handoff.
2. Review the actual diff, status, and any untracked files yourself.
3. Verify and classify each finding as accepted, rejected, or deferred.
4. Send this checkpoint and stop:

```md
Claude found:
- [short list of findings]

Codex checked:
- [one-paragraph summary of what the diff actually changes]

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
