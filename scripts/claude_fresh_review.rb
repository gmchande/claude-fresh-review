#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "optparse"
require "shellwords"
require "tmpdir"

MAX_UNTRACKED_BYTES = 200_000
CLAUDE_MODEL = "claude-opus-4-8"
CLAUDE_EFFORT = ENV.fetch("CLAUDE_REVIEW_EFFORT", "high")
CLAUDE_PERMISSION_MODE = "bypassPermissions"
CLAUDE_REVIEW_TOOLS = "Read,Grep,Glob,Bash,WebSearch,WebFetch"
CLAUDE_BYPASS_WARNING_MARKERS = ["Bypass", "Permissions", "Yes", "accept"].freeze
CLAUDE_READY_MARKERS = ["Claude Code", "❯"].freeze

options = {
  base: nil,
  intent: nil,
  plan: nil,
  dry_run: false,
  zellij_session: nil
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: claude_fresh_review.rb [options]"

  opts.on("--base REF", "Review branch changes against REF") { |value| options[:base] = value }
  opts.on("--intent TEXT", "Short description of what changed and why") { |value| options[:intent] = value }
  opts.on("--plan PATH", "Include a plan/PRD file as review context") { |value| options[:plan] = value }
  opts.on("--zellij-session NAME", "Create this one-off visible Zellij session name") { |value| options[:zellij_session] = value }
  opts.on("--dry-run", "Print the prompt bundle instead of calling Claude") { options[:dry_run] = true }
  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit 0
  end
end

parser.parse!(ARGV)

def run(*cmd, allow_failure: false)
  stdout, stderr, status = Open3.capture3(*cmd)
  if !status.success? && !allow_failure
    warn "Command failed: #{cmd.shelljoin}"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end
  [stdout, stderr, status]
end

def git(*args, allow_failure: false)
  stdout, _stderr, status = run("git", *args, allow_failure: allow_failure)
  return nil if allow_failure && !status.success?

  stdout
end

def command_available?(name)
  _stdout, _stderr, status = run("sh", "-c", "command -v #{Shellwords.escape(name)} >/dev/null 2>&1", allow_failure: true)
  status.success?
end

def git_ref_exists?(ref)
  _stdout, _stderr, status = run("git", "rev-parse", "--verify", "--quiet", ref, allow_failure: true)
  status.success?
end

def inside_git_repo?
  _stdout, _stderr, status = run("git", "rev-parse", "--is-inside-work-tree", allow_failure: true)
  status.success?
end

def head_exists?
  git_ref_exists?("HEAD")
end

def empty_tree_ref
  git("hash-object", "-t", "tree", "/dev/null").strip
end

def likely_text_file?(path)
  File.file?(path) && !File.binread(path, 4096).include?("\x00")
rescue Errno::ENOENT, Errno::EACCES
  false
end

def read_plan(path)
  return nil unless path

  unless File.file?(path)
    warn "Plan file not found: #{path}"
    exit 1
  end

  File.read(path)
end

def untracked_file_section(path)
  if !likely_text_file?(path)
    "### #{path}\n\nSkipped: not a readable text file.\n"
  elsif File.size(path) > MAX_UNTRACKED_BYTES
    "### #{path}\n\nSkipped: file is larger than #{MAX_UNTRACKED_BYTES} bytes.\n"
  else
    content = File.read(path)
    "### #{path}\n\n```text\n#{content}\n```\n"
  end
rescue Errno::ENOENT, Errno::EACCES
  "### #{path}\n\nSkipped: file disappeared or became unreadable.\n"
end

def current_branch_base
  if command_available?("gh")
    stdout, _stderr, status = run("gh", "pr", "view", "--json", "baseRefName", "--jq", ".baseRefName", allow_failure: true)
    base_name = stdout.strip
    if status.success? && !base_name.empty?
      remote_ref = "origin/#{base_name}"
      return remote_ref if git_ref_exists?(remote_ref)
      return base_name if git_ref_exists?(base_name)
    end
  end

  %w[origin/main main origin/master master].find { |ref| git_ref_exists?(ref) }
end

def untracked_bundle
  raw = git("ls-files", "--others", "--exclude-standard", "-z")
  paths = raw.split("\0").reject(&:empty?)
  return "" if paths.empty?

  sections = paths.map { |path| untracked_file_section(path) }

  <<~TEXT
    ## Untracked Files

    These files are not in `git diff`, but are part of the current working tree:

    #{sections.join("\n")}
  TEXT
end

def slug(value)
  value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")[0, 60]
end

def default_prompt_file(repo_root)
  repo_slug = slug(File.basename(repo_root))
  stamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
  File.join(Dir.tmpdir, "claude-fresh-review", "#{stamp}-#{repo_slug}-review.md")
end

def default_system_prompt_file(prompt_path)
  return prompt_path.sub(/\.md\z/, "-system.md") if prompt_path.end_with?(".md")

  "#{prompt_path}-system.md"
end

def write_prompt_bundle(payload, repo_root)
  path = default_prompt_file(repo_root)
  FileUtils.mkdir_p(File.dirname(path)) unless File.dirname(path) == "."
  File.write(path, payload)
  path
end

def write_system_prompt(system_prompt, prompt_path)
  path = default_system_prompt_file(prompt_path)
  File.write(path, system_prompt)
  path
end

def zellij_session_name(options)
  return options[:zellij_session] if options[:zellij_session]

  "cfr-#{Time.now.utc.strftime("%H%M%S")}"
end

def claude_interactive_shell_cmd(system_prompt_path)
  cmd = [
    "claude",
    "--model",
    CLAUDE_MODEL,
    "--effort",
    CLAUDE_EFFORT,
    "--permission-mode",
    CLAUDE_PERMISSION_MODE,
    "--tools",
    CLAUDE_REVIEW_TOOLS,
    "--allowedTools",
    CLAUDE_REVIEW_TOOLS
  ]

  "#{cmd.shelljoin} --append-system-prompt \"$(cat #{system_prompt_path.shellescape})\""
end

def zellij(*args, allow_failure: false)
  stdout, stderr, status = run("zellij", *args, allow_failure: true)

  if !status.success? && !allow_failure
    warn "Command failed: #{(["zellij"] + args).shelljoin}"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end

  [stdout, stderr, status]
end

def zellij_session_exists?(session)
  stdout, _stderr, status = zellij("list-sessions", "--short", allow_failure: true)
  return false unless status.success?

  stdout.lines.map(&:strip).include?(session)
end

def zellij_dump_screen(session, pane_id, full: false)
  # Readiness checks must ignore scrollback; old bypass warnings can remain in `--full` output.
  args = [
    "--session",
    session,
    "action",
    "dump-screen",
    "--pane-id",
    pane_id
  ]
  args << "--full" if full

  stdout, _stderr, status = zellij(*args, allow_failure: true)
  return stdout if status.success?

  ""
end

def close_other_terminal_panes(session, pane_id)
  stdout, _stderr, status = zellij("--session", session, "action", "list-panes", allow_failure: true)
  return unless status.success?

  stdout.each_line do |line|
    other_pane_id = line[/\A(terminal_\d+)\s+terminal\b/, 1]
    next if other_pane_id.nil? || other_pane_id == pane_id

    zellij("--session", session, "action", "close-pane", "--pane-id", other_pane_id, allow_failure: true)
  end
end

def bypass_warning_screen?(screen)
  CLAUDE_BYPASS_WARNING_MARKERS.all? { |marker| screen.include?(marker) }
end

def claude_ready_screen?(screen)
  CLAUDE_READY_MARKERS.all? { |marker| screen.include?(marker) } && !bypass_warning_screen?(screen)
end

def accept_zellij_bypass_warning(session, pane_id)
  warn "Claude bypass-permissions startup screen detected; selecting Yes, I accept."
  zellij("--session", session, "action", "send-keys", "--pane-id", pane_id, "2", "Enter")
end

def wait_for_zellij_claude_prompt(session, pane_id, timeout_seconds: 30)
  deadline = Time.now + timeout_seconds

  until Time.now > deadline
    screen = zellij_dump_screen(session, pane_id)
    if bypass_warning_screen?(screen)
      accept_zellij_bypass_warning(session, pane_id)
      sleep 1
      next
    end

    return true if claude_ready_screen?(screen)

    sleep 0.5
  end

  warn "Claude pane did not show a ready prompt within #{timeout_seconds}s; not sending the review task."
  warn "Inspect it with: zellij --session #{session.shellescape} action dump-screen --pane-id #{pane_id.shellescape} --full"
  false
end

def zellij_write_text(session, pane_id, text)
  text.each_char.each_slice(8_000) do |chars|
    zellij("--session", session, "action", "write-chars", "--pane-id", pane_id, "--", chars.join)
  end
end

def run_zellij_review(system_prompt, payload, repo_root, options)
  unless command_available?("zellij")
    warn "Zellij is required for claude-fresh-review. Install it with `brew install zellij` and rerun this command."
    exit 1
  end

  unless command_available?("claude")
    warn "Claude Code CLI not found on PATH."
    exit 1
  end

  session = zellij_session_name(options)
  if zellij_session_exists?(session)
    warn "Zellij session already exists: #{session}"
    warn "claude-fresh-review sessions are one-off; choose a new --zellij-session name or close the old session first."
    exit 1
  end

  prompt_path = write_prompt_bundle(payload, repo_root)
  system_prompt_path = write_system_prompt(system_prompt, prompt_path)

  _stdout, stderr, status = zellij("attach", "--create-background", session, allow_failure: true)
  unless status.success?
    warn "Failed to create Zellij background session: #{session}"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end

  stdout, stderr, status = zellij(
    "--session",
    session,
    "run",
    "--cwd",
    repo_root,
    "--name",
    "Claude Fresh Review",
    "--",
    "sh",
    "-lc",
    claude_interactive_shell_cmd(system_prompt_path),
    allow_failure: true
  )

  unless status.success?
    warn "Failed to create Zellij Claude pane in session: #{session}"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end

  pane_id = stdout.strip
  if pane_id.empty?
    warn "Zellij did not return a pane id; cannot safely send the review task."
    exit 1
  end

  close_other_terminal_panes(session, pane_id)
  exit 1 unless wait_for_zellij_claude_prompt(session, pane_id)

  zellij("--session", session, "action", "focus-pane-id", pane_id)
  zellij_write_text(session, pane_id, payload)
  sleep 2
  zellij("--session", session, "action", "send-keys", "--pane-id", pane_id, "Enter")

  puts "Claude review prompt sent to Zellij session: #{session}"
  puts "Zellij pane: #{pane_id}"
  puts "Prompt bundle: #{prompt_path}"
  puts "System prompt: #{system_prompt_path}"
  puts
  puts "Watch:"
  puts "zellij attach #{session.shellescape}"
  puts
  puts "Inspect from Codex/shell:"
  puts "zellij --session #{session.shellescape} action dump-screen --pane-id #{pane_id.shellescape} --full"
  puts
  puts "Interrupt:"
  puts "zellij --session #{session.shellescape} action send-keys --pane-id #{pane_id.shellescape} Esc"
  puts "zellij --session #{session.shellescape} action send-keys --pane-id #{pane_id.shellescape} \"Ctrl c\""
end

unless inside_git_repo?
  warn "Not inside a git repository. Run this from the experiment/project repo you want reviewed."
  exit 1
end

repo_root = git("rev-parse", "--show-toplevel").strip
Dir.chdir(repo_root)

plan_text = read_plan(options[:plan])
status_short = git("status", "--short")
dirty = !status_short.strip.empty?

unless options[:plan] || options[:intent]
  warn "No plan or intent supplied. Claude can review the diff, but may miss plan-level issues."
end

if dirty
  if head_exists?
    comparison_ref = "HEAD"
    target_label = "working tree against HEAD"
  else
    comparison_ref = empty_tree_ref
    target_label = "working tree against empty tree (unborn branch; no HEAD commit yet)"
  end

  diff_stat = git("diff", "--stat", comparison_ref, "--")
  diff_body = git("diff", "--no-ext-diff", comparison_ref, "--")
  untracked = untracked_bundle
else
  base = options[:base] || current_branch_base
  unless base
    warn "No local changes found, and no base branch could be detected. Pass --base REF."
    exit 1
  end

  target_label = "current branch against #{base}"
  diff_stat = git("diff", "--stat", "#{base}...HEAD", "--")
  diff_body = git("diff", "--no-ext-diff", "#{base}...HEAD", "--")
  untracked = ""
end

if diff_body.strip.empty? && untracked.strip.empty?
  warn "No diff content found to review."
  warn "If reviewing already-committed work, pass --base HEAD~1 or --base HEAD~N." unless dirty
  exit 1
end

reviewer_persona = <<~PROMPT
  You are reviewing a git diff or supplied project artifact with fresh eyes after another agent planned or changed it.

  Review posture:
  - Be pragmatic and thorough for a serious small experiment, repo workflow, plan, design document, or agent-OS configuration.
  - Verify correctness, completeness, and solidity for the stated purpose.
  - First infer what kind of artifact this is: code, plan/PRD, design review, documentation, workflow instructions, or agent/tooling setup. Apply the relevant standard rather than forcing a code-only review.
  - Look for correctness bugs, broken user flows, data loss, privacy/security footguns, confusing structure, missing essential checks, instruction conflicts, unclear ownership, brittle workflow assumptions, and poor fit with the existing project style.
  - For plans and documents, focus on clarity, internal consistency, missing decisions, executable next steps, ambiguous scope, and whether the review is balanced for the stated stakes.
  - When a plan or intent is supplied, critique the plan itself as well as whether the diff follows it; a perfectly executed wrong plan is still a review finding.
  - Prefer concrete, high-confidence findings with small scoped fixes.
  - Do not review like a principal engineer hardening a large SaaS product for millions of users.
  - Avoid speculative scale concerns, broad rewrites, purity refactors, needless abstraction, and "this might matter someday" findings.
  - If there are no actionable findings, say that clearly.

  Output format:
  - Findings first, ordered by severity.
  - For each finding, include file/line or section references when possible, why it matters, and the smallest reasonable fix.
  - Then include a short "Checks / validation I would run" section.
  - Then include "Noise / non-issues" only if you intentionally rejected tempting but over-engineered concerns.
  - Do not edit files.
  - You may use local inspection, shell commands, tests, and web/doc lookup tools when they materially improve the review. Prefer official docs when checking CLI/tool behavior.
  - Do not make edits or commit changes.
PROMPT

payload = <<~PROMPT
  Repository: #{repo_root}
  Review target: #{target_label}

  #{options[:intent] ? "Task intent:\n#{options[:intent]}\n" : ""}
  #{plan_text ? "Plan / PRD / artifact context:\n#{plan_text}\n" : ""}
  Git status:
  ```text
  #{status_short.empty? ? "(clean)" : status_short}
  ```

  Diff stat:
  ```text
  #{diff_stat}
  ```

  Diff:
  ```diff
  #{diff_body}
  ```

  #{untracked}
PROMPT

if options[:dry_run]
  puts "Claude model: #{CLAUDE_MODEL}"
  puts "Claude effort: #{CLAUDE_EFFORT}"
  puts "Permission mode: #{CLAUDE_PERMISSION_MODE}"
  puts "Runner: visible Zellij session"
  puts "Claude tools: #{CLAUDE_REVIEW_TOOLS}"
  puts
  puts "## Appended system prompt"
  puts reviewer_persona
  puts
  puts "## User payload"
  puts payload
  exit 0
end

run_zellij_review(reviewer_persona, payload, repo_root, options)
