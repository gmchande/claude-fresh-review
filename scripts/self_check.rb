#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

HELPER = File.expand_path("claude_review.rb", __dir__)
STREAM_PRINTER = File.expand_path("claude_stream_printer.rb", __dir__)

def run_cmd(repo, *cmd, allow_failure: false)
  stdout, stderr, status = Open3.capture3(*cmd, chdir: repo)
  if !status.success? && !allow_failure
    warn "Command failed in #{repo}: #{cmd.join(" ")}"
    warn stdout unless stdout.empty?
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end
  [stdout, stderr, status]
end

def git(repo, *args)
  run_cmd(repo, "git", *args)
end

def init_repo
  repo = Dir.mktmpdir("cr-check-")
  git(repo, "init")
  git(repo, "config", "user.email", "check@example.test")
  git(repo, "config", "user.name", "Self Check")
  repo
end

def write(repo, path, content)
  full_path = File.join(repo, path)
  FileUtils.mkdir_p(File.dirname(full_path))
  File.binwrite(full_path, content)
end

def commit_all(repo, message)
  git(repo, "add", ".")
  git(repo, "commit", "-m", message)
end

def dry_run(repo, *args, allow_failure: false)
  stdout, stderr, status = run_cmd(repo, "ruby", HELPER, "--dry-run", *args, allow_failure: allow_failure)
  [stdout + stderr, status]
end

def assert(condition, message)
  return if condition

  warn "FAIL: #{message}"
  exit 1
end

def assert_includes(text, needle, label)
  assert(text.include?(needle), "#{label}: expected output to include #{needle.inspect}")
end

def run_stream_printer(handoff_path, session_id_path, *events)
  input = events.map(&:to_json).join("\n") + "\n"
  Open3.capture3("ruby", STREAM_PRINTER, handoff_path, session_id_path, stdin_data: input)
end

def test_stream_printer_writes_session_id_from_init
  dir = Dir.mktmpdir("cr-printer-")
  session_id_path = File.join(dir, "session-id.txt")

  _stdout, stderr, status = run_stream_printer(
    File.join(dir, "handoff.md"),
    session_id_path,
    { "type" => "system", "subtype" => "init", "session_id" => "abc-123", "model" => "m", "cwd" => dir }
  )

  assert(status.success?, "stream printer should exit successfully: #{stderr}")
  assert(File.binread(session_id_path) == "abc-123", "stream printer should write the session id")
ensure
  FileUtils.rm_rf(dir) if dir
end

def test_stream_printer_writes_missing_handoff_from_result
  dir = Dir.mktmpdir("cr-printer-")
  handoff_path = File.join(dir, "handoff.md")
  result_text = "Final review handoff\n"

  _stdout, stderr, status = run_stream_printer(
    handoff_path,
    File.join(dir, "session-id.txt"),
    { "type" => "result", "subtype" => "success", "result" => result_text }
  )

  assert(status.success?, "stream printer should exit successfully: #{stderr}")
  assert(File.file?(handoff_path), "stream printer should create handoff")
  assert(File.binread(handoff_path) == result_text, "stream printer should write result text")
  assert((File.stat(handoff_path).mode & 0o777) == 0o600, "stream printer handoff should be mode 0600")
ensure
  FileUtils.rm_rf(dir) if dir
end

def test_stream_printer_preserves_non_empty_handoff
  dir = Dir.mktmpdir("cr-printer-")
  handoff_path = File.join(dir, "handoff.md")
  original_text = "Claude wrote a structured handoff\n"
  File.binwrite(handoff_path, original_text)

  _stdout, stderr, status = run_stream_printer(
    handoff_path,
    File.join(dir, "session-id.txt"),
    { "type" => "result", "subtype" => "success", "result" => "Fallback handoff\n" }
  )

  assert(status.success?, "stream printer should exit successfully: #{stderr}")
  assert(File.binread(handoff_path) == original_text, "stream printer should not overwrite non-empty handoff")
ensure
  FileUtils.rm_rf(dir) if dir
end

