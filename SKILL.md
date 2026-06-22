---
name: claude-fresh-review
description: Claude Code review delegation for the current diff, plan, or repo artifact. Launches a visible Zellij review and has Codex verify, triage, and checkpoint findings before editing.
---

# Claude Fresh Review

Use this skill to ask Claude Code for an independent review of the current repo
diff, branch, plan, PRD, document, or agent/tooling setup. Claude is review
input, not authority; Codex must verify every finding.

## Gate

After Claude responds, verify the findings against the repo, send a triage
checkpoint, and stop before editing.

Before the checkpoint and approval, do not call `apply_patch`, run
formatters/generators/autofixers, stage, commit, push, or otherwise modify repo
files.

Allowed before the checkpoint: `git status`, `git diff`, `rg`, `sed`, `nl`,
read-only inspection, and validation commands that do not write files. If a
validation command may write generated files, ask first or defer it.

Exception: if the same user message explicitly says to review and then fix accepted findings without stopping, send the triage checkpoint immediately before edits so the user can interrupt.

## Run

Confirm the target repo root. Do not run from a parent directory containing
unrelated repos. From the target repo root, run the helper from this skill
directory:

```sh
/path/to/claude-fresh-review/scripts/claude_fresh_review.rb \
  --intent "Short description of the change"
```

The helper reviews the git repo containing the current working directory. Do not
run from the skill directory unless reviewing this skill. Replace
`/path/to/claude-fresh-review` with the loaded skill directory.

Prefer `--plan PATH` for real plan/PRD context. Use `--intent "..."` when the
plan lives in conversation. Use diff-only review mainly for trivial or
mechanical changes. Useful options: `--base REF`, `--zellij-session NAME`, and
`--dry-run`.

Security note: Claude does not receive Edit/Write tools, but Bash under
`bypassPermissions` is not read-only. Use only in trusted local repos and check
`git status` after the run.

## Review Scope

The helper carries the detailed Claude reviewer prompt. Codex's job is to make
sure Claude reviewed the actual diff or artifact, then verify each finding
against the real repo and reject noise.

## Observe

Let the user watch the visible Zellij/Ghostty session. First check the done
marker after 2-3 minutes, then poll the marker/handoff paths. The marker holds
Claude's exit code: `0` means read the handoff; non-zero usually means the run
failed or was interrupted, but check whether the handoff exists before
discarding it.

If the marker is absent, the review is not complete yet; keep polling until
about 15 minutes have passed. If pane/session inspection says the session is
gone or exited, check the marker and handoff directly before diagnosing or
rerunning. If the session is repeatedly gone/exited and the marker is still
absent after a brief recheck, treat the run as failed or ambiguous. Prefer
viewport-only `dump-screen`; avoid repeated full transcript dumps.

## Triage

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
