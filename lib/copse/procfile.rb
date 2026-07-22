# frozen_string_literal: true

module Copse
  # Reads a Procfile and splits it into the foreground `web` process and the rest.
  #
  # Parsing only. The lifecycle -- spawning, teardown, signal handling -- lives in
  # Session, so everything here is a pure function that can be tested without a
  # process tree.
  class Procfile
    Entry = Struct.new(:name, :command, keyword_init: true)

    WEB = "web"

    # Control operators that make Ruby's Process.spawn hand the string to
    # /bin/sh, which then becomes the pid foreman records.
    FIXABLE_SEPARATORS = [";", "&&", "||"].freeze
    UNFIXABLE_SEPARATORS = ["|", "&"].freeze

    # The characters Ruby itself treats as requiring a shell (mirrors
    # rb_exec_fillarg). A command containing any of these is spawned via
    # `/bin/sh -c` even when it is a single command.
    SHELL_REQUIRED = /[*?{}\[\]<>()~&|\\$;'"`\n#]/.freeze

    # Matches an explicit port flag on a command line: `-p 3000`, `--port 3000`,
    # or `--port=3000`.
    PORT_FLAG = /\s+(?:-p|--port)(?:=|\s+)\d+\b/.freeze

    attr_reader :entries

    def initialize(entries)
      @entries = entries
    end

    def self.parse(text)
      entries = text.to_s.lines.filter_map do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        name, command = stripped.split(":", 2)
        next if command.nil?

        command = command.strip
        next if command.empty?

        Entry.new(name: name.strip, command: command)
      end
      new(entries)
    end

    def self.load(path)
      File.exist?(path) ? parse(File.read(path)) : nil
    end

    # The `web` entry, matched by name. Real templates ship
    # `web: env RUBY_DEBUG_OPEN=true bin/rails server`, so never assume a bare
    # `bin/rails server`.
    def web
      entries.find { |entry| entry.name == WEB }
    end

    # Everything that is not `web`. These go to foreman.
    def secondaries
      entries.reject { |entry| entry.name == WEB }
    end

    # Removes an explicit port flag from a command.
    #
    # An explicit `--port` beats the PORT environment variable in `rails server`,
    # so a Procfile shipping `web: bin/rails s --port 3000` -- which vite_ruby's
    # own example does -- would silently boot on 3000 and defeat the derived
    # port. Stripping the flag is what makes the stock template work unchanged.
    def self.strip_port_flag(command)
      command.gsub(PORT_FLAG, "")
    end

    def self.port_flag?(command)
      command.match?(PORT_FLAG)
    end

    # Rewrites a command so the process foreman records is the real one, not a
    # `/bin/sh` that will not forward SIGTERM.
    #
    # Returns [rewritten_command, warning_or_nil].
    #
    # Three nearby forms are wrong and were measured wrong:
    #   `exec sh -c "a; b"`   -> recorded pid is still sh; the orphan survives
    #   `exec a; b`           -> exec replaces the shell with `a`; `b` never runs
    #   `a | exec b`          -> the recorded pid is the shell awaiting the pipeline
    # What works is inserting `exec` before the *final* command of a chain.
    #
    # A pipeline or a background `&` cannot be collapsed into one pid by any exec
    # placement, so those are left alone and warned about instead of silently
    # "fixed".
    def self.signal_transparent(command)
      operators = top_level_operators(command)

      if operators.any? { |op| UNFIXABLE_SEPARATORS.include?(op[:token]) }
        return [command, unfixable_warning(command, operators)]
      end

      return [command, nil] if operators.empty? && !command.match?(SHELL_REQUIRED)

      # A single command that still needs a shell (a redirect, a glob, a quoted
      # argument): prefixing exec replaces the shell with it, which is correct.
      return ["exec #{command}", nil] if operators.empty?

      # A chain: exec the last command. A Procfile entry whose final command is
      # short-lived would exit immediately and stop being a long-running process
      # at all, so "the process we care about is last" is forced by what a
      # Procfile entry is, not merely a convention.
      last = operators.last
      cut = last[:at] + last[:token].length
      head = command[0, cut]
      tail = command[cut..].to_s
      indent = tail[/\A\s*/]
      ["#{head}#{indent}exec #{tail.lstrip}", nil]
    end

    # Finds control operators outside quotes.
    #
    # Quote-awareness matters: `bin/rails runner 'A.watch; B.watch'` is a single
    # command with a quoted semicolon, not a chain, and treating it as one would
    # rewrite a working line.
    def self.top_level_operators(command)
      operators = []
      in_single = false
      in_double = false
      index = 0

      while index < command.length
        char = command[index]

        if in_single
          in_single = false if char == "'"
        elsif in_double
          if char == "\\"
            index += 1
          elsif char == '"'
            in_double = false
          end
        else
          case char
          when "'" then in_single = true
          when '"' then in_double = true
          when "\\" then index += 1
          when ";", "\n" then operators << { token: ";", at: index }
          when "&"
            if command[index + 1] == "&"
              operators << { token: "&&", at: index }
              index += 1
            else
              operators << { token: "&", at: index }
            end
          when "|"
            if command[index + 1] == "|"
              operators << { token: "||", at: index }
              index += 1
            else
              operators << { token: "|", at: index }
            end
          end
        end

        index += 1
      end

      operators
    end

    def self.unfixable_warning(_command, operators)
      kind = operators.any? { |op| op[:token] == "|" } ? "a pipeline" : "a background &"
      "uses #{kind}, which keeps a shell in front of it -- its child processes may " \
        "survive teardown. Consider splitting it into separate Procfile entries."
    end
  end
end
