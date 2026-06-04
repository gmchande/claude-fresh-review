#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "optparse"
require "shellwords"
require "fileutils"
require "json"

MAX_UNTRACKED_BYTES = 200_000
CLAUDE_MODEL = "claude-opus-4-8"
CLAUDE_EFFORT = ENV.fetch("CLAUDE_REVIEW_EFFORT", "high")
CLAUDE_REVIEW_TOOLS = "Read,Grep,Glob,Bash,WebSearch,WebFetch"

options = {
  base: nil,
  intent: nil,
  output: nil,
  plan: nil,
  timeout: 600,
  dry_run: false
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: claude_fresh_review.rb [options]"

  opts.on("--base REF", "Review branch changes against REF") { |value| options[:base] = value }
  opts.on("--intent TEXT", "Short description of what changed and why") { |value| options[:intent] = value }
  opts.on("--plan PATH", "Include a plan/PRD file as review context") { |value| options[:plan] = value }
  opts.on("--output PATH", "Write Claude's review to PATH as well as stdout") { |value| options[:output] = value }
  opts.on("--timeout SECONDS", Integer, "Stop Claude if review exceeds SECONDS (default: 600)") { |value| options[:timeout] = value }
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

def run_claude_review(system_prompt, payload, timeout_seconds)
  timed_out = false

  Open3.popen3(
    "claude",
    "-p",
    "--no-session-persistence",
    "--model",
    CLAUDE_MODEL,
    "--effort",
    CLAUDE_EFFORT,
    "--tools",
    CLAUDE_REVIEW_TOOLS,
    "--allowedTools",
    CLAUDE_REVIEW_TOOLS,
    "--append-system-prompt",
    system_prompt,
    "--output-format",
    "json"
  ) do |stdin, stdout, stderr, wait_thread|
    stdin.write(payload)
    stdin.close

    stdout_reader = Thread.new { stdout.read }
    stderr_reader = Thread.new { stderr.read }

    if wait_thread.join(timeout_seconds)
      return [stdout_reader.value, stderr_reader.value, wait_thread.value, false]
    end

    timed_out = true
    begin
      Process.kill("TERM", wait_thread.pid)
    rescue Errno::ESRCH
      # Process already exited between timeout detection and signal delivery.
    end

    sleep 2

    if wait_thread.alive?
      begin
        Process.kill("KILL", wait_thread.pid)
      rescue Errno::ESRCH
        # Process already exited after TERM.
      end
    end

    wait_thread.join
    [stdout_reader.value, stderr_reader.value, wait_thread.value, timed_out]
  end
end

def extract_review_text(stdout)
  parsed = JSON.parse(stdout)
  events = parsed.is_a?(Array) ? parsed : [parsed]
  result_event = events.reverse.find { |event| event.is_a?(Hash) && event["type"] == "result" }

  return [result_event["result"].to_s, result_event] if result_event

  [stdout, nil]
rescue JSON::ParserError
  [stdout, nil]
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
  puts "Claude tools: #{CLAUDE_REVIEW_TOOLS}"
  puts
  puts "## Appended system prompt"
  puts reviewer_persona
  puts
  puts "## User payload"
  puts payload
  exit 0
end

unless command_available?("claude")
  warn "Claude Code CLI not found on PATH."
  exit 1
end

stdout, stderr, status, timed_out = run_claude_review(reviewer_persona, payload, options[:timeout])
warn stderr unless stderr.empty?

if timed_out
  warn "Claude review timed out after #{options[:timeout]} seconds."
  exit 124
end

unless status.success?
  warn "Claude review failed."
  exit status.exitstatus || 1
end

review_text, metadata = extract_review_text(stdout)

if metadata && metadata["is_error"]
  warn "Claude review returned an error result: #{metadata["subtype"] || "unknown"}"
  error_details = review_text.empty? ? Array(metadata["errors"]).join("\n") : review_text
  error_details = stdout if error_details.empty?
  warn error_details unless error_details.empty?
  exit 1
end

puts review_text

if options[:output]
  FileUtils.mkdir_p(File.dirname(options[:output])) unless File.dirname(options[:output]) == "."
  File.write(options[:output], review_text)
end
