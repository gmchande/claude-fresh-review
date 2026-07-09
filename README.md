# claude-review

A Codex skill that asks Claude Code for an independent review of the current git diff or project artifact.

The intended workflow is simple: use Codex for planning and implementation, then launch Claude Code in a visible Zellij session as an independent reviewer before you keep moving. The review posture is pragmatic and thorough for serious small projects: catch correctness bugs, broken flows, data loss, security footguns, unclear plans, brittle workflow assumptions, and poor fit with the existing project style without drifting into enterprise hardening or speculative architecture review.

The core runner uses Ruby, Git, zsh, Zellij, and the Claude Code CLI. On macOS with Ghostty it opens a watching tab automatically; without Ghostty, the review still runs in Zellij and prints the manual attach command.

## What it does

- Reviews a dirty working tree against `HEAD`, including untracked text files that do not look like credentials.
- Reviews new experiment repos before the first commit by comparing tracked changes to Git's empty tree and bundling untracked text files while skipping likely credential filenames.
- Reviews already-committed work with `--base HEAD~1` or branch work with `--base main`. On dirty trees, `--base` reviews the working tree against the merge base so committed branch work and uncommitted changes are both included.
- Auto-loads `AGENTS.md` and `CLAUDE.md` from the repo root and ancestor directories so Claude sees project shape, stack, taste, and parent guidance before judging the work.
- Accepts plan or PRD context with `--plan`.
- Reviews repo artifacts with `--artifact`; artifact-only when the worktree is clean.
- Accepts conversation-level intent with `--intent`.
- Includes coordinated changes from other Git repos in the same review with repeatable `--include-repo PATH` options.
- Checks local dependencies with `--doctor`.
- Runs Claude Code in a new, one-off visible Zellij session with `claude-fable-5`, xhigh effort, and `--permission-mode bypassPermissions` by default, with streamed output formatted for the terminal.
- Allows `Read`, `Grep`, `Glob`, `Bash`, `WebSearch`, and `WebFetch`.
- Does not grant Claude Code `Edit` or `Write`, but `Bash` is still shell access without per-command permission prompts. Use it for trusted local repos and artifacts.
- Opens a Ghostty tab attached to the Zellij session when available and always prints the exact attach, inspect, and interrupt commands.

## Install

Clone into your Codex skills directory:

```sh
git clone https://github.com/gmchande/claude-review.git "${CODEX_HOME:-$HOME/.codex}/skills/claude-review"
```

If your Codex setup loads personal skills from another directory, clone it there instead.

The helper script should be executable after cloning. If needed:

```sh
chmod +x "${CODEX_HOME:-$HOME/.codex}/skills/claude-review/scripts/claude_review.rb"
```

## Requirements

- Ruby
- Git
- zsh on `PATH`
- Claude Code CLI on `PATH`; tested with Claude Code 2.1.193
- Zellij 0.44+ on `PATH`
- Optional: Ghostty.app installed and registered with macOS for automatic watch-tab opening
- Optional: GitHub CLI, used only to infer the PR base branch when available

The helper uses `ZELLIJ_SOCKET_DIR` when already set. Otherwise it automatically uses a stable per-user path under the system temporary directory, such as `/tmp/zellij-501`.

## Usage

From Codex, invoke the skill by name:

```text
Use $claude-review to review the current diff with intent: "What changed and why"
```

Codex should launch the helper, read Claude's handoff, verify the findings against the repo, and stop at a checkpoint before making edits.

From a repo you want reviewed:

```sh
~/.codex/skills/claude-review/scripts/claude_review.rb --intent "What changed and why"
```

Include plan context when available:

```sh
~/.codex/skills/claude-review/scripts/claude_review.rb --plan docs/plan.md
```

Review one coordinated change across multiple repos in a single session:

```sh
~/.codex/skills/claude-review/scripts/claude_review.rb \
  --include-repo ~/Obsidian/gaurav-os \
  --intent "Review the Alfred and vault cutover together"
```

Review a standalone repo artifact when the worktree is clean:

```sh
~/.codex/skills/claude-review/scripts/claude_review.rb --artifact docs/plan.md
```

Review already-committed work:

```sh
~/.codex/skills/claude-review/scripts/claude_review.rb --base HEAD~1
```

Check local review dependencies:

```sh
~/.codex/skills/claude-review/scripts/claude_review.rb --doctor
```

Use less effort for simpler diffs:

```sh
CLAUDE_REVIEW_EFFORT=medium ~/.codex/skills/claude-review/scripts/claude_review.rb --intent "Mechanical rename"
```

Test another Claude model deliberately:

```sh
CLAUDE_REVIEW_MODEL=claude-sonnet-4-6 ~/.codex/skills/claude-review/scripts/claude_review.rb --intent "Review the current diff"
```

Use an explicit one-off session name:

```sh
~/.codex/skills/claude-review/scripts/claude_review.rb \
  --zellij-session feature-review \
  --intent "Review the current diff"
```

Inspect the prompt bundle without calling Claude:

```sh
~/.codex/skills/claude-review/scripts/claude_review.rb --dry-run --intent "Check prompt"
```

Run deterministic self-checks:

```sh
ruby ~/.codex/skills/claude-review/scripts/self_check.rb
```

## Security Notes

Run this only in local repos and artifacts you trust. Claude receives the git diff, supplied plan or artifact, auto-loaded authority files, and eligible untracked text files. Authority files are `AGENTS.md` and `CLAUDE.md` from the repo root and ancestor directories, capped at 120 KB per file and 240 KB total. Untracked paths that look like credentials are skipped by default, including `.env`, `.env.*`, `.npmrc`, `.pypirc`, SSH/AWS/Kube/GnuPG directories, private-key extensions, and non-source filenames containing tokens such as `secret`, `token`, `credential`, or `password`.

The skip-list is a guardrail, not a secrets scanner. Keep real secrets ignored, removed, or outside the repo before review. Prompt bundles and system prompts are written into an owner-only temp directory with owner-only file permissions.

## Runtime Behavior

The helper creates a collision-safe named Zellij session, starts a `Claude Review` pane in the repo root with `claude -p < prompt_bundle`, streams Claude's JSON events through a readable terminal formatter, opens a Ghostty tab attached to the session when available, and prints socket-aware commands like:

```sh
env ZELLIJ_SOCKET_DIR=/tmp/zellij-501 zellij attach feature-review
env ZELLIJ_SOCKET_DIR=/tmp/zellij-501 zellij --session feature-review action dump-screen --pane-id terminal_0
```

If the requested Zellij session name already exists, the helper exits. Session names are one-off handles for a single Claude review; use a fresh name for each run, or remove the old handle with `zellij delete-session <name>` or `zellij kill-session <name>` if it is still active.

The helper writes the assembled prompt bundle, system prompt, handoff file, and done marker under an owner-only `claude-review` directory in the system temp directory so the exact task and final review remain inspectable. It uses an existing `ZELLIJ_SOCKET_DIR` or configures a stable per-user default, and every printed watch or cleanup command carries that socket path explicitly. If Ghostty auto-open is unavailable, the review keeps running and the printed attach command is the supported watch path. Codex should first check the done marker after 2-3 minutes, read the handoff once complete, and verify every finding against every included repo.

## Review posture

The skill asks Claude to report concrete behavioral findings with severity and confidence. Codex should verify and filter those findings against the real repo. The helper includes repo authority files automatically; use `--intent` for conversation-only product goals, user constraints, or nuance that is not written down. When you pass a plan or intent, Claude is asked to critique the plan itself, not only whether the diff follows it. A perfectly executed wrong plan is still a review finding.

## License

MIT