def test_dirty_diff
  repo = init_repo
  write(repo, "app.txt", "hello\n")
  commit_all(repo, "initial")
  write(repo, "app.txt", "hello world\n")

  output, status = dry_run(repo, "--intent", "Review dirty diff")

  assert(status.success?, "dirty diff dry-run should succeed")
  assert_includes(output, "Review target: working tree against HEAD", "dirty diff")
  assert_includes(output, "+hello world", "dirty diff")
ensure
  FileUtils.rm_rf(repo) if repo
end

def test_default_model_and_effort
  repo = init_repo
  write(repo, "app.txt", "hello\n")
  commit_all(repo, "initial")
  write(repo, "app.txt", "hello changed\n")

  output, status = dry_run(repo, "--intent", "Review defaults")

  assert(status.success?, "default model dry-run should succeed")
  assert_includes(output, "Claude model: claude-fable-5", "default model")
  assert_includes(output, "Claude effort: xhigh", "default effort")
ensure
  FileUtils.rm_rf(repo) if repo
end

def test_clean_branch_with_base
  repo = init_repo
  write(repo, "app.txt", "base\n")
  commit_all(repo, "initial")
  git(repo, "branch", "-M", "main")
  git(repo, "checkout", "-b", "feature")
  write(repo, "app.txt", "feature\n")
  commit_all(repo, "feature")

  output, status = dry_run(repo, "--base", "main", "--intent", "Review branch")

  assert(status.success?, "clean branch dry-run should succeed")
  assert_includes(output, "Review target: current branch against main", "clean branch")
  assert_includes(output, "+feature", "clean branch")
ensure
  FileUtils.rm_rf(repo) if repo
end

def test_unborn_untracked
  repo = init_repo
  write(repo, "notes.txt", "first file\n")

  output, status = dry_run(repo, "--intent", "Review unborn repo")

  assert(status.success?, "unborn untracked dry-run should succeed")
  assert_includes(output, "working tree against empty tree", "unborn untracked")
  assert_includes(output, "## Untracked Files", "unborn untracked")
  assert_includes(output, "first file", "unborn untracked")
ensure
  FileUtils.rm_rf(repo) if repo
end

def test_secret_untracked_skip
  repo = init_repo
  write(repo, "app.txt", "hello\n")
  commit_all(repo, "initial")
  write(repo, ".env", "LEAK_ME_ENV=1\n")
  write(repo, "config/api_token.txt", "LEAK_ME_TOKEN=1\n")
  write(repo, "auth.rb", "class Auth\nend\n")
  write(repo, "tokens.rb", "TOKENS_SOURCE = true\n")
  write(repo, "password_input.tsx", "export function PasswordInput() {}\n")

  output, status = dry_run(repo, "--intent", "Review secret skips")

  assert(status.success?, "secret untracked dry-run should succeed")
  assert_includes(output, "### .env", "secret untracked")
  assert_includes(output, "### config/api_token.txt", "secret untracked")
  assert_includes(output, "Skipped: likely secret or credential filename.", "secret untracked")
  assert(!output.include?("LEAK_ME_ENV"), "secret untracked: should not include .env contents")
  assert(!output.include?("LEAK_ME_TOKEN"), "secret untracked: should not include token file contents")
  assert_includes(output, "### auth.rb", "secret untracked")
  assert_includes(output, "class Auth", "secret untracked")
  assert_includes(output, "### tokens.rb", "secret untracked")
  assert_includes(output, "TOKENS_SOURCE = true", "secret untracked")
  assert_includes(output, "### password_input.tsx", "secret untracked")
  assert_includes(output, "PasswordInput", "secret untracked")
ensure
  FileUtils.rm_rf(repo) if repo
end

def test_missing_plan
  repo = init_repo
  write(repo, "app.txt", "hello\n")
  commit_all(repo, "initial")

  output, status = dry_run(repo, "--plan", "missing.md", allow_failure: true)

  assert(!status.success?, "missing plan dry-run should fail")
  assert_includes(output, "Plan file not found: missing.md", "missing plan")
