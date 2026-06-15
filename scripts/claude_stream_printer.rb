#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

MAX_TOOL_OUTPUT_CHARS = 4_000

$stdout.sync = true

def summarize_tool_input(input)
  if input.is_a?(Hash)
    command = input["command"] || input[:command]
    return command.to_s if command

    path = input["file_path"] || input[:file_path] || input["path"] || input[:path]
    return path.to_s if path
  end

  input.to_s
end

def truncate(value)
  text = value.to_s
  return text if text.length <= MAX_TOOL_OUTPUT_CHARS

  "#{text[0, MAX_TOOL_OUTPUT_CHARS]}\n... output truncated ..."
end

def print_tool_result(result)
  unless result.is_a?(Hash)
    puts "[tool result]"
    puts truncate(result.inspect)
    return true
  end

  stdout = result["stdout"].to_s
  stderr = result["stderr"].to_s
  content = result["content"].to_s
  file = result["file"].is_a?(Hash) ? result["file"] : nil
  file_content = file ? file["content"].to_s : ""
  printed = false

  unless stdout.empty?
    puts "[tool stdout]"
    puts truncate(stdout)
    printed = true
  end

  unless stderr.empty?
    puts "[tool stderr]"
    puts truncate(stderr)
    printed = true
  end

  if stdout.empty? && stderr.empty? && !content.empty?
    puts "[tool result]"
    puts truncate(content)
    printed = true
  end

  if !printed && !file_content.empty?
    path = file["filePath"] || file["path"] || "file"
    puts "[tool file] #{path} (#{file_content.length} chars)"
    printed = true
  end

  printed
end

STDIN.each_line do |line|
  event = JSON.parse(line)

  case event["type"]
  when "system"
    case event["subtype"]
    when "init"
      puts "[claude] started #{event["model"] || "session"} in #{event["cwd"]}"
    when "status"
      puts "[claude] #{event["status"]}..."
    when "hook_progress"
      output = event["output"].to_s
      puts output unless output.empty?
    end
  when "stream_event"
    stream = event["event"] || {}
    case stream["type"]
    when "content_block_delta"
      delta = stream["delta"] || {}
      print delta["text"] if delta["type"] == "text_delta"
    when "message_stop"
      puts
    end
  when "assistant"
    Array(event.dig("message", "content")).each do |content|
      next unless content["type"] == "tool_use"

      puts
      puts "[tool] #{content["name"]}: #{summarize_tool_input(content["input"])}"
    end
  when "user"
    result = event["tool_use_result"] || {}
    printed = result.empty? ? false : print_tool_result(result)
    unless printed
      Array(event.dig("message", "content")).each do |content|
        next unless content["type"] == "tool_result"

        print_tool_result(content["content"])
      end
    end
  when "result"
    puts
    puts "[claude] finished: #{event["subtype"] || event["status"] || "done"}"
  else
    next
  end
rescue JSON::ParserError, StandardError
  puts line
end
