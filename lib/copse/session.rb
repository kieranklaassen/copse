# frozen_string_literal: true

require "open3"
require "socket"
require "tmpdir"
require "fileutils"

module Copse
  # Everything the session needs before it spawns anything: the environment, a
  # safe temporary Procfile, and a trustworthy answer to whether foreman works.
  class Session
    MIN_FOREMAN_VERSION = "0.90.0"

    # How long to wait before checking whether foreman died on the spot. Long
    # enough to catch a missing binary or an empty Procfile, short enough to be
    # invisible next to a Rails boot.
    FOREMAN_STARTUP_GRACE = 0.3

    # How long teardown waits for a child to honour SIGTERM before SIGKILL. Chosen
    # to sit just past foreman's own 5s escalation so its children get their
    # graceful window first.
    REAP_TIMEOUT = 6
    REAP_POLL = 0.05

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

      # The guard spans everything after the banner, not just the foreground wait.
      # The foreman probe spawns a child of its own, and a signal arriving during it
      # used to escape the handler entirely -- which surfaced as a bogus "cannot run
      # foreman" error rather than a clean interrupt.
      guarded do
        # No secondaries means no foreman -- not even a preflight. The Procfile the
        # install generator writes has only a `web` line, so preflighting a tool
        # this run will never use would refuse to boot the most common app. Running
        # `foreman start` against an empty Procfile is fatal anyway.
        next run_foreground unless secondaries?

        unless foreman_available?
          @out.puts foreman_error_message
          next 1
        end
        @out.puts foreman_version_warning if foreman_outdated?

        @foreman_pid = spawn_foreman(write_temp_procfile)
        report_if_foreman_died_early
        run_foreground
      end
    ensure
      teardown
    end

    private

    # Runs the body with SIGTERM converted to an Interrupt, and keeps that
    # conversion in place while `start`'s `ensure` tears down.
    #
    # Two windows depend on this. Without the trap at all, SIGTERM kills the
    # process outright and `ensure` never runs. With the trap restored too early, a
    # second SIGTERM arriving during teardown kills us between `terminate_web` and
    # `terminate_foreman` -- which was measured to leave the watcher alive.
    # Interrupt is caught here rather than inside `run_foreground` so the foreman
    # startup grace is covered too; otherwise a signal during that sleep escaped as
    # a raw backtrace.
    def guarded
      previous = Signal.trap("TERM") { raise Interrupt }
      @term_trap_previous = previous
      yield
    rescue Interrupt
      # Ctrl-C, or a SIGTERM converted above. The TTY already delivered SIGINT to
      # the whole foreground group, so there is nothing to announce -- `ensure`
      # cleans up.
      INTERRUPTED_STATUS
    end

    def restore_term_trap
      return unless defined?(@term_trap_previous)

      Signal.trap("TERM", @term_trap_previous || "DEFAULT")
      remove_instance_variable(:@term_trap_previous)
    end

    def run_foreground
      @web_pid = Process.spawn(web_env, web_command, chdir: root)
      _, status = Process.waitpid2(@web_pid)
      @web_pid = nil

      code = status.exitstatus || INTERRUPTED_STATUS
      report_port_collision if code != 0 && port_in_use?
      code
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

    # Foreman is signalled *first*, then waited on.
    #
    # Ordering matters: `Process.waitpid` on the web process is unbounded, so a web
    # process that delays or ignores SIGTERM used to park teardown here forever and
    # foreman was never signalled at all -- every watcher survived. Signalling
    # foreman up front means its own 5s SIGTERM-to-SIGKILL escalation runs in
    # parallel with the web process shutting down.
    def teardown
      signal_foreman
      terminate_web
      reap_foreman
      remove_temp_procfile
      restore_term_trap
    end

    def terminate_web
      return if @web_pid.nil?

      Process.kill("TERM", @web_pid)
      reap(@web_pid, "the web process")
    rescue Errno::ESRCH, Errno::ECHILD
      # Already gone.
    ensure
      @web_pid = nil
    end

    # Waits for `pid`, escalating to SIGKILL rather than blocking forever. Teardown
    # must always complete; a child that ignores SIGTERM is not a reason to hang.
    def reap(pid, what, timeout: REAP_TIMEOUT)
      deadline = Time.now + timeout
      loop do
        return if Process.waitpid(pid, Process::WNOHANG)
        break if Time.now >= deadline

        sleep REAP_POLL
      end

      @out.puts "copse: #{what} did not exit within #{timeout}s; sending SIGKILL."
      Process.kill("KILL", pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      # Already gone.
    end

    # Signals foreman's own pid and lets foreman reap its children.
    #
    # Never a negative pgid. Foreman does not call setsid, so its process group is
    # the caller's own -- `Process.kill("-TERM", pgid)` would signal the
    # developer's shell session.
    # Signals foreman's own pid and lets foreman reap its children.
    #
    # Never a negative pgid. Foreman does not call setsid, so its process group is
    # the caller's own -- `Process.kill("-TERM", pgid)` would signal the
    # developer's shell session.
    def signal_foreman
      return if @foreman_pid.nil? || @foreman_reaped

      Process.kill("TERM", @foreman_pid)
    rescue Errno::ESRCH
      # Expected on Ctrl-C: the TTY signalled foreman directly, because its
      # children share this terminal's foreground process group.
    end

    def reap_foreman
      return if @foreman_pid.nil? || @foreman_reaped

      reap(@foreman_pid, "foreman")
    ensure
      @foreman_pid = nil
    end

    def remove_temp_procfile
      return if @procfile_dir.nil?

      FileUtils.remove_entry(@procfile_dir) if File.exist?(@procfile_dir)
    ensure
      @procfile_dir = nil
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

      @procfile = Procfile.load(procfile_path)
    end

    def procfile_path = File.join(root, "Procfile.dev")

    # Hands the whole Procfile -- `web` included -- to Overmind, replacing this
    # process. Never returns.
    #
    # There is no split session here and no foreground/background distinction to
    # preserve: Overmind gives every process its own tmux pty, so `binding.irb`
    # works over `overmind connect web` rather than by holding this terminal. All
    # Copse contributes on this path is the environment.
    #
    # The environment is `copse_env` unoffset -- deliberately not
    # `foreman_port_env`. Overmind derives each child's port as
    # `base + index * 100` from PORT just as foreman does, but here it supervises
    # `web` too, so offsetting the base would hand `web` a port Copse never
    # derived and the banner above would name the wrong URL.
    # `-p` before the caller's own arguments, so `bin/dev -p 4000` still wins.
    #
    # The base port is passed as a *flag* rather than left to the inherited PORT
    # because only the flag survives Overmind's env files. Measured against
    # Overmind 2.5.1: with `PORT` in `.overmind.env` and the derived port merely
    # inherited, the app booted on the env file's port; with `-p` it booted on the
    # derived one. Secondaries still get `base + index * 100`.
    def exec_overmind(args = [])
      @out.puts "=> Copse: #{worktree.url}"
      @out.puts overmind_web_position_warning if web_out_of_position?
      exec(overmind_env, "overmind", "start", "-f", procfile_path, "-p", worktree.port.to_s, *args)
    end

    # OVERMIND_SKIP_ENV is this path's `--env /dev/null`, and for the same reason:
    # Overmind loads the app's `.env` and applies it *over* the environment it was
    # handed, so anything Copse derives is otherwise beatable by a stale `.env`.
    #
    # It is not the port's only defence -- `-p` above is, and it covers
    # `.overmind.env`, which this flag does not skip. What this buys is that both
    # supervisors see the same environment. That matters more here than it looks:
    # the overmind `bin/dev` falls back to the foreman session on a machine without
    # overmind, so if the two disagreed about `.env`, one committed repo would
    # behave differently per teammate.
    #
    # Only the supervisor's env-file loading is suppressed, not the app's.
    # dotenv-rails still reads `.env` inside Rails, exactly as on the foreman path.
    def overmind_env
      copse_env.merge("OVERMIND_SKIP_ENV" => "1")
    end

    # Whether `overmind start` will actually work. Overmind is a Go binary rather
    # than a gem, so unlike foreman there is no bundler environment to strip and no
    # version-manager shim to see past -- but probing still beats `command -v`,
    # which succeeds on an unexecutable file.
    #
    # `--version`, not `version`: Overmind has no `version` subcommand and exits 3
    # on one, which would make every probe fail and silently downgrade the whole
    # path to foreman.
    def overmind_available?
      _out, _err, status = Open3.capture3("overmind", "--version")
      status.success?
    rescue Errno::ENOENT, Errno::EACCES
      false
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

    # Foreman derives each child's port as `base_port + index * 100`, and takes
    # base_port from PORT. Handing it the derived port therefore gave the *first*
    # secondary exactly the web process's port -- so a secondary that binds it
    # collides with puma, and copse's own collision message then blames another
    # worktree.
    #
    # Offsetting the base is the least-bad of three options. Removing PORT entirely
    # looks cleaner but is worse: foreman then falls back to 5000, which is the
    # macOS AirPlay Receiver port and is on our own reserved list. Secondaries that
    # need the app's real port read COPSE_PORT, which foreman does not touch.
    FOREMAN_PORT_OFFSET = 100

    def foreman_port_env
      { "PORT" => (worktree.port + FOREMAN_PORT_OFFSET).to_s }
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
      base = copse_env.merge(foreman_port_env)
      overrides = bundler_overrides
      return [base] if overrides.empty?

      [base.merge(overrides), base]
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
    # The foreground command goes through the same signal-transparency transform as
    # the secondaries. Without it, a `web` line needing a shell (`... 2>&1`) made
    # @web_pid the shell rather than the app: teardown reaped the shell instantly
    # and the real server survived, reparented to pid 1, still holding the derived
    # port. `exec` is only added when the command would have gone through /bin/sh
    # anyway, so the common metacharacter-free case is untouched.
    def web_command
      entry = procfile&.web
      return "bin/rails server" if entry.nil?

      command, warning = Procfile.signal_transparent(Procfile.strip_port_flag(entry.command))
      @out.puts "copse: `web` #{warning}" if warning
      command
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

    # Only Overmind cares: it hands `web` the port at its Procfile index, so a
    # `web` line that is not first gets `port + index * 100`. On the foreman path
    # Copse spawns `web` itself with the derived PORT, so its position is
    # irrelevant.
    def web_out_of_position?
      entry = procfile&.web
      !entry.nil? && procfile.entries.first != entry
    end

    def overmind_web_position_warning
      index = procfile.entries.index(procfile.web)
      "copse: `web` is entry #{index + 1} in Procfile.dev, so overmind will start it on " \
        "#{worktree.port + index * 100} rather than the derived port #{worktree.port} " \
        "(each process gets base + index * 100). Move `web` to the top of Procfile.dev."
    end

    # Writes the secondaries to a Procfile foreman can run, inside a private
    # directory. The file's contents are commands foreman will execute, and
    # derived hostnames are deliberately reproducible, so a predictable path in a
    # world-writable directory would be a symlink/TOCTOU surface.
    #
    # Returns the Procfile path. The directory is recorded on the instance the
    # moment it exists, so teardown can remove it even if a later step in this
    # method raises -- returning it to the caller would have leaked it.
    def write_temp_procfile
      dir = Dir.mktmpdir("copse-")
      @procfile_dir = dir
      File.chmod(0o700, dir)
      path = File.join(dir, "Procfile")

      lines = secondaries.map do |entry|
        command, warning = Procfile.signal_transparent(entry.command)
        @out.puts "copse: `#{entry.name}` #{warning}" if warning
        stdin_warning = Procfile.stdin_sensitive_warning(entry.command)
        @out.puts "copse: `#{entry.name}` #{stdin_warning}" if stdin_warning
        "#{entry.name}: #{command}\n"
      end

      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(lines.join)
      end

      path
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
