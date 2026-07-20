#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "pi_visible_session"

HELPER = File.expand_path("claude_review.rb", __dir__)
HANDOFF_EXTENSION = File.expand_path("pi_review_handoff.ts", __dir__)

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

def test_pi_handoff_extension_tracks_interactive_turns
  dir = Dir.mktmpdir("cr-pi-handoff-")
  handoff_path = File.join(dir, "handoff.md")
  done_marker_path = File.join(dir, "review.done")
  script = <<~JAVASCRIPT
    import { existsSync, readFileSync, statSync } from "node:fs";

    process.env.PI_REVIEW_HANDOFF_PATH = #{JSON.generate(handoff_path)};
    process.env.PI_REVIEW_DONE_MARKER_PATH = #{JSON.generate(done_marker_path)};

    const extensionModule = await import(`file://#{HANDOFF_EXTENSION}?self_check=${Date.now()}`);
    const handlers = {};
    const pi = { on(name, handler) { handlers[name] = handler; } };
    const assistant = (text, stopReason = "stop") => ({
      role: "assistant",
      content: [{ type: "thinking", thinking: "private" }, { type: "text", text }],
      stopReason,
    });

    extensionModule.default(pi);

    const settle = async (message) => {
      await handlers.agent_start({});
      const cleared = !existsSync(process.env.PI_REVIEW_HANDOFF_PATH) && !existsSync(process.env.PI_REVIEW_DONE_MARKER_PATH);
      await handlers.agent_end({ messages: message ? [message] : [] });
      await handlers.agent_settled({});
      return {
        cleared,
        handoff: readFileSync(process.env.PI_REVIEW_HANDOFF_PATH, "utf8"),
        marker: readFileSync(process.env.PI_REVIEW_DONE_MARKER_PATH, "utf8"),
      };
    };

    const first = await settle(assistant("First review"));
    first.handoffMode = statSync(process.env.PI_REVIEW_HANDOFF_PATH).mode & 0o777;
    first.markerMode = statSync(process.env.PI_REVIEW_DONE_MARKER_PATH).mode & 0o777;
    const interrupted = await settle(assistant("Partial review", "aborted"));
    const truncated = await settle(assistant("Cut off review", "length"));
    const failed = await settle({ ...assistant("Partial provider output", "error"), errorMessage: "quota exceeded" });
    const final = await settle(assistant("Corrected final review"));

    console.log(JSON.stringify({ first, interrupted, truncated, failed, final }));
  JAVASCRIPT

  stdout, stderr, status = Open3.capture3("bun", "-e", script)
  assert(status.success?, "Pi handoff extension should load and run under Bun: #{stderr}")
  result = JSON.parse(stdout)
  assert(result.dig("first", "handoff") == "First review\n", "handoff should contain the completed assistant turn")
  assert(result.dig("first", "marker") == "0\n", "completed turn should write status 0")
  assert(result.dig("first", "handoffMode") == 0o600, "handoff should be mode 0600")
  assert(result.dig("first", "markerMode") == 0o600, "done marker should be mode 0600")
  assert(result.dig("interrupted", "cleared"), "a new turn should clear the previous handoff and marker")
  assert(result.dig("interrupted", "marker") == "130\n", "Escape-style abort should write status 130")
  assert(result.dig("truncated", "cleared"), "a follow-up should clear the interrupted marker")
  assert(result.dig("truncated", "marker") == "1\n", "token-limit truncation should not look complete")
  assert_includes(result.dig("truncated", "handoff"), "stop reason length", "truncated handoff")
  assert(result.dig("failed", "marker") == "1\n", "provider error should write status 1")
  assert(result.dig("failed", "handoff").start_with?("quota exceeded"), "provider error should lead the failed handoff")
  assert(result.dig("final", "handoff") == "Corrected final review\n", "follow-up should replace the handoff")
  assert(result.dig("final", "marker") == "0\n", "completed follow-up should replace status 130 with 0")
ensure
  FileUtils.rm_rf(dir) if dir
end