ensure
  FileUtils.rm_rf(repo) if repo
end

def test_binary_untracked_skip
  repo = init_repo
  write(repo, "app.txt", "hello\n")
  commit_all(repo, "initial")
  write(repo, "blob.bin", "abc\u0000def")

  output, status = dry_run(repo, "--intent", "Review binary untracked")

  assert(status.success?, "binary untracked dry-run should succeed")
  assert_includes(output, "### blob.bin", "binary untracked")
  assert_includes(output, "Skipped: not a readable text file.", "binary untracked")
ensure
  FileUtils.rm_rf(repo) if repo
end

def test_artifact_only
  repo = init_repo
  write(repo, "docs/plan.md", "# Plan\n\nShip the workflow.\n")
  commit_all(repo, "initial")

  output, status = dry_run(repo, "--artifact", "docs/plan.md")

  assert(status.success?, "artifact-only dry-run should succeed")
  assert_includes(output, "Review target: artifact docs/plan.md", "artifact-only")
  assert_includes(output, "Artifact under review: docs/plan.md", "artifact-only")
  assert_includes(output, "Ship the workflow.", "artifact-only")
ensure
  FileUtils.rm_rf(repo) if repo
end

def test_dirty_artifact_includes_diff
  repo = init_repo
  write(repo, "app.txt", "hello\n")
  write(repo, "docs/plan.md", "# Plan\n\nShip the workflow.\n")
  commit_all(repo, "initial")
  write(repo, "app.txt", "hello changed\n")

  output, status = dry_run(repo, "--artifact", "docs/plan.md")

  assert(status.success?, "dirty artifact dry-run should succeed")
  assert_includes(output, "Review target: working tree against HEAD", "dirty artifact")
  assert_includes(output, "Artifact under review: docs/plan.md", "dirty artifact")
  assert_includes(output, "+hello changed", "dirty artifact")
ensure
  FileUtils.rm_rf(repo) if repo
end

def test_project_context_includes_parent_and_repo_authority_files
  parent = Dir.mktmpdir("cr-context-parent-")
  repo = File.join(parent, "child")
  FileUtils.mkdir_p(repo)

  write(parent, "AGENTS.md", "# Parent guidance\n\nUse the small-app rules when judging architecture.\n")
  write(repo, "AGENTS.md", "# Child guidance\n\nPrefer JSON until durable querying is real.\n")
  write(repo, "CLAUDE.md", "@AGENTS.md\n")
  git(repo, "init")
  git(repo, "config", "user.email", "check@example.test")
  git(repo, "config", "user.name", "Self Check")
  write(repo, "app.txt", "hello\n")
  commit_all(repo, "initial")
  write(repo, "app.txt", "hello changed\n")

  output, status = dry_run(repo, "--intent", "Review project context")

  assert(status.success?, "project context dry-run should succeed")
  assert_includes(output, "Project context (auto-loaded from authority files", "project context")
  assert_includes(output, "Use the small-app rules when judging architecture.", "project context")
  assert_includes(output, "Prefer JSON until durable querying is real.", "project context")
  assert_includes(output, "### ../AGENTS.md", "project context")
  assert_includes(output, "### AGENTS.md", "project context")
  assert_includes(output, "### CLAUDE.md", "project context")
ensure
  FileUtils.rm_rf(parent) if parent
end

tests = [
  method(:test_stream_printer_writes_session_id_from_init),
  method(:test_stream_printer_writes_missing_handoff_from_result),
  method(:test_stream_printer_preserves_non_empty_handoff),
  method(:test_dirty_diff),
  method(:test_default_model_and_effort),
  method(:test_clean_branch_with_base),
  method(:test_unborn_untracked),
  method(:test_secret_untracked_skip),
  method(:test_missing_plan),
  method(:test_binary_untracked_skip),
  method(:test_artifact_only),
  method(:test_dirty_artifact_includes_diff),
  method(:test_project_context_includes_parent_and_repo_authority_files)
]

tests.each do |test|
  test.call
  puts "PASS #{test.name}"
end

puts "All self-checks passed."
