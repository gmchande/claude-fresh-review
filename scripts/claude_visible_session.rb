# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"

module ClaudeVisibleSession
  module_function

  def run_session(
    skill_name:,
    session:,
    repo_root:,
    pane_name:,
    claude_shell_command:,
    prompt_path:,
    system_prompt_path:,
    handoff_path: nil,
    done_marker_path: nil,
    session_id_path: nil,
    prompt_label:,
    sent_message:
  )
    ensure_required_command!("zellij", skill_name)
    ensure_required_command!("claude", skill_name)
    ensure_required_command!("zsh", skill_name)
    ensure_zellij_socket_dir!(skill_name)

    if zellij_session_exists?(session)
      warn "Zellij session already exists: #{session}"
      warn "#{skill_name} sessions are one-off; choose a new --zellij-session name, or run `#{zellij_shell_command("delete-session", session)}` (or `#{zellij_shell_command("kill-session", session)}` if active) first."
      exit 1
    end

    handoff_path ||= default_handoff_path(prompt_path)
    done_marker_path ||= default_done_marker_path(prompt_path)
    session_id_path ||= default_session_id_path(prompt_path)
    FileUtils.rm_f([handoff_path, done_marker_path, session_id_path])
    File.open(system_prompt_path, "a") do |file|
      file.write("\n")
      file.write(completion_handoff_instructions(handoff_path))
    end

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
      pane_name,
      "--",
      "zsh",
      "-lc",
      claude_shell_command,
      allow_failure: true
    )

    unless status.success?
      warn "Failed to create Zellij Claude pane in session: #{session}"
      warn stderr unless stderr.empty?
      delete_zellij_session(session)
      exit status.exitstatus || 1
    end

    pane_id = stdout.strip
    if pane_id.empty?
      warn "Zellij did not return a pane id; cannot safely watch the #{prompt_label}."
      delete_zellij_session(session)
      exit 1
    end

    close_other_terminal_panes(session, pane_id)
    zellij("--session", session, "action", "focus-pane-id", pane_id)
    ghostty_opened = open_ghostty_attach(session, repo_root)
    warn "Ghostty auto-open unavailable; the #{prompt_label} is still running. Attach manually with `#{zellij_shell_command("attach", session)}`." unless ghostty_opened

    puts "#{sent_message}: #{session}"
    puts "Zellij pane: #{pane_id}"
    puts "Prompt bundle: #{prompt_path}"
    puts "System prompt: #{system_prompt_path}"
    puts "Handoff file: #{handoff_path}"
    puts "Done marker: #{done_marker_path}"
    puts "Claude session id: #{session_id_path} (written when the run starts)"
    puts "Ghostty auto-open: #{ghostty_opened ? "opened" : "unavailable; use the watch command below"}"
    puts
    puts "Watch:"
    puts zellij_shell_command("attach", session)
    puts
    puts "Completion check (marker holds Claude's exit code):"
    puts "if test -f #{done_marker_path.shellescape}; then cat #{done_marker_path.shellescape}; else echo 'PENDING_OR_AMBIGUOUS: no done marker yet'; fi"
    puts "if test -f #{done_marker_path.shellescape} && [ \"$(cat #{done_marker_path.shellescape})\" = \"0\" ]; then cat #{handoff_path.shellescape}; else ls -l #{done_marker_path.shellescape} #{handoff_path.shellescape} 2>/dev/null || true; fi"
    puts
    puts "Codex observation policy:"
    puts "Let the user watch in Zellij, with Ghostty auto-open when available. First marker check should be after 2-3 minutes; keep polling marker/handoff paths before diagnosing pane errors."
    puts
    puts "Quick inspect (viewport only):"
    puts zellij_shell_command("--session", session, "action", "dump-screen", "--pane-id", pane_id)
    puts
    puts "Session state diagnostic:"
    puts zellij_shell_command("list-sessions")
    puts
    puts "Follow up with the same Claude session (run from the repo root):"
    puts "cd #{repo_root.shellescape} && claude --resume \"$(cat #{session_id_path.shellescape})\""
    puts
    puts "Cleanup (only when the user says they are done with this run; leave the session open for follow-ups otherwise):"
    puts "#{zellij_shell_command("kill-session", session)} # if still attached"
    puts zellij_shell_command("delete-session", "--force", session)
    puts
    puts "Full transcript (diagnostic only, writes to a temp file):"
    puts zellij_shell_command("--session", session, "action", "dump-screen", "--pane-id", pane_id, "--full", "--path", diagnostic_screen_path(skill_name, session))
    puts
    puts "Interrupt:"
    puts zellij_shell_command("--session", session, "action", "send-keys", "--pane-id", pane_id, "Ctrl c")
  end

  def ensure_required_command!(name, skill_name)
    return if command_available?(name)

    if name == "zellij"
      warn "Zellij is required for #{skill_name}. Install it with `brew install zellij` and rerun this command."
    else
      warn "#{name} not found on PATH."
    end
    exit 1
  end

  def ensure_zellij_socket_dir!(skill_name)
    socket_dir = ENV.fetch("ZELLIJ_SOCKET_DIR", "").strip
    socket_dir = "/tmp/zellij-#{Process.uid}" if socket_dir.empty?
    ENV["ZELLIJ_SOCKET_DIR"] = socket_dir

    begin
      FileUtils.mkdir_p(socket_dir)
    rescue SystemCallError => e
      warn "Could not create ZELLIJ_SOCKET_DIR #{socket_dir.inspect}: #{e.message}"
      exit 1
    end

    socket_dir
  end

  def run_command(*cmd, allow_failure: false)
    stdout, stderr, status = Open3.capture3(*cmd)
    if !status.success? && !allow_failure
      warn "Command failed: #{cmd.shelljoin}"
      warn stderr unless stderr.empty?
      exit status.exitstatus || 1
    end
    [stdout, stderr, status]
  end

  def command_available?(name)
    _stdout, _stderr, status = run_command("sh", "-c", "command -v #{Shellwords.escape(name)} >/dev/null 2>&1", allow_failure: true)
    status.success?
  end

  def zellij(*args, allow_failure: false)
    stdout, stderr, status = run_command("zellij", *args, allow_failure: true)
    if !status.success? && !allow_failure
      warn "Command failed: #{zellij_shell_command(*args)}"
      warn stderr unless stderr.empty?
      exit status.exitstatus || 1
    end

    [stdout, stderr, status]
  end

  def zellij_shell_command(*args)
    (["env", "ZELLIJ_SOCKET_DIR=#{ENV.fetch("ZELLIJ_SOCKET_DIR")}", "zellij"] + args).shelljoin
  end

  def zellij_session_exists?(session)
    stdout, _stderr, status = zellij("list-sessions", "--short", allow_failure: true)
    return false unless status.success?

    stdout.lines.map(&:strip).include?(session)
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

  def delete_zellij_session(session)
    zellij("delete-session", "--force", session, allow_failure: true)
  end

  def completion_handoff_instructions(handoff_path)
    <<~TEXT
      ## Completion Handoff

      At the end of the run, write your final handoff to:

      ```text
      #{handoff_path}
      ```

      The handoff file should contain the same final findings or implementation summary you print in the terminal. Writing the handoff file under /tmp is expected and is not a repo edit. If you are blocked, still write the handoff file with the blocker. The session writes its own done marker automatically when the run exits, so you do not need to create one.
    TEXT
  end

  def default_handoff_path(prompt_path)
    return prompt_path.sub(/\.md\z/, "-handoff.md") if prompt_path.end_with?(".md")

    "#{prompt_path}-handoff.md"
  end

  def default_done_marker_path(prompt_path)
    return prompt_path.sub(/\.md\z/, ".done") if prompt_path.end_with?(".md")

    "#{prompt_path}.done"
  end

  def default_session_id_path(prompt_path)
    return prompt_path.sub(/\.md\z/, "-session-id.txt") if prompt_path.end_with?(".md")

    "#{prompt_path}-session-id.txt"
  end

  def diagnostic_screen_path(skill_name, session)
    skill_part = skill_name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    session_part = session.gsub(/[^A-Za-z0-9_.-]/, "_")
    "/tmp/#{skill_part}-#{session_part}.screen.txt"
  end

  def applescript_string(value)
    "\"#{value.to_s.gsub("\\", "\\\\\\").gsub('"', '\\"')}\""
  end

  def command_path(name)
    stdout, _stderr, status = run_command("sh", "-c", "command -v #{Shellwords.escape(name)}", allow_failure: true)
    return stdout.strip if status.success? && !stdout.strip.empty?

    name
  end

  def open_ghostty_attach(session, repo_root)
    unless command_available?("osascript")
      warn "osascript not found; skipping Ghostty auto-open."
      return false
    end

    attach_inner = "export ZELLIJ_SOCKET_DIR=#{ENV.fetch("ZELLIJ_SOCKET_DIR").shellescape}; " \
                   "#{command_path("zellij").shellescape} attach #{session.shellescape}; " \
                   "cd #{repo_root.shellescape} 2>/dev/null || cd; " \
                   "exec #{command_path("zsh").shellescape} -l"
    attach_command = "#{command_path("zsh").shellescape} -lc #{Shellwords.escape(attach_inner)}"

    script = <<~APPLESCRIPT
      tell application "Ghostty"
        set cfg to new surface configuration
        set initial working directory of cfg to #{applescript_string(repo_root)}
        set command of cfg to #{applescript_string(attach_command)}
        set wait after command of cfg to true
        if (count of windows) > 0 then
          set newTab to new tab in front window with configuration cfg
          select tab newTab
        else
          set newWin to new window with configuration cfg
        end if
        activate
      end tell
    APPLESCRIPT

    _stdout, stderr, status = Open3.capture3("osascript", stdin_data: script)
    return true if status.success?

    warn "Failed to open Ghostty attached to Zellij session: #{session}"
    warn stderr unless stderr.empty?
    false
  end
end