def test_review_scenarios
  clean_branch = lambda do |repo|
    write(repo, "app.txt", "base\n")
    commit_all(repo, "initial")
    git(repo, "branch", "-M", "main")
    git(repo, "checkout", "-b", "feature")
    write(repo, "app.txt", "feature\n")
    commit_all(repo, "feature")
  end

  scenarios = [
    {
      name: "dirty diff",
      setup: ->(repo) { write(repo, "app.txt", "hello\n"); commit_all(repo, "initial"); write(repo, "app.txt", "hello world\n") },
      args: ["--intent", "Review dirty diff"],
      includes: ["Review target: working tree against HEAD", "+hello world"]
    },
    {
      name: "clean branch with base",
      setup: clean_branch,
      args: ["--base", "main", "--intent", "Review branch"],
      includes: ["Review target: current branch against main", "+feature"]
    },
    {
      name: "clean branch requires base",
      setup: clean_branch,
      args: ["--intent", "Review branch"],
      success: false,
      includes: ["No local changes found. Pass --base REF"]
    },
    {
      name: "unborn untracked",
      setup: ->(repo) { write(repo, "notes.txt", "first file\n") },
      args: ["--intent", "Review unborn repo"],
      includes: ["working tree against empty tree", "## Untracked Files", "first file"]
    },
    {
      name: "missing plan",
      setup: ->(repo) { write(repo, "app.txt", "hello\n"); commit_all(repo, "initial") },
      args: ["--plan", "missing.md"],
      success: false,
      includes: ["Plan file not found: missing.md"]
    },
    {
      name: "plan only",
      setup: ->(repo) { write(repo, "docs/plan.md", "# Plan\n\nShip the bounded review.\n"); commit_all(repo, "initial") },
      args: ["--plan", "docs/plan.md"],
      includes: ["Review target: plan docs/plan.md", "Plan under review: docs/plan.md", "Ship the bounded review."]
    },
    {
      name: "binary untracked",
      setup: ->(repo) { write(repo, "app.txt", "hello\n"); commit_all(repo, "initial"); write(repo, "blob.bin", "abc\u0000def") },
      args: ["--intent", "Review binary untracked"],
      includes: ["### blob.bin", "Skipped: not a readable text file."]
    },
    {
      name: "artifact only",
      setup: ->(repo) { write(repo, "docs/plan.md", "# Plan\n\nShip the workflow.\n"); commit_all(repo, "initial") },
      args: ["--artifact", "docs/plan.md"],
      includes: ["Review target: artifact docs/plan.md", "Artifact under review: docs/plan.md", "Ship the workflow."]
    },
    {
      name: "dirty artifact",
      setup: lambda do |repo|
        write(repo, "app.txt", "hello\n")
        write(repo, "docs/plan.md", "# Plan\n\nShip the workflow.\n")
        commit_all(repo, "initial")
        write(repo, "app.txt", "hello changed\n")
      end,
      args: ["--artifact", "docs/plan.md"],
      includes: ["Review target: working tree against HEAD", "Artifact under review: docs/plan.md", "+hello changed"]
    }
  ]

  scenarios.each do |scenario|
    repo = init_repo
    begin
      scenario[:setup].call(repo)
      output, status = dry_run(repo, *scenario[:args], allow_failure: !scenario.fetch(:success, true))
      expected_success = scenario.fetch(:success, true)
      assert(status.success? == expected_success, "#{scenario[:name]} dry-run success should be #{expected_success}")
      scenario[:includes].each { |needle| assert_includes(output, needle, scenario[:name]) }
    ensure
      FileUtils.rm_rf(repo)
    end
  end
end

def test_default_pi_configuration
  repo = init_repo
  write(repo, "app.txt", "hello\n")
  commit_all(repo, "initial")
  write(repo, "app.txt", "hello changed\n")

  output, status = dry_run(repo, "--intent", "Review defaults")

  assert(status.success?, "default Pi configuration dry-run should succeed")
  assert_includes(output, "Pi provider: moonshotai", "default provider")
  assert_includes(output, "Pi model: kimi-k3", "default model")
  assert_includes(output, "Pi thinking: max", "default thinking level")
  assert_includes(output, "Runner: interactive Pi TUI in a visible Zellij session", "interactive runner")
  assert_includes(output, "Pi tools: read,grep,find,ls", "review tool boundary")
  assert_includes(output, "Match review depth to the change's size, risk, and project context.", "proportional review prompt")
  assert_includes(output, "Use tools when needed to understand affected behavior", "review exploration prompt")
  assert_includes(output, "state the review limitation instead of claiming no actionable findings", "incomplete review prompt")
  assert(!output.match?(/at most \d+ tool calls/i), "review prompt should not contain a numeric tool-call budget")
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

def test_socket_dir_defaults_without_shell_setup
  previous = ENV.delete("ZELLIJ_SOCKET_DIR")
  socket_dir = PiVisibleSession.ensure_zellij_socket_dir!

  assert(socket_dir == "/tmp/zellij-#{Process.uid}", "socket dir should use the short stable per-user default")
  assert(Dir.exist?(socket_dir), "socket dir should be created")
  socket_command = PiVisibleSession.zellij_shell_command("list-sessions")
  assert_includes(socket_command, "ZELLIJ_SOCKET_DIR", "socket-aware command")
  assert_includes(socket_command, socket_dir, "socket-aware command")
ensure
  if previous
    ENV["ZELLIJ_SOCKET_DIR"] = previous
  else
    ENV.delete("ZELLIJ_SOCKET_DIR")
  end
end

def test_include_repo_bundles_related_diff
  primary = init_repo
  related = init_repo

  write(primary, "primary.txt", "before\n")
  commit_all(primary, "initial primary")

  write(related, "AGENTS.md", "# Related guidance\n\nPreserve historical notes.\n")
  write(related, "related.txt", "before\n")
  commit_all(related, "initial related")
  write(related, "related.txt", "after\n")
  write(related, "new-note.md", "new related context\n")

  output, status = dry_run(primary, "--include-repo", related, "--intent", "Review both repos")

  assert(status.success?, "include-repo dry-run should succeed")
  assert_includes(output, "Review target: clean primary working tree with included repositories", "include repo primary")
  assert_includes(output, "# Related Repositories", "include repo")
  assert_includes(output, "Repository: #{File.realpath(related)}", "include repo")
  assert_includes(output, "Preserve historical notes.", "include repo authority")
  assert_includes(output, "+after", "include repo diff")
  assert_includes(output, "new related context", "include repo untracked")

  commit_all(related, "related changes")
  clean_output, clean_status = dry_run(primary, "--include-repo", related, "--intent", "Review both repos", allow_failure: true)
  assert(!clean_status.success?, "all-clean included repos should not create an empty review")
  assert_includes(clean_output, "No diff content found to review.", "all-clean include repo")
ensure
  FileUtils.rm_rf(primary) if primary
  FileUtils.rm_rf(related) if related
end

tests = [
  method(:test_pi_handoff_extension_tracks_interactive_turns),
  method(:test_review_scenarios),
  method(:test_default_pi_configuration),
  method(:test_secret_untracked_skip),
  method(:test_project_context_includes_parent_and_repo_authority_files),
  method(:test_socket_dir_defaults_without_shell_setup),
  method(:test_include_repo_bundles_related_diff)
]

tests.each do |test|
  test.call
  puts "PASS #{test.name}"
end

puts "All self-checks passed."
