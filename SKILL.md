---
name: claude-fresh-review
description: Manual Claude Code review gate for the current diff, branch, or repo artifact. Launch a visible Zellij review, verify Claude's findings against the repo, and checkpoint before editing.
---

# Claude Fresh Review

Launch Claude Code as an independent reviewer. Claude is review input, not
authority: verify every finding against the real repo before acting on it.

## Preflight

Confirm the target repo root. Do not run from a parent directory containing
unrelated repos. Use `--doctor` if the visible review environment is uncertain.

Before the verification checkpoint, do not call `apply_patch`, run
formatters/generators/autofixers, stage, commit, push, or modify repo files.

Allowed before the checkpoint: `git status`, `git diff`, `rg`, `sed`, `nl`,
read-only inspection, and validation commands that do not write files. If a
validation command may write generated files, ask first or defer it.

Exception: if the same user message explicitly says to review and then fix
accepted findings without stopping, send the checkpoint immediately before edits
so the user can interrupt.

## Launch

From the target repo root, run the helper from this skill directory:

```sh
/path/to/claude-fresh-review/scripts/claude_fresh_review.rb \
  --intent "Short description of the change"
```

Replace `/path/to/claude-fresh-review` with the loaded skill directory. Do not
run from the skill directory unless reviewing this skill.

Use:

- `--plan PATH` for spec/PRD context that should judge the diff.
- `--artifact PATH` to include a document, plan, workflow, or prompt. It is
  artifact-only when the worktree is clean; otherwise it reviews the artifact
  alongside the current diff.
- `--intent "..."` when the intent lives only in conversation.
- `--base REF` for already-committed branch work.
- `--dry-run` to inspect the prompt bundle without launching Claude.

Claude does not receive Edit/Write tools, but Bash under `bypassPermissions` is
not read-only. Use this only in trusted local repos and check `git status` after
the run.

## Observe

Let the user watch the visible Zellij/Ghostty session. First check the done
marker after 2-3 minutes, then poll the marker/handoff paths printed by the
helper. The marker holds Claude's exit code. If the run behaves ambiguously,
read [references/observing-zellij.md](references/observing-zellij.md).

## Verify Gate

After Claude responds, verify before editing:

1. Read the handoff.
2. Inspect the actual diff, status, untracked files, and artifact if supplied.
3. Classify each Claude finding as accepted, rejected, or deferred.
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

If there are no actionable findings, say so and include any residual risk or
test gap.

## After Approval

- Fix only accepted, concrete, in-scope issues.
- Keep edits narrow and consistent with the repo.
- Re-run focused checks.
- Summarize changed files and validation.
- If fixes materially change the diff, one follow-up Claude review is reasonable; avoid review loops.
