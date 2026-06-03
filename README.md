# claude-fresh-review

A Codex skill that asks Claude Code for a fresh-eyes review of the current git diff or project artifact.

The intended workflow is simple: use Codex for planning and implementation, then use Claude Code as an independent reviewer before you keep moving. The review posture is pragmatic and thorough for serious small projects: catch correctness bugs, broken flows, data loss, security footguns, unclear plans, brittle workflow assumptions, and poor fit with the existing project style without drifting into enterprise hardening or speculative architecture review.

## What it does

- Reviews a dirty working tree against `HEAD`, including untracked text files.
- Reviews already-committed work with `--base HEAD~1` or branch work with `--base main`.
- Accepts plan, PRD, or artifact context with `--plan`.
- Accepts conversation-level intent with `--intent`.
- Runs Claude Code with `claude-opus-4-8`, high effort by default, and a 10-minute timeout.
- Allows `Read`, `Grep`, `Glob`, `Bash`, `WebSearch`, and `WebFetch`.
- Does not grant Claude Code `Edit` or `Write`, but `Bash` is still shell access. Use it for trusted local repos and artifacts.

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

Use less effort for trivial diffs:

```sh
CLAUDE_REVIEW_EFFORT=medium ~/.codex/skills/claude-fresh-review/scripts/claude_fresh_review.rb --intent "Mechanical rename"
```

Inspect the prompt bundle without calling Claude:

```sh
~/.codex/skills/claude-fresh-review/scripts/claude_fresh_review.rb --dry-run --intent "Check prompt"
```

## Review posture

The skill asks Claude to verify correctness, completeness, and solidity for the stated purpose. When you pass a plan or intent, Claude is asked to critique the plan itself, not only whether the diff follows it. A perfectly executed wrong plan is still a review finding.

## License

MIT
