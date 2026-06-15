# claude-fresh-review

A Codex skill that asks Claude Code for a fresh-eyes review of the current git diff or project artifact.

The intended workflow is simple: use Codex for planning and implementation, then launch Claude Code in a visible Zellij session as an independent reviewer before you keep moving. The review posture is pragmatic and thorough for serious small projects: catch correctness bugs, broken flows, data loss, security footguns, unclear plans, brittle workflow assumptions, and poor fit with the existing project style without drifting into enterprise hardening or speculative architecture review.

## What it does

- Reviews a dirty working tree against `HEAD`, including untracked text files.
- Reviews new experiment repos before the first commit by comparing tracked changes to Git's empty tree and bundling untracked text files.
- Reviews already-committed work with `--base HEAD~1` or branch work with `--base main`. On dirty trees, `--base` reviews the working tree against the merge base so committed branch work and uncommitted changes are both included.
- Accepts plan, PRD, or artifact context with `--plan`.
- Accepts conversation-level intent with `--intent`.
- Runs Claude Code in a new, one-off visible Zellij session with `claude-opus-4-8`, xhigh effort, and `--permission-mode bypassPermissions` by default, with streamed output formatted for the terminal.
- Allows `Read`, `Grep`, `Glob`, `Bash`, `WebSearch`, and `WebFetch`.
- Does not grant Claude Code `Edit` or `Write`, but `Bash` is still shell access without per-command permission prompts. Use it for trusted local repos and artifacts.
- Opens a Ghostty tab attached to the Zellij session and prints the exact attach, inspect, and interrupt commands.

## Install

Clone into your Codex skills directory:

```sh
git clone https://github.com/gmchande/claude-fresh-review.git "${CODEX_HOME:-$HOME/.codex}/skills/claude-fresh-review"
```

If your Codex setup loads personal skills from another directory, clone it there instead.

The helper script should be executable after cloning. If needed:

```sh
chmod +x "${CODEX_HOME:-$HOME/.codex}/skills/claude-fresh-review/scripts/claude_fresh_review.rb"
```

## Requirements

- Ruby
- Git
- Claude Code CLI on `PATH`
- Zellij 0.44+ on `PATH`
- Ghostty.app installed and registered with macOS
- `ZELLIJ_SOCKET_DIR` set in shell startup to a short stable path such as `/tmp/zellij`
- Optional: GitHub CLI, used only to infer the PR base branch when available

## Usage

From a repo you want reviewed:

```sh
~/.codex/skills/claude-fresh-review/scripts/claude_fresh_review.rb --intent "What changed and why"
```

Include plan context when available:

```sh
~/.codex/skills/claude-fresh-review/scripts/claude_fresh_review.rb --plan docs/plan.md
```

Review already-committed work:

```sh
~/.codex/skills/claude-fresh-review/scripts/claude_fresh_review.rb --base HEAD~1
```

Use less effort for simpler diffs:

```sh
CLAUDE_REVIEW_EFFORT=medium ~/.codex/skills/claude-fresh-review/scripts/claude_fresh_review.rb --intent "Mechanical rename"
```

Test another Claude model deliberately:

```sh
CLAUDE_REVIEW_MODEL=claude-sonnet-4-6 ~/.codex/skills/claude-fresh-review/scripts/claude_fresh_review.rb --intent "Review the current diff"
```

Use an explicit one-off session name:

```sh
~/.codex/skills/claude-fresh-review/scripts/claude_fresh_review.rb \
  --zellij-session feature-review \
  --intent "Review the current diff"
```

Inspect the prompt bundle without calling Claude:

```sh
~/.codex/skills/claude-fresh-review/scripts/claude_fresh_review.rb --dry-run --intent "Check prompt"
```

## Runtime Behavior

The helper creates a new named Zellij session, starts a `Claude Fresh Review` pane in the repo root with `claude -p < prompt_bundle`, streams Claude's JSON events through a readable terminal formatter, opens a Ghostty tab attached to the session, and prints commands like:

```sh
zellij attach feature-review
zellij --session feature-review action dump-screen --pane-id terminal_0
zellij --session feature-review action dump-screen --pane-id terminal_0 --full --path /tmp/claude-fresh-review-feature-review.screen.txt
zellij --session feature-review action send-keys --pane-id terminal_0 "Ctrl c"
```

If the requested Zellij session name already exists, the helper exits. Session names are one-off handles for a single Claude review; use a fresh name for each run, or remove the old handle with `zellij delete-session <name>` or `zellij kill-session <name>` if it is still active.

The helper writes the assembled prompt bundle, system prompt, handoff file, and done marker under `/tmp/claude-fresh-review/...` so the exact task and final review remain inspectable. Zellij must use a short, stable socket namespace such as `/tmp/zellij` in shell startup so plain commands like `zellij attach feature-review` work from new terminal tabs. If `ZELLIJ_SOCKET_DIR` is missing, the helper exits instead of creating a hidden alternate namespace. It does not parse a final review from JSON stdout; Codex should let the user watch the formatted stream, do the first done-marker check after 2-3 minutes, read the handoff once the marker exists, avoid continuous pane polling, and verify every finding against the actual repo.

## Review posture

The skill asks Claude to report concrete behavioral findings with severity and confidence. Codex should verify and filter those findings against the real repo. When you pass a plan or intent, Claude is asked to critique the plan itself, not only whether the diff follows it. A perfectly executed wrong plan is still a review finding.

## License

MIT
