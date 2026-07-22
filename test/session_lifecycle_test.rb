# frozen_string_literal: true

require "test_helper"
require "json"

# Exercises the real process tree. Nothing here mocks a process: the point of the
# unit is that exiting or interrupting leaves no orphans, and that is only
# observable by starting real children and looking at the process table.
#
# Foreman is a development dependency precisely so these run rather than skip.
class SessionLifecycleTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  def setup
    @dir = Dir.mktmpdir("copse-app")
    @app = File.join(File.realpath(@dir), "cora")
    @tmp = File.join(File.realpath(@dir), "childtmp")
    FileUtils.mkdir_p(File.join(@app, "bin"))
    FileUtils.mkdir_p(@tmp)
  end

  # Writes an executable script into the fake app's bin/. Deliberately
  # app-relative: a bare `sleep` would resolve from any working directory and so
  # would pass whether or not foreman was told where the app root is.
  def bin(name, body)
    path = File.join(@app, "bin", name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def procfile(contents)
    File.write(File.join(@app, "Procfile.dev"), contents)
  end

  # A script that records its own pid and then blocks, so a test can ask whether
  # it survived teardown.
  def long_running(name, pidfile)
    bin(name, "echo $$ > #{pidfile}\nexec sleep 300")
  end

  def pidfile(name) = File.join(@app, "#{name}.pid")

  def read_pid(path, timeout: 12)
    deadline = Time.now + timeout
    while Time.now < deadline
      if File.exist?(path)
        contents = File.read(path).strip
        return Integer(contents) unless contents.empty?
      end

      sleep 0.05
    end
    nil
  end

  # Runs copse as a real subprocess so it can be signalled and observed.
  #
  # When `path` is given the child runs outside bundler entirely, via
  # Bundler.with_unbundled_env. Setting RUBYOPT/BUNDLE_GEMFILE to nil in the spawn
  # env is not enough: bundler re-injects itself into spawned children (and
  # re-prepends its gem bin directory to PATH), so a PATH restriction would not
  # hold. Running unbundled is also the honest simulation of a machine that simply
  # does not have foreman.
  def spawn_copse(pgroup: false, path: nil)
    log = File.join(@app, "copse.log")
    script = <<~RUBY
      $LOAD_PATH.unshift(#{LIB.inspect})
      require "copse"
      exit(Copse.start(root: #{@app.inspect}))
    RUBY
    env = { "TMPDIR" => @tmp }
    spawn = lambda do
      Process.spawn(env, RbConfig.ruby, "-e", script,
                    out: log, err: [:child, :out], pgroup: pgroup)
    end

    pid =
      if path
        env["PATH"] = path
        Bundler.with_unbundled_env(&spawn)
      else
        spawn.call
      end

    [pid, log]
  end

  def wait_for_exit(pid, timeout: 25)
    deadline = Time.now + timeout
    while Time.now < deadline
      done, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if done

      sleep 0.05
    end
    Process.kill("KILL", pid) rescue nil
    Process.waitpid(pid) rescue nil
    flunk "copse did not exit within #{timeout}s"
  end

  def refute_alive(pid, what, timeout: 8)
    deadline = Time.now + timeout
    sleep 0.05 while alive?(pid) && Time.now < deadline
    refute alive?(pid), "#{what} (pid #{pid}) survived teardown"
  end

  def copse_temp_dirs = Dir.glob(File.join(@tmp, "copse-*"))

  # --- The three exit paths -------------------------------------------------

  def test_web_exiting_normally_leaves_no_orphaned_secondary
    long_running("watcher", pidfile("watcher"))
    bin("web", "sleep 1.5")
    procfile("web: bin/web\ncss: bin/watcher\n")

    pid, log = spawn_copse
    watcher = read_pid(pidfile("watcher"))
    refute_nil watcher, "the secondary never started: #{File.read(log)}"

    status = wait_for_exit(pid)

    assert_equal 0, status.exitstatus, File.read(log)
    refute_alive watcher, "the css watcher"
  end

  def test_interrupting_leaves_no_orphaned_secondary
    long_running("watcher", pidfile("watcher"))
    bin("web", "exec sleep 300")
    procfile("web: bin/web\ncss: bin/watcher\n")

    # A new process group, then SIGINT to the group: exactly what the terminal
    # does when the developer presses Ctrl-C.
    pid, log = spawn_copse(pgroup: true)
    watcher = read_pid(pidfile("watcher"))
    refute_nil watcher, "the secondary never started: #{File.read(log)}"

    Process.kill("-INT", Process.getpgid(pid))
    wait_for_exit(pid)

    refute_alive watcher, "the css watcher"
    refute_includes File.read(log), "Interrupt", "Ctrl-C printed a backtrace"
  end

  def test_sigterm_to_copse_leaves_no_orphaned_secondary
    long_running("watcher", pidfile("watcher"))
    bin("web", "exec sleep 300")
    procfile("web: bin/web\ncss: bin/watcher\n")

    pid, log = spawn_copse
    watcher = read_pid(pidfile("watcher"))
    refute_nil watcher, "the secondary never started: #{File.read(log)}"

    # Without an explicit trap, SIGTERM would kill copse outright and `ensure`
    # would never run -- leaving foreman and its children behind.
    Process.kill("TERM", pid)
    wait_for_exit(pid)

    refute_alive watcher, "the css watcher"
  end

  # --- KTD8 regression: the transform must work end to end ------------------

  def test_a_compound_secondary_runs_and_then_leaves_no_grandchild
    # Both halves matter. Asserting only that nothing survived would pass if the
    # process never started at all -- which is exactly what `exec echo hi; sleep`
    # does, since exec replaces the shell with echo and the sleep never runs.
    marker = pidfile("compound")
    bin("compound", "echo $$ > #{marker}\nexec sleep 300")
    bin("web", "sleep 1.5")
    procfile("web: bin/web\nlog: echo starting; bin/compound\n")

    pid, log = spawn_copse
    grandchild = read_pid(marker)

    assert grandchild, "the compound line's process never ran: #{File.read(log)}"
    assert alive?(grandchild), "the compound line's process was not alive before teardown"

    wait_for_exit(pid)

    refute_alive grandchild, "the compound line's process"
  end

  # --- foreman needs to be told where the app is ----------------------------

  def test_an_app_relative_secondary_actually_starts
    # Proves `-d <app root>` reached foreman. Foreman takes each child's working
    # directory from the Procfile's directory, and the Procfile copse writes lives
    # in a temp dir -- so without -d this command cannot be found at all.
    long_running("watcher", pidfile("watcher"))
    bin("web", "sleep 2")
    procfile("web: bin/web\ncss: bin/watcher\n")

    pid, log = spawn_copse
    watcher = read_pid(pidfile("watcher"))
    wait_for_exit(pid)

    refute_nil watcher,
               "an app-relative secondary never started, so foreman ran it from the wrong " \
               "directory: #{File.read(log)}"
  end

  # --- Apps with nothing for foreman to do ---------------------------------

  def test_an_app_with_only_a_web_line_boots_with_foreman_absent
    # This is the Procfile the install generator writes, so it is the most common
    # app there is. Preflighting a tool this run never uses would refuse to boot it.
    bin("web", "echo booted; exit 0")
    procfile("web: bin/web\n")

    pid, log = spawn_copse(path: "/usr/bin:/bin")
    status = wait_for_exit(pid)
    output = File.read(log)

    assert_equal 0, status.exitstatus, output
    assert_includes output, "booted"
    refute_includes output, "foreman"
  end

  def test_an_app_with_no_procfile_boots_bin_rails_server_with_foreman_absent
    bin("rails", "echo \"rails $1\"\nexit 0")

    pid, log = spawn_copse(path: "/usr/bin:/bin")
    status = wait_for_exit(pid)
    output = File.read(log)

    assert_equal 0, status.exitstatus, output
    assert_includes output, "rails server"
    refute_includes output, "foreman"
  end

  # --- Diagnostics ---------------------------------------------------------

  def test_a_secondary_that_cannot_be_found_is_visible_and_still_tears_down
    # Foreman does NOT exit when one of its commands is missing -- it logs
    # "unknown command" and keeps supervising. That message reaches the shared
    # terminal, so the developer does see it; copse's job is to still tear down
    # cleanly around it rather than to detect it.
    long_running("watcher", pidfile("watcher"))
    bin("web", "sleep 1.5")
    procfile("web: bin/web\ncss: bin/watcher\njs: bin/does-not-exist-anywhere\n")

    pid, log = spawn_copse
    watcher = read_pid(pidfile("watcher"))
    status = wait_for_exit(pid)
    output = File.read(log)

    assert_includes output, "unknown command"
    assert_equal 0, status.exitstatus, output
    refute_alive watcher, "the surviving secondary"
    assert_empty copse_temp_dirs
  end

  def test_foreman_exiting_immediately_is_reported_rather_than_silent
    # The genuine early-death case: foreman itself refuses to start. Stubbed,
    # because a missing secondary command does not produce it.
    stub_dir = File.join(@app, "stub")
    FileUtils.mkdir_p(stub_dir)
    File.write(File.join(stub_dir, "foreman"), <<~SH)
      #!/bin/sh
      if [ "$1" = "version" ]; then echo 0.90.0; exit 0; fi
      echo "ERROR: no processes defined" >&2
      exit 1
    SH
    File.chmod(0o755, File.join(stub_dir, "foreman"))

    bin("web", "sleep 1.5")
    procfile("web: bin/web\ncss: bin/watcher\n")

    pid, log = spawn_copse(path: "#{stub_dir}:/usr/bin:/bin")
    wait_for_exit(pid)
    output = File.read(log)

    assert_includes output, "foreman exited immediately"
    assert_includes output, "css"
  end

  def test_a_missing_foreman_reports_one_clean_line_and_spawns_nothing
    bin("web", "echo SHOULD_NOT_RUN\nexit 0")
    procfile("web: bin/web\ncss: bin/watcher\n")

    pid, log = spawn_copse(path: "/usr/bin:/bin")
    status = wait_for_exit(pid)
    output = File.read(log)

    refute_equal 0, status.exitstatus
    assert_includes output, "cannot run `foreman`"
    refute_includes output, "SHOULD_NOT_RUN", "the web process ran despite the preflight failing"
    refute_match(/\.rb:\d+/, output, "a backtrace reached the developer")
  end

  def test_the_boot_line_names_the_copse_url
    bin("web", "exit 0")
    procfile("web: bin/web\n")

    pid, log = spawn_copse
    wait_for_exit(pid)

    assert_includes File.read(log), "cora.localhost:#{Copse.port_for('cora.localhost')}"
  end

  def test_the_web_processes_exit_status_is_propagated
    bin("web", "exit 3")
    procfile("web: bin/web\n")

    pid, = spawn_copse

    assert_equal 3, wait_for_exit(pid).exitstatus
  end

  # --- The property the whole gem exists for (R5) ---------------------------

  def test_the_web_process_inherits_stdin_and_the_foreground_process_group
    # This is why copse exists: `binding.irb` needs the web process to hold the
    # same stdin as the terminal and to be in the terminal's foreground process
    # group. Whether a prompt visibly echoes needs a real TTY and stays a manual
    # gate, but the two mechanical preconditions are checkable here -- and they are
    # exactly what a daemon or a foreman-multiplexed pipe would break.
    dump = File.join(@app, "web.probe")
    File.write(File.join(@app, "bin", "web"), <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      File.write(#{dump.inspect}, JSON.dump(
        stdin_stat: [$stdin.stat.dev, $stdin.stat.ino],
        stdin_tty: $stdin.tty?,
        pgid: Process.getpgrp,
        pid: Process.pid
      ))
    RUBY
    File.chmod(0o755, File.join(@app, "bin", "web"))
    procfile("web: bin/web\n")

    pid, log = spawn_copse
    wait_for_exit(pid)

    assert File.exist?(dump), "the web process did not run: #{File.read(log)}"
    probe = JSON.parse(File.read(dump))

    # Same stdin object as copse's, not a pipe foreman created.
    assert_equal [$stdin.stat.dev, $stdin.stat.ino], probe["stdin_stat"],
                 "the web process did not inherit copse's stdin"

    # Same process group as this runner, which copse inherited and passed straight
    # through -- so the terminal's signals and input reach the web process. (Read
    # from the runner rather than from copse's pid, which has already exited.)
    assert_equal Process.getpgrp, probe["pgid"],
                 "the web process was placed in its own process group, so it cannot " \
                 "read from the terminal"
  end

  # --- What a child process actually receives (R8, KTD11) ------------------

  def test_the_foreground_process_receives_the_copse_variables
    dump = File.join(@app, "web.env")
    bin("web", "env > #{dump}\nexit 0")
    procfile("web: bin/web\n")

    pid, log = spawn_copse
    wait_for_exit(pid)

    env = File.read(dump).lines.to_h { |l| l.chomp.split("=", 2) }

    assert_equal Copse.port_for("cora.localhost").to_s, env["PORT"], File.read(log)
    assert_equal Copse.port_for("cora.localhost").to_s, env["COPSE_PORT"]
    assert_equal "cora.localhost", env["COPSE_HOST"]
    assert_equal "http://cora.localhost:#{Copse.port_for('cora.localhost')}", env["COPSE_URL"]
    assert_equal Copse.companion_port_for("cora.localhost").to_s, env["VITE_RUBY_PORT"]
  end

  def test_foreman_rewrites_port_for_its_children_but_not_copse_port
    # The reason COPSE_PORT exists. Foreman derives each child's PORT as
    # base_port + index * 100, so the second secondary sees a port copse never
    # derived -- one that can leave the 3000..9999 range entirely or land on a
    # reserved service port. COPSE_PORT is the name foreman does not touch.
    first = File.join(@app, "first.env")
    second = File.join(@app, "second.env")
    bin("first", "env > #{first}\nexec sleep 300")
    bin("second", "env > #{second}\nexec sleep 300")
    bin("web", "sleep 2.5")
    procfile("web: bin/web\nfirst: bin/first\nsecond: bin/second\n")

    pid, log = spawn_copse
    wait_for_exit(pid)

    assert File.exist?(second), "the second secondary never ran: #{File.read(log)}"
    env = File.read(second).lines.to_h { |l| l.chomp.split("=", 2) }
    derived = Copse.port_for("cora.localhost")

    assert_equal derived.to_s, env["COPSE_PORT"],
                 "COPSE_PORT must survive foreman untouched"
    assert_equal (derived + 100).to_s, env["PORT"],
                 "expected foreman's per-child PORT arithmetic (base + index * 100)"
    refute_equal env["COPSE_PORT"], env["PORT"],
                 "if these matched, COPSE_PORT would be redundant"
  end

  # --- Temp directory cleanup ---------------------------------------------

  def test_the_temp_directory_is_removed_when_web_exits
    long_running("watcher", pidfile("watcher"))
    bin("web", "sleep 1.5")
    procfile("web: bin/web\ncss: bin/watcher\n")

    pid, = spawn_copse
    read_pid(pidfile("watcher"))
    wait_for_exit(pid)

    assert_empty copse_temp_dirs, "copse left its temporary Procfile behind"
  end

  def test_the_temp_directory_is_removed_on_interrupt
    long_running("watcher", pidfile("watcher"))
    bin("web", "exec sleep 300")
    procfile("web: bin/web\ncss: bin/watcher\n")

    pid, = spawn_copse(pgroup: true)
    read_pid(pidfile("watcher"))
    Process.kill("-INT", Process.getpgid(pid))
    wait_for_exit(pid)

    assert_empty copse_temp_dirs, "copse left its temporary Procfile behind after Ctrl-C"
  end

  def test_the_temp_directory_is_removed_on_sigterm
    long_running("watcher", pidfile("watcher"))
    bin("web", "exec sleep 300")
    procfile("web: bin/web\ncss: bin/watcher\n")

    pid, = spawn_copse
    read_pid(pidfile("watcher"))
    Process.kill("TERM", pid)
    wait_for_exit(pid)

    assert_empty copse_temp_dirs, "copse left its temporary Procfile behind after SIGTERM"
  end
end
