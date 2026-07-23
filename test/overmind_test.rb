# frozen_string_literal: true

require "test_helper"
require "open3"

# The Overmind path: Copse contributes the environment and nothing else, because
# Overmind gives every process its own pty and therefore needs no split session.
class OvermindTest < Minitest::Test
  FakeWorktree = Struct.new(:root, :host, :port, :companion_port, keyword_init: true) do
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
    @dir = Dir.mktmpdir("copse-overmind")
    @root = File.realpath(@dir)
    @worktree = FakeWorktree.new(root: @root, host: "cora.localhost", port: 5368,
                                 companion_port: 9911)
    @out = StringIO.new
  end

  def session(procfile)
    File.write(File.join(@root, "Procfile.dev"), procfile)
    RecordingSession.new(@worktree, root: @root, out: @out)
  end

  # --- The exec ------------------------------------------------------------

  def test_hands_the_whole_procfile_to_overmind_and_forwards_arguments
    s = session("web: bin/rails server\ncss: bin/watch\n")

    s.exec_overmind(["-l", "web"])

    assert_equal ["overmind", "start", "-f", File.join(@root, "Procfile.dev"), "-l", "web"],
                 s.exec_argv
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

  def test_writes_no_temporary_procfile
    s = session("web: bin/rails server\ncss: bin/watch\n")

    s.exec_overmind

    assert_equal [File.join(@root, "Procfile.dev")],
                 s.exec_argv.grep(/Procfile/),
                 "the app's own Procfile.dev is what overmind runs"
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

    assert_includes out, "overmind-argv: start -f #{File.join(@root, 'Procfile.dev')} -l web"
    assert_includes out, "overmind-port: #{port}"
  end

  def test_start_falls_back_to_the_foreman_session_when_overmind_is_missing
    # bin/dev is committed, so a teammate without overmind still has to boot.
    File.write(File.join(@root, "Procfile.dev"), "web: echo booted\n")

    out = run_start(path: File.join(@root, "empty"))

    assert_includes out, "booted"
    refute_includes out, "overmind-argv"
  end

  private

  # A stand-in overmind: answers `version`, and on `start` prints what it was
  # handed instead of supervising anything.
  def fake_overmind
    dir = File.join(@root, "fake")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "overmind")
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = "version" ]; then echo "Overmind version 2.5.1"; exit 0; fi
      echo "overmind-argv: $@"
      echo "overmind-port: $PORT"
    SH
    File.chmod(0o755, path)
    dir
  end

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
