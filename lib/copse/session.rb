# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"

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

  # Everything the session needs before it spawns anything: the environment, a
  # safe temporary Procfile, and a trustworthy answer to whether foreman works.
  class Session
    MIN_FOREMAN_VERSION = "0.90.0"

    attr_reader :worktree, :root

    def initialize(worktree, root: nil, out: $stdout)
      @worktree = worktree
      @root = File.expand_path(root || worktree.root)
      @out = out
    end

    def procfile
      return @procfile if defined?(@procfile)

      @procfile = Procfile.load(File.join(root, "Procfile.dev"))
    end

    # The variables every process Copse starts receives.
    #
    # COPSE_PORT exists because foreman rewrites PORT for its own children
    # (base_port + index * 100), so a secondary never sees the derived port under
    # the name PORT. COPSE_PORT is the name foreman does not touch.
    def copse_env
      {
        "PORT" => worktree.port.to_s,
        "COPSE_PORT" => worktree.port.to_s,
        "COPSE_HOST" => worktree.host,
        "COPSE_URL" => worktree.url,
        "VITE_RUBY_PORT" => worktree.companion_port.to_s
      }
    end

    # The foreground process keeps the inherited bundler environment: it *is* the
    # Rails app and needs its bundle.
    def web_env
      copse_env
    end

    # Foreman must not inherit the bundler environment. `bin/dev` has to load the
    # bundle to require copse at all, so foreman would otherwise inherit
    # BUNDLE_GEMFILE and RUBYOPT and die with "foreman is not currently included
    # in the bundle" -- even when foreman is installed.
    def foreman_env
      copse_env.merge(bundler_overrides)
    end

    # Process.spawn *merges* its env hash rather than replacing the environment,
    # so handing it Bundler.original_env is not enough: the inherited BUNDLE_*
    # keys survive the merge. Removing them requires explicit nils.
    def bundler_overrides
      return {} unless defined?(Bundler) && Bundler.respond_to?(:original_env)

      original = Bundler.original_env
      overrides = {}
      (ENV.keys - original.keys).each { |key| overrides[key] = nil }
      original.each { |key, value| overrides[key] = value if ENV[key] != value }
      overrides
    end

    # The foreground command, with any explicit port flag removed so the derived
    # PORT applies. Falls back to `bin/rails server` when there is no Procfile, or
    # when a Procfile exists but names no `web` process.
    def web_command
      entry = procfile&.web
      return "bin/rails server" if entry.nil?

      Procfile.strip_port_flag(entry.command)
    end

    # Non-web entries. When a Procfile exists but has no `web` line, every entry
    # is a secondary and the foreground falls back to `bin/rails server`.
    def secondaries
      return [] if procfile.nil?

      procfile.web ? procfile.secondaries : procfile.entries
    end

    def secondaries?
      secondaries.any?
    end

    # Writes the secondaries to a Procfile foreman can run, inside a private
    # directory. The file's contents are commands foreman will execute, and
    # derived hostnames are deliberately reproducible, so a predictable path in a
    # world-writable directory would be a symlink/TOCTOU surface.
    #
    # Returns [directory, procfile_path]. The caller owns removing the directory.
    def write_temp_procfile
      dir = Dir.mktmpdir("copse-")
      File.chmod(0o700, dir)
      path = File.join(dir, "Procfile")

      lines = secondaries.map do |entry|
        command, warning = Procfile.signal_transparent(entry.command)
        @out.puts "copse: `#{entry.name}` #{warning}" if warning
        "#{entry.name}: #{command}\n"
      end

      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(lines.join)
      end

      [dir, path]
    end

    # Whether `foreman start` will actually work.
    #
    # Probing is the only reliable answer. `command -v foreman` and
    # File.executable? both succeed on a version-manager shim whose gem is absent
    # for the active Ruby, and the real invocation then dies with a
    # Gem::GemNotFoundException backtrace. Capturing stderr is the point: it is
    # what keeps that backtrace off the developer's screen.
    #
    # Probes with the same environment the real spawn uses -- otherwise the
    # bundler case passes the probe and fails the run.
    def foreman_available?
      foreman_version
      @foreman_probe[:ok]
    end

    def foreman_version
      return @foreman_probe[:version] if defined?(@foreman_probe)

      out, _err, status = Open3.capture3(foreman_env, "foreman", "version")
      @foreman_probe = { ok: status.success?, version: status.success? ? out.strip : nil }
      @foreman_probe[:version]
    rescue Errno::ENOENT, Errno::EACCES
      @foreman_probe = { ok: false, version: nil }
      nil
    end

    # One clear line, never a backtrace.
    def foreman_error_message
      "copse: cannot run `foreman`, which is needed for the #{secondaries.size} non-web " \
        "#{secondaries.size == 1 ? 'process' : 'processes'} in Procfile.dev. " \
        "Add `foreman` to your Gemfile, or install it for the Ruby you are using " \
        "(a version manager keeps gems per Ruby version, so switching versions can " \
        "leave foreman behind)."
    end

    def foreman_outdated?
      version = foreman_version
      return false if version.nil?

      Gem::Version.new(version) < Gem::Version.new(MIN_FOREMAN_VERSION)
    rescue ArgumentError
      false
    end

    def foreman_version_warning
      "copse: foreman #{foreman_version} is older than #{MIN_FOREMAN_VERSION}; " \
        "process teardown is only verified from #{MIN_FOREMAN_VERSION} onward."
    end
  end
end
