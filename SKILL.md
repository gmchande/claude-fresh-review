---
name: claude-fresh-review
description: Run a fresh-eyes Claude Code review of the current git diff using a pragmatic, thorough small-project rubric. Use when the user asks for Claude review, fresh eyes, second opinion, review this diff, check Codex's work, or a balanced non-enterprise code review.
---

# Claude Fresh Review

Use this skill to ask Claude Code for an independent review after Codex has planned or implemented changes, or when a repo artifact such as a plan, design document, workflow instruction, or agent/tooling configuration needs fresh eyes.

The helper launches Claude in a new, one-off visible Zellij session with local inspection, `Bash`, `WebSearch`, and `WebFetch` so it can inspect the repo, run relevant checks, and verify official docs. It opens a Ghostty tab attached to that Zellij session before sending the review task. It does not grant `Edit` or `Write`, but `Bash` is still shell access and runs with `--permission-mode bypassPermissions`; use this helper only for trusted local repos and artifacts. If the requested Zellij session name already exists, the helper exits instead of reusing it.

It defaults Claude to `claude-opus-4-8` and `--effort xhigh`. Set `CLAUDE_REVIEW_MODEL` only when intentionally testing another Claude model; set `CLAUDE_REVIEW_EFFORT=high`, `medium`, or `low` for simpler diffs. The stable reviewer instructions are passed with Claude Code's file-based appended system prompt flag; the repo status, diff, plan, and intent are sent as the user payload.

## Review posture

Ask for a pragmatic, thorough review suitable for serious small projects, experiments, plans, design documents, repo workflows, and agent/tooling setup:

- Care about correctness, broken flows, data loss, privacy/security footguns, confusing structure, missing essential checks, instruction conflicts, unclear ownership, brittle workflow assumptions, and poor fit with the existing project style.
- Verify correctness, completeness, and solidity for the stated purpose.
- For plans and documents, focus on clarity, internal consistency, missing decisions, executable next steps, ambiguous scope, and whether the review is balanced for the stated stakes.
- When a plan or intent is supplied, critique the plan itself as well as whether the diff follows it; a perfectly executed wrong plan is still a review finding.
- Surface concrete behavioral findings with severity and confidence so Codex can verify and filter them afterward.
- Omit enterprise SaaS assumptions, pure style nits, speculative scale concerns, broad rewrites, purity refactors, needless abstraction, and "this might matter someday" findings.
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
scripts/claude_fresh_review.rb --zellij-session feature-review
scripts/claude_fresh_review.rb --dry-run
```

The helper writes the assembled prompt bundle, system prompt, handoff path, and done marker under `/tmp/claude-fresh-review/...`, starts Claude in Zellij, waits for the Claude prompt, accepts the bypass-permissions startup responsibility screen if it appears, opens Ghostty attached to the session, bracket-pastes the review task, and prints attach/inspect/interrupt commands. `ZELLIJ_SOCKET_DIR` must be set in shell startup to a short stable path such as `/tmp/zellij`; if it is missing, the helper exits instead of creating a hidden alternate namespace.

Observation policy: after launching Claude visibly, Codex should let the user be the live observer and should not continuously poll the pane. When Codex needs completion, do the first marker check after 2-3 minutes, then poll the printed done marker cheaply and read the handoff file once it exists. Inspect the pane only on explicit user request, a bounded checkpoint, or to verify a concrete finding. Prefer `zellij list-sessions --short` for liveness and viewport-only `dump-screen` with small output caps. Avoid repeated `dump-screen --full` polling; use full transcript dumps only as diagnostics, preferably written to a temp file. Codex should still verify every Claude finding against the real repo before accepting it.

## After Claude responds

- Before editing anything, give Gaurav a brief, plain triage summary:
  - What Claude found.
  - Which findings Codex agrees with.
  - Why each accepted finding is real or important.
  - Which findings Codex rejects or treats as low-priority noise, and why.
  - What Codex plans to do next.
- Keep this summary short but readable. It should be a decision checkpoint, not a second full review.
- Verify each finding against the real code before accepting it.
- Fix only concrete, in-scope issues.
- Briefly reject noisy, speculative, or over-engineered findings.
- Re-run focused checks after fixes.
- If the fixes materially change the diff, one follow-up Claude review is reasonable; avoid endless review loops.
