# frozen_string_literal: true

require "open3"
require "socket"
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

    # How long to wait before checking whether foreman died on the spot. Long
    # enough to catch a missing binary or an empty Procfile, short enough to be
    # invisible next to a Rails boot.
    FOREMAN_STARTUP_GRACE = 0.3

    INTERRUPTED_STATUS = 130

    attr_reader :worktree, :root

    def initialize(worktree, root: nil, out: $stdout)
      @worktree = worktree
      @root = File.expand_path(root || worktree.root)
      @out = out
    end

    # Boots the app and returns the foreground process's exit status.
    #
    # The load-bearing property is that the web process is spawned with this
    # process's own stdin, stdout, and stderr and stays in the terminal's
    # foreground process group, so `binding.irb` and `debug` behave exactly as
    # they do under a bare `rails server`. Nothing may come between the two.
    def start
      @out.puts "=> Copse: #{worktree.url}"

      # No secondaries means no foreman -- not even a preflight. The Procfile the
      # install generator writes has only a `web` line, so preflighting a tool
      # this run will never use would refuse to boot the most common app. Running
      # `foreman start` against an empty Procfile is fatal anyway.
      return with_term_trap { run_foreground } unless secondaries?

      unless foreman_available?
        @out.puts foreman_error_message
        return 1
      end
      @out.puts foreman_version_warning if foreman_outdated?

      dir, path = write_temp_procfile
      @foreman_pid = spawn_foreman(path)

      with_term_trap do
        report_if_foreman_died_early
        run_foreground
      end
    ensure
      teardown(dir)
    end

    private

    def run_foreground
      @web_pid = Process.spawn(web_env, web_command, chdir: root)
      _, status = Process.waitpid2(@web_pid)
      @web_pid = nil

      code = status.exitstatus || INTERRUPTED_STATUS
      report_port_collision if code != 0 && port_in_use?
      code
    rescue Interrupt
      # Ctrl-C. The TTY already delivered SIGINT to the whole foreground group, so
      # there is nothing to announce -- just let `ensure` clean up.
      INTERRUPTED_STATUS
    end

    def spawn_foreman(path)
      Process.spawn(
        foreman_env,
        "foreman", "start",
        "-f", path,
        # Not optional. Foreman takes each child's working directory from the
        # Procfile's own directory, so without this every app-relative command
        # (`bin/rails tailwindcss:watch`, `yarn build --watch`) would run from the
        # temp directory and die with "unknown command". Copse's own cwd does not
        # help; only this does.
        "-d", root,
        # jsbundling-rails and cssbundling-rails both pass this. Without it
        # foreman loads the app's .env, which can clobber the derived PORT.
        "--env", "/dev/null",
        chdir: root
      )
    end

    # A developer should not spend an hour editing CSS with no watcher running.
    # Nothing monitors foreman while the web process holds the foreground, so
    # check once here.
    def report_if_foreman_died_early
      sleep FOREMAN_STARTUP_GRACE
      pid, status = Process.waitpid2(@foreman_pid, Process::WNOHANG)
      return if pid.nil?

      @foreman_reaped = true
      @out.puts "copse: foreman exited immediately (status #{status.exitstatus}). " \
                "The #{secondaries.size == 1 ? 'process' : 'processes'} " \
                "#{secondaries.map(&:name).join(', ')} are not running."
    rescue Errno::ECHILD
      @foreman_reaped = true
    end

    def teardown(dir)
      terminate_web
      terminate_foreman
      FileUtils.remove_entry(dir) if dir && File.exist?(dir)
    end

    def terminate_web
      return if @web_pid.nil?

      Process.kill("TERM", @web_pid)
      Process.waitpid(@web_pid)
    rescue Errno::ESRCH, Errno::ECHILD
      # Already gone.
    ensure
      @web_pid = nil
    end

    # Signals foreman's own pid and lets foreman reap its children.
    #
    # Never a negative pgid. Foreman does not call setsid, so its process group is
    # the caller's own -- `Process.kill("-TERM", pgid)` would signal the
    # developer's shell session.
    def terminate_foreman
      return if @foreman_pid.nil? || @foreman_reaped

      begin
        Process.kill("TERM", @foreman_pid)
      rescue Errno::ESRCH
        # Expected on Ctrl-C: the TTY signalled foreman directly, because its
        # children share this terminal's foreground process group.
      end

      begin
        Process.waitpid(@foreman_pid)
      rescue Errno::ECHILD
        # Already reaped.
      end
    ensure
      @foreman_pid = nil
    end

    # Without a trap, SIGTERM kills this process outright and `ensure` never runs,
    # which would leave foreman and its children behind.
    def with_term_trap
      previous = Signal.trap("TERM") { raise Interrupt }
      yield
    ensure
      Signal.trap("TERM", previous || "DEFAULT")
    end

    # Derived ports are uncoordinated by design, so collisions happen. Puma's
    # "Address already in use" does not reach us -- the web process owns the
    # terminal and we see only an exit status -- so check whether the port is
    # actually held before blaming a collision. A non-zero exit has many causes.
    def port_in_use?
      TCPServer.new("127.0.0.1", worktree.port).close
      false
    rescue Errno::EADDRINUSE
      true
    rescue SystemCallError
      false
    end

    def report_port_collision
      @out.puts "copse: port #{worktree.port} (derived from #{worktree.host}) is already in use. " \
                "Another app or worktree most likely derived the same port."
    end

    public

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

    # The environment foreman is actually spawned with -- whichever candidate the
    # probe found works. Falls back to the preferred candidate when nothing has
    # been probed yet.
    def foreman_env
      foreman_version
      @foreman_env || foreman_env_candidates.first
    end

    # Two ways foreman can be reachable, and neither one covers both.
    #
    # Stripping the bundler environment first is what handles the common case:
    # `bin/dev` has to load the bundle to require copse at all, so foreman would
    # otherwise inherit BUNDLE_GEMFILE and RUBYOPT and die with "foreman is not
    # currently included in the bundle" even though it is installed. That is what
    # Rails' own /bin/sh `bin/dev` achieves by exec'ing foreman outside the bundle.
    #
    # But if foreman is provided *only* by the app's Gemfile, the stripped
    # environment is the one that cannot see it. So the inherited environment is
    # the second candidate rather than an alternative design: probing both is what
    # makes foreman-as-a-system-gem and foreman-in-the-Gemfile both work.
    def foreman_env_candidates
      overrides = bundler_overrides
      return [copse_env] if overrides.empty?

      [copse_env.merge(overrides), copse_env]
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

      @foreman_probe = { ok: false, version: nil }

      foreman_env_candidates.each do |candidate|
        out, _err, status = begin
          Open3.capture3(candidate, "foreman", "version")
        rescue Errno::ENOENT, Errno::EACCES
          # Not on this candidate's PATH, or not executable. Try the next one.
          next
        end

        next unless status.success?

        # Remember the environment that worked: the real spawn must use the same
        # one, or the probe proves nothing.
        @foreman_env = candidate
        @foreman_probe = { ok: true, version: out.strip }
        break
      end

      @foreman_probe[:version]
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
