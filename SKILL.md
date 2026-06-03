---
name: claude-fresh-review
description: Run a fresh-eyes Claude Code review of the current git diff using a pragmatic, thorough small-project rubric. Use when the user asks for Claude review, fresh eyes, second opinion, review this diff, check Codex's work, or a balanced non-enterprise code review.
---

# Claude Fresh Review

Use this skill to ask Claude Code for an independent review after Codex has planned or implemented changes, or when a repo artifact such as a plan, design document, workflow instruction, or agent/tooling configuration needs fresh eyes.

The helper runs Claude with local inspection, `Bash`, `WebSearch`, and `WebFetch` so it can inspect the repo, run relevant checks, and verify official docs. It does not grant `Edit` or `Write`, but `Bash` is still shell access; use this helper for trusted local repos and artifacts.

It pins Claude to `claude-opus-4-8`, defaults to `--effort high`, and uses a 10-minute default timeout. Set `CLAUDE_REVIEW_EFFORT=medium` or `CLAUDE_REVIEW_EFFORT=low` for trivial or mechanical diffs. The stable reviewer instructions are passed with `--append-system-prompt`; the repo status, diff, plan, and intent are sent as the user payload.

## Review posture

Ask for a pragmatic, thorough review suitable for serious small projects, experiments, plans, design documents, repo workflows, and agent/tooling setup:

- Care about correctness, broken flows, data loss, privacy/security footguns, confusing structure, missing essential checks, instruction conflicts, unclear ownership, brittle workflow assumptions, and poor fit with the existing project style.
- Verify correctness, completeness, and solidity for the stated purpose.
- For plans and documents, focus on clarity, internal consistency, missing decisions, executable next steps, ambiguous scope, and whether the review is balanced for the stated stakes.
- When a plan or intent is supplied, critique the plan itself as well as whether the diff follows it; a perfectly executed wrong plan is still a review finding.
- Prefer concrete, high-confidence findings that can be fixed with small scoped changes.
- Avoid enterprise SaaS assumptions, speculative scale concerns, broad rewrites, purity refactors, needless abstraction, and "this might matter someday" findings.
- If there are no actionable findings, say so plainly.
- When reviewing tool/CLI behavior, let Claude check official docs rather than relying only on model memory.
- Let Claude run shell commands when that improves review quality, but keep the output focused on findings rather than implementation.

## Workflow

1. Identify the current project or repo root. Do not run this from a parent directory that contains multiple unrelated repos.
2. Include the plan, PRD, or task intent whenever possible:
   - Use `--plan PATH` when a plan/PRD file exists.
   - Use `--intent "..."` when the plan only lives in the conversation.
   - Treat diff-only review as appropriate mainly for trivial or mechanical changes.
3. Run the helper. Resolve the script path relative to this skill directory:

```sh
scripts/claude_fresh_review.rb --intent "Short description of the change"
```

Useful options:

```sh
scripts/claude_fresh_review.rb --plan docs/plan.md
scripts/claude_fresh_review.rb --base main
scripts/claude_fresh_review.rb --base HEAD~1
scripts/claude_fresh_review.rb --output tmp/claude-review.md
scripts/claude_fresh_review.rb --timeout 900
scripts/claude_fresh_review.rb --dry-run
```

## After Claude responds

- Verify each finding against the real code before accepting it.
- Fix only concrete, in-scope issues.
- Briefly reject noisy, speculative, or over-engineered findings.
- Re-run focused checks after fixes.
- If the fixes materially change the diff, one follow-up Claude review is reasonable; avoid endless review loops.
