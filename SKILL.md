---
name: claude-review
description: Single-session Pi/Kimi K3 review gate for a current diff, branch, plan, artifact, or coordinated multi-repo change. Launch one visible review, let the user steer it, independently judge Kimi's findings against the real files, and stop for approval before editing.
---

# Claude Review

Run one independent Kimi K3 review in the Pi harness. Treat its findings as input, not authority. Keep the `$claude-review` name for compatibility until it is renamed separately.

## Gate

Do not edit, format, generate, stage, commit, or push before the verification checkpoint. Always stop for approval after the checkpoint, even when the user also requested fixes.

## Launch

1. Run from the primary repo root.
2. If this task already has a printed Pi session, keep using it. Never launch another review or retry a failed run without the user's explicit approval.
3. Launch one review:

```sh
/path/to/claude-review/scripts/claude_review.rb \
  --intent "Short description of the change"
```

Useful options:

- `--include-repo PATH` adds another repo's authority, status, diff, and eligible untracked text; repeat as needed.
- `--plan PATH` supplies a plan or PRD and becomes plan-only when the worktree is clean.
- `--artifact PATH` supplies a document or workflow and becomes artifact-only when the worktree is clean.
- `--base REF` reviews committed primary-branch work when no worktree change is available.
- `--dry-run` prints the bundle without launching Pi.

Pi receives only read-only tools. Likely credential paths are excluded from untracked bundles, but this is not a secrets scanner.

## Observe

- Let the user watch the visible Pi session. Press Escape to interrupt the current turn, then type a correction and press Enter. Press Ctrl+D only when finished.
- Poll the printed marker and handoff paths. Marker `0` is complete, `130` is interrupted with Pi still open, `1` is failed, and a missing marker is pending or ambiguous.
- Treat a visibly working TUI as active even when the marker is missing. If Pi fails or exits ambiguously, report that and ask the user; never relaunch automatically.
- Leave the session open for follow-ups until the user says it is finished.

## Verify and Stop

After the latest marker contains `0`:

1. Read the handoff.
2. Independently inspect the primary repo, every included repo, and every supplied artifact enough to understand the change and its material risks. Do not merely summarize Kimi.
3. Verify each finding against the current files and project instructions. Classify it as accepted, rejected, or deferred.
4. Judge whether Kimi's depth and priorities fit the change. Identify material issues it missed and reject pedantry, speculation, or unnecessary redesign.
5. Report this checkpoint and stop:

```md
Kimi reported:
- [short findings]

My independent assessment:
- Actual change: [what it does and its material risks]
- Review quality: [appropriately scoped, overreaching, incomplete, or mixed]
- Missed or under-reviewed: [important omissions, or none]

Accepted:
- [finding]: [why]

Rejected or deferred:
- [finding]: [why]

Implementation plan:
- [smallest edits]
- [focused checks]

Waiting for your go-ahead before I edit.
```

If Kimi reports nothing or gives an incomplete answer, say whether your own inspection supports that conclusion. Do not treat the absence of findings as validation by itself.

## After Approval

Fix only accepted in-scope findings and rerun focused checks. Use the existing Pi session for a follow-up only when the fixes materially change the review target.
