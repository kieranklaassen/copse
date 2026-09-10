# frozen_string_literal: true

require "test_helper"
require "open3"

# The Overmind path: Copse contributes the environment and nothing else, because
# Overmind gives every process its own pty and therefore needs no split session.
class OvermindTest < Minitest::Test
  FakeWorktree = Struct.new(:root, :host, :port, :companion_port, :database_suffix,
                            keyword_init: true) do
    def url = "http://#{host}:#{port}"
  end

  # Overrides the one call that would replace this process, so the arguments and
  # environment can be inspected.
  class RecordingSession < Copse::Session
    attr_reader :exec_env, :exec_argv

    def exec(env, *argv)
      @exec_env = env
      @exec_argv = argv
    end
  end

  def setup
    # exec_overmind chdirs, and this process is not replaced by an exec here, so the
    # cwd has to be put back before teardown removes the directory it moved into.
    @cwd = Dir.pwd
    @dir = Dir.mktmpdir("copse-overmind")
    @root = File.realpath(@dir)
    @worktree = FakeWorktree.new(root: @root, host: "cora.localhost", port: 5368,
                                 companion_port: 9911)
    @out = StringIO.new
  end

  def teardown
    Dir.chdir(@cwd)
    super
  end

  def session(procfile, advertiser: nil)
    File.write(File.join(@root, "Procfile.dev"), procfile)
    RecordingSession.new(@worktree, root: @root, out: @out, advertiser: advertiser)
  end

  # Records which way it was asked to advertise. Threaded or forked is the whole
  # distinction on this path.
  RecordingAdvertiser = Class.new do
    attr_reader :calls

    def initialize = @calls = []
    def start = @calls << :start
    def stop = @calls << :stop
    def fork_watching_parent = @calls << :fork_watching_parent
  end

  # --- The exec ------------------------------------------------------------

  def test_hands_the_whole_procfile_to_overmind_and_forwards_arguments
    s = session("web: bin/rails server\ncss: bin/watch\n")

    s.exec_overmind(["-l", "web"])

    assert_equal ["overmind", "start", "-f", File.join(@root, "Procfile.dev"), "-p", "5368",
                  "-l", "web"],
                 s.exec_argv
  end

  def test_the_callers_own_port_flag_still_wins
    # Ours comes first, so a later -p from the command line overrides it.
    s = session("web: bin/rails server\n")

    s.exec_overmind(["-p", "4000"])

    assert_equal %w[-p 5368 -p 4000], s.exec_argv.last(4)
  end

  def test_the_derived_port_reaches_overmind_unoffset
    # Overmind supervises `web` itself, so the foreman base-port offset must not be
    # applied here: `web` first in Procfile.dev gets base + 0.
    s = session("web: bin/rails server\ncss: bin/watch\n")

    s.exec_overmind

    assert_equal "5368", s.exec_env["PORT"]
    assert_equal "5368", s.exec_env["COPSE_PORT"]
    assert_equal "http://cora.localhost:5368", s.exec_env["COPSE_URL"]
    assert_equal "cora.localhost", s.exec_env["COPSE_HOST"]
    assert_equal "9911", s.exec_env["VITE_RUBY_PORT"]
  end

  def test_announces_the_url_like_the_foreman_path
    session("web: bin/rails server\n").exec_overmind

    assert_includes @out.string, "=> Copse: http://cora.localhost:5368"
  end

  # --- Zeroconf naming ------------------------------------------------------

  # Threads do not survive an exec, so the announcement has to be forked into a
  # process of its own here. Started in-process -- as the foreman path does -- it
  # would be replaced by Overmind milliseconds later and the name would never be
  # answered for.
  def test_the_advertiser_is_forked_rather_than_started_in_process
    advertiser = RecordingAdvertiser.new

    session("web: bin/rails server\n", advertiser: advertiser).exec_overmind

    assert_equal [:fork_watching_parent], advertiser.calls
  end

  def test_overmind_is_handed_the_reachability_environment_too
    @worktree.host = "cora.thicc.local"
    s = session("web: bin/rails server\n", advertiser: RecordingAdvertiser.new)

    s.exec_overmind

    assert_equal "0.0.0.0", s.exec_env["BINDING"]
    assert_equal ".cora.thicc.local", s.exec_env["RAILS_DEVELOPMENT_HOSTS"]
  end

  def test_writes_no_temporary_procfile
    s = session("web: bin/rails server\ncss: bin/watch\n")

    s.exec_overmind

    assert_equal [File.join(@root, "Procfile.dev")],
                 s.exec_argv.grep(/Procfile/),
                 "the app's own Procfile.dev is what overmind runs"
  end

  def test_runs_overmind_from_the_app_root
    # `.overmind.sock` is created relative to overmind's own cwd, so `overmind
    # connect web` from the app root only finds it if overmind started there.
    s = session("web: bin/rails server\n")

    Dir.chdir(Dir.tmpdir)
    s.exec_overmind

    assert_equal @root, File.realpath(Dir.pwd)
  end

  # --- The `web` position warning ------------------------------------------

  def test_warns_when_web_is_not_the_first_entry
    # Overmind assigns base + index * 100, so a `web` line further down never sees
    # the derived port and the banner would name a URL nothing is listening on.
    session("css: bin/watch\nweb: bin/rails server\n").exec_overmind

    assert_includes @out.string, "`web` is entry 2"
    assert_includes @out.string, "5468"
    assert_includes @out.string, "5368"
  end

  def test_is_quiet_when_web_is_first
    session("web: bin/rails server\ncss: bin/watch\n").exec_overmind

    refute_includes @out.string, "entry"
  end

  def test_is_quiet_when_there_is_no_web_entry_at_all
    session("css: bin/watch\njs: bin/build\n").exec_overmind

    refute_includes @out.string, "entry"
  end

  # --- The explicit port flag ----------------------------------------------

  def test_warns_when_the_web_line_sets_its_own_port
    # The foreman path strips this flag; overmind runs the app's own Procfile, so
    # the flag survives and `rails server` honours it over PORT.
    session("web: bin/rails s --port 3000\ncss: bin/watch\n").exec_overmind

    assert_includes @out.string, "explicit port"
    assert_includes @out.string, "5368"
  end

  def test_is_quiet_when_the_web_line_leaves_the_port_alone
    session("web: bin/rails server\n").exec_overmind

    refute_includes @out.string, "explicit port"
  end

  # --- The probe -----------------------------------------------------------

  def test_the_probe_fails_when_overmind_is_not_on_path
    with_path("") do
      refute_predicate session("web: bin/rails server\n"), :overmind_available?
    end
  end

  def test_the_probe_succeeds_against_a_working_overmind
    with_path(fake_overmind) do
      assert_predicate session("web: bin/rails server\n"), :overmind_available?
    end
  end

  def test_the_probe_fails_on_an_overmind_that_cannot_run
    dir = File.join(@root, "broken")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "overmind"), "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, File.join(dir, "overmind"))

    with_path(dir) do
      refute_predicate session("web: bin/rails server\n"), :overmind_available?
    end
  end

  # --- Copse.start dispatch ------------------------------------------------

  def test_start_execs_overmind_when_it_is_installed
    File.write(File.join(@root, "Procfile.dev"), "web: bin/rails server\ncss: bin/watch\n")
    port = Copse::Worktree.new(@root).port

    out = run_start(path: fake_overmind, args: %w[-l web])

    assert_includes out, "overmind-argv: start -f #{File.join(@root, 'Procfile.dev')} -p #{port} -l web"
    assert_includes out, "overmind-port: #{port}"
  end

  def test_overmind_is_told_to_skip_its_own_env_file
    s = session("web: bin/rails server\n")

    s.exec_overmind

    assert_equal "1", s.exec_env["OVERMIND_SKIP_ENV"]
  end

  # --- Against the real binary ---------------------------------------------
  #
  # The probe and the env handling are claims about overmind's CLI, and a stand-in
  # can only confirm the shape it was written to. These run when overmind is
  # actually installed.

  def test_the_probe_matches_the_real_overmind_cli
    skip "overmind is not installed" unless real_overmind?

    assert_predicate session("web: bin/rails server\n"), :overmind_available?
  end

  def test_the_real_overmind_has_no_version_subcommand
    # Why the probe uses `--version`: this is what an `overmind version` probe would
    # have seen, on every machine, forever silently downgrading to foreman.
    skip "overmind is not installed" unless real_overmind?

    _out, _err, status = Open3.capture3("overmind", "version")

    refute_predicate status, :success?
  end

  def test_a_port_in_an_env_file_does_not_beat_the_derived_port
    # Both files, because they are defeated by different things: OVERMIND_SKIP_ENV
    # covers `.env` and does nothing for `.overmind.env`, which only `-p` covers.
    [".env", ".overmind.env"].each do |name|
      skip "overmind and tmux are not both installed" unless real_overmind? && tmux?

      File.write(File.join(@root, name), "PORT=9999\n")
      File.write(File.join(@root, "Procfile.dev"), %(web: sh -c "echo web-port=$PORT"\n))
      port = Copse::Worktree.new(@root).port

      out = run_start(path: ENV.fetch("PATH"))

      assert_includes out, "web-port=#{port}", "#{name} beat the derived port"
      refute_includes out, "web-port=9999", "#{name} beat the derived port"
    ensure
      FileUtils.rm_f(File.join(@root, name))
    end
  end

  def test_start_falls_back_to_the_foreman_session_when_overmind_is_missing
    # bin/dev is committed, so a teammate without overmind still has to boot.
    File.write(File.join(@root, "Procfile.dev"), "web: echo booted\n")

    out = run_start(path: File.join(@root, "empty"))

    assert_includes out, "booted"
    refute_includes out, "overmind-argv"
  end

  private

  # A stand-in overmind, shaped like the real CLI: `--version` succeeds and a
  # `version` subcommand does not exist (real overmind exits 3 on it). On `start` it
  # prints what it was handed instead of supervising anything.
  def fake_overmind
    dir = File.join(@root, "fake")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "overmind")
    File.write(path, <<~SH)
      #!/bin/sh
      case "$1" in
        --version|-v) echo "Overmind version 2.5.1"; exit 0 ;;
        start|s) ;;
        *) echo "No help topic for '$1'" >&2; exit 3 ;;
      esac
      shift
      echo "overmind-argv: start $@"
      echo "overmind-port: $PORT"
      echo "overmind-skip-env: $OVERMIND_SKIP_ENV"
    SH
    File.chmod(0o755, path)
    dir
  end

  def real_overmind? = system("overmind", "--version", out: File::NULL, err: File::NULL)

  def tmux? = system("tmux", "-V", out: File::NULL, err: File::NULL)

  def with_path(dir)
    previous = ENV["PATH"]
    ENV["PATH"] = dir
    yield
  ensure
    ENV["PATH"] = previous
  end

  # Runs the real Copse.start in a child process, since the overmind path replaces
  # the process it runs in.
  def run_start(path:, args: [])
    script = "require \"copse\"; exit Copse.start(process_manager: :overmind, args: #{args.inspect})"
    lib = File.expand_path("../lib", __dir__)
    out, _status = Open3.capture2e(
      { "PATH" => "#{path}:/usr/bin:/bin" },
      RbConfig.ruby, "-I", lib, "-e", script, chdir: @root
    )
    out
  end
end
