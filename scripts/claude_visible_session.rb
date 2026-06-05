# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"

module ClaudeVisibleSession
  BYPASS_WARNING_MARKERS = ["Bypass", "Permissions", "Yes", "accept"].freeze
  READY_MARKERS = ["Claude Code", "❯"].freeze
  PASTE_CHUNK_SIZE = 8_000
  READY_TIMEOUT_SECONDS = 60

  module_function

  def run_session(
    skill_name:,
    session:,
    repo_root:,
    pane_name:,
    claude_shell_command:,
    prompt_text:,
    prompt_path:,
    system_prompt_path:,
    prompt_label:,
    sent_message:
  )
    ensure_required_command!("zellij", skill_name)
    ensure_required_command!("claude", skill_name)
    ensure_zellij_socket_dir!(skill_name)

    if zellij_session_exists?(session)
      warn "Zellij session already exists: #{session}"
      warn "#{skill_name} sessions are one-off; choose a new --zellij-session name, or run `#{zellij_shell_command("delete-session", session)}` (or `#{zellij_shell_command("kill-session", session)}` if active) first."
      exit 1
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
      "sh",
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
      warn "Zellij did not return a pane id; cannot safely paste the prompt."
      delete_zellij_session(session)
      exit 1
    end

    close_other_terminal_panes(session, pane_id)
    unless wait_for_claude_prompt(session, pane_id, prompt_label)
      delete_zellij_session(session)
      exit 1
    end

    handoff_path = default_handoff_path(prompt_path)
    done_marker_path = default_done_marker_path(prompt_path)
    FileUtils.rm_f([handoff_path, done_marker_path])
    prompt_text = with_completion_handoff(prompt_text, handoff_path, done_marker_path)
    File.write(prompt_path, prompt_text)

    zellij("--session", session, "action", "focus-pane-id", pane_id)
    unless open_ghostty_attach(session, repo_root)
      warn "Failed to open the visible Ghostty attach tab; not sending the #{prompt_label} invisibly."
      delete_zellij_session(session)
      exit 1
    end

    sleep 1
    paste_text(session, pane_id, prompt_text)
    sleep 2
    zellij("--session", session, "action", "send-keys", "--pane-id", pane_id, "Enter")

    puts "#{sent_message}: #{session}"
    puts "Zellij pane: #{pane_id}"
    puts "Prompt bundle: #{prompt_path}"
    puts "System prompt: #{system_prompt_path}"
    puts "Handoff file: #{handoff_path}"
    puts "Done marker: #{done_marker_path}"
    puts
    puts "Watch:"
    puts zellij_shell_command("attach", session)
    puts
    puts "Completion check:"
    puts "test -f #{done_marker_path.shellescape} && sed -n '1,220p' #{handoff_path.shellescape}"
    puts
    puts "Codex observation policy:"
    puts "Let the user watch in Zellij/Ghostty. Poll the done marker cheaply when needed; inspect the pane only on request, at a bounded checkpoint, or to verify a concrete finding."
    puts
    puts "Quick inspect (viewport only):"
    puts zellij_shell_command("--session", session, "action", "dump-screen", "--pane-id", pane_id)
    puts
    puts "Full transcript (diagnostic only, writes to a temp file):"
    puts zellij_shell_command("--session", session, "action", "dump-screen", "--pane-id", pane_id, "--full", "--path", diagnostic_screen_path(skill_name, session))
    puts
    puts "Interrupt:"
    puts zellij_shell_command("--session", session, "action", "send-keys", "--pane-id", pane_id, "Esc")
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
    socket_dir = ENV.fetch("ZELLIJ_SOCKET_DIR", "")
    if socket_dir.empty?
      warn "ZELLIJ_SOCKET_DIR is required for #{skill_name}'s visible Zellij workflow."
      warn "Set it once in shell startup, for example: export ZELLIJ_SOCKET_DIR=/tmp/zellij"
      warn "Then open a new terminal and rerun the helper. This keeps plain `zellij attach <session>` working everywhere."
      exit 1
    end

    begin
      FileUtils.mkdir_p(socket_dir)
    rescue SystemCallError => e
      warn "Could not create ZELLIJ_SOCKET_DIR #{socket_dir.inspect}: #{e.message}"
      exit 1
    end
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
    (["zellij"] + args).shelljoin
  end

  def zellij_session_exists?(session)
    stdout, _stderr, status = zellij("list-sessions", "--short", allow_failure: true)
    return false unless status.success?

    stdout.lines.map(&:strip).include?(session)
  end

  def zellij_dump_screen(session, pane_id, full: false)
    args = ["--session", session, "action", "dump-screen", "--pane-id", pane_id]
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

  def delete_zellij_session(session)
    zellij("delete-session", session, "--force", allow_failure: true)
  end

  def bypass_warning_screen?(screen)
    BYPASS_WARNING_MARKERS.all? { |marker| screen.include?(marker) }
  end

  def claude_ready_screen?(screen)
    READY_MARKERS.all? { |marker| screen.include?(marker) } && !bypass_warning_screen?(screen)
  end

  def accept_bypass_warning(session, pane_id)
    warn "Claude bypass-permissions startup screen detected; selecting Yes, I accept."
    zellij("--session", session, "action", "send-keys", "--pane-id", pane_id, "2", "Enter")
  end

  def wait_for_claude_prompt(session, pane_id, prompt_label)
    deadline = Time.now + READY_TIMEOUT_SECONDS

    until Time.now > deadline
      screen = zellij_dump_screen(session, pane_id)
      if bypass_warning_screen?(screen)
        accept_bypass_warning(session, pane_id)
        sleep 1
        next
      end

      return true if claude_ready_screen?(screen)

      sleep 0.5
    end

    warn "Claude pane did not show a ready prompt within #{READY_TIMEOUT_SECONDS}s; not sending the #{prompt_label}."
    warn "Inspect it with: #{zellij_shell_command("--session", session, "action", "dump-screen", "--pane-id", pane_id)}"
    false
  end

  def paste_text(session, pane_id, text)
    # Bracketed paste keeps embedded newlines and line-leading command syntax literal.
    text.each_char.each_slice(PASTE_CHUNK_SIZE) do |chars|
      zellij("--session", session, "action", "paste", "--pane-id", pane_id, "--", chars.join)
    end
  end

  def with_completion_handoff(text, handoff_path, done_marker_path)
    <<~TEXT
      #{text}

      ## Completion Handoff

      At the end of the run, write your final handoff to:

      ```text
      #{handoff_path}
      ```

      Then create this done marker as your final filesystem action:

      ```text
      #{done_marker_path}
      ```

      The handoff file should contain the same final findings or implementation summary you print in the terminal. If you are blocked, still write the handoff file with the blocker and then create the done marker.
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
    attach_inner = "export ZELLIJ_SOCKET_DIR=#{ENV.fetch("ZELLIJ_SOCKET_DIR").shellescape}; " \
                   "#{command_path("zellij").shellescape} attach #{session.shellescape}; exec /bin/zsh -l"
    attach_command = "/bin/zsh -lc #{Shellwords.escape(attach_inner)}"

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
