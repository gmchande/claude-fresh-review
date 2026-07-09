---
name: claude-review
description: Manual Claude Code review gate for a current diff, branch, artifact, or coordinated multi-repo change. Launch one visible Zellij review, verify Claude's findings against every included repo, and checkpoint before editing.
---

# Claude Review

Use Claude Code as an independent reviewer. Claude is review input, not authority. Verify every finding against the real files before acting.

## No-Edit Gate

Before the verification checkpoint, do not edit files, run write-producing formatters or generators, stage, commit, or push. Read-only inspection and non-writing validation are allowed.

If the user explicitly asks to review and then fix accepted findings without stopping, send the checkpoint immediately before editing so they can interrupt.

## Launch

1. Confirm the primary repo root. Run from that root, not a parent containing unrelated repos.
2. Use one Claude session for one logical change. For a cross-repo change, choose the repo that owns the operating authority as primary and pass each other repo with `--include-repo PATH`. Do not launch parallel per-repo reviews.
3. Run:

```sh
/path/to/claude-review/scripts/claude_review.rb \
  --intent "Short description of the change"
```

Cross-repo example:

```sh
/path/to/claude-review/scripts/claude_review.rb \
  --include-repo /absolute/path/to/related-repo \
  --intent "Review this coordinated change across both repos"
```

The helper configures a stable per-user Zellij socket automatically and generates collision-safe session names. Use `--doctor` only to check installed dependencies.

Useful options:

- `--include-repo PATH` includes another repo's authority files, status, diff, and eligible untracked text files; repeat as needed.
- `--plan PATH` supplies a spec or PRD.
- `--artifact PATH` adds a document or workflow; it becomes artifact-only when the primary worktree is clean.
- `--base REF` reviews committed branch work.
- `--dry-run` prints the prompt bundle without launching Claude.

Claude has read-oriented tools plus Bash under `bypassPermissions`, so use the helper only with trusted local repos. Likely credential files are excluded from untracked-file bundles, but this is not a secrets scanner.

## Observe

Let the user watch the visible Zellij session. First check the printed done marker after 2-3 minutes, then poll the marker and handoff paths. Read [references/observing-zellij.md](references/observing-zellij.md) only if the run is ambiguous.

Leave the session open for follow-ups. Clean it up only when the user says the review is finished.

## Verify and Stop

After Claude responds:

1. Read the handoff.
2. Re-check status, diffs, untracked files, and supplied artifacts in every included repo.
3. Classify each finding as accepted, rejected, or deferred.
4. Send this checkpoint and stop:

```md
Claude found:
- [short findings]

Codex checked:
- [what the actual cross-repo diff changes]

I agree with:
- [finding]: [why it is real]

I reject or defer:
- [finding]: [why it is noise, historical, speculative, or out of scope]

Implementation plan:
- [smallest edits]
- [focused checks]

Waiting for your go-ahead before I edit.
```

If nothing is actionable, say so and name any residual risk or test gap.

## After Approval

Fix only accepted in-scope findings, rerun focused checks, and summarize the result. Use one follow-up Claude review only when the fixes materially change the diff.
