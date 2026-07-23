# frozen_string_literal: true

require "test_helper"

# The spawn-free half of Session: environment assembly, the temporary Procfile,
# and the foreman probe. The lifecycle is exercised in session_lifecycle_test.rb.
class SessionInputsTest < Minitest::Test
  FakeWorktree = Struct.new(:root, :host, :port, :companion_port, keyword_init: true) do
    def url = "http://#{host}:#{port}"
  end

  def setup
    @dir = Dir.mktmpdir("copse-session")
    @root = File.realpath(@dir)
    @worktree = FakeWorktree.new(root: @root, host: "cora.localhost", port: 5368,
                                 companion_port: 9911)
  end

  def session(procfile: nil)
    File.write(File.join(@root, "Procfile.dev"), procfile) if procfile
    Copse::Session.new(@worktree, root: @root, out: StringIO.new)
  end

  # --- Environment (R8, KTD11) ----------------------------------------------

  def test_exports_the_copse_variables
    env = session.copse_env

    assert_equal "5368", env["PORT"]
    assert_equal "5368", env["COPSE_PORT"]
    assert_equal "cora.localhost", env["COPSE_HOST"]
    assert_equal "http://cora.localhost:5368", env["COPSE_URL"]
    assert_equal "9911", env["VITE_RUBY_PORT"]
  end

  def test_copse_port_duplicates_port_because_foreman_rewrites_port
    # foreman spawns each child with PORT = base_port + index * 100, so a
    # secondary never sees the derived port under the name PORT.
    env = session.copse_env

    assert_equal env["PORT"], env["COPSE_PORT"]
  end

  def test_the_web_environment_keeps_the_bundler_environment
    # The foreground process is the Rails app; it needs its bundle.
    out, _err, status = Open3.capture3(
      session.web_env, "ruby", "-e", "puts ENV.fetch('BUNDLE_GEMFILE', 'ABSENT')"
    )

    assert_predicate status, :success?
    refute_equal "ABSENT", out.strip,
                 "the web process lost its bundle, which would break `require`"
  end

  def test_the_preferred_foreman_environment_drops_the_bundler_environment
    # Proven by observing a real child process, not by inspecting the hash:
    # Process.spawn merges rather than replaces, so handing it
    # Bundler.original_env would leave the inherited BUNDLE_* keys in place.
    #
    # The expectation is whatever preceded bundler rather than a literal "ABSENT".
    # A BUNDLE_GEMFILE already exported by the shell -- which is how
    # gemfiles/rails71.gemfile is run -- is not the same thing as bundler having set
    # one, and only the second is Copse's to undo. RUBYOPT is checked alongside it
    # because bundler's `-rbundler/setup` is what actually pulls foreman into this
    # bundle, and no ambient value makes that legitimate.
    script = "puts ENV.fetch('BUNDLE_GEMFILE', 'ABSENT'); puts ENV.fetch('RUBYOPT', 'ABSENT')"
    out, _err, status = Open3.capture3(session.foreman_env_candidates.first, "ruby", "-e", script)
    gemfile, rubyopt = out.lines.map(&:strip)

    assert_predicate status, :success?
    assert_equal Bundler.original_env.fetch("BUNDLE_GEMFILE", "ABSENT"), gemfile,
                 "foreman would inherit the bundle and fail with 'not currently included in the bundle'"
    refute_includes rubyopt, "bundler/setup",
                    "foreman would still be loaded through this bundle's setup"
  end

  def test_every_foreman_environment_carries_the_copse_variables
    session.foreman_env_candidates.each do |candidate|
      out, _err, = Open3.capture3(candidate, "ruby", "-e", "puts ENV.fetch('COPSE_PORT', 'ABSENT')")

      assert_equal "5368", out.strip
    end
  end

  # --- Foreground command (Q4) ----------------------------------------------

  def test_web_command_has_its_explicit_port_flag_stripped
    # vite_ruby's own example Procfile ships this line.
    s = session(procfile: "web: bin/rails s --port 3000\nvite: bin/vite dev\n")

    assert_equal "bin/rails s", s.web_command
  end

  def test_web_command_goes_through_the_signal_transparency_transform
    # Without this, a `web` line needing a shell made @web_pid the shell rather than
    # the app: teardown reaped the shell instantly and the real server survived,
    # reparented to pid 1, still holding the derived port.
    s = session(procfile: "web: bin/rails server 2>&1\n")

    assert_equal "exec bin/rails server 2>&1", s.web_command
  end

  def test_web_command_is_untouched_when_it_needs_no_shell
    s = session(procfile: "web: env RUBY_DEBUG_OPEN=true bin/rails server\n")

    assert_equal "env RUBY_DEBUG_OPEN=true bin/rails server", s.web_command
  end

  def test_web_command_strips_the_port_flag_before_transforming
    s = session(procfile: "web: bin/rails s --port 3000 2>&1\n")

    assert_equal "exec bin/rails s 2>&1", s.web_command
  end

  def test_the_temp_procfile_directory_is_recorded_before_the_file_is_written
    # Recorded on the instance the moment mktmpdir returns, so teardown can remove
    # it even if a later step in write_temp_procfile raises. Returning it to the
    # caller instead leaked the directory on any mid-method failure.
    s = session(procfile: "web: bin/rails server\ncss: bin/watch\n")
    path = s.write_temp_procfile
    begin
      assert_equal File.dirname(path), s.instance_variable_get(:@procfile_dir)
    ensure
      FileUtils.remove_entry(File.dirname(path))
    end
  end

  def test_web_command_falls_back_when_there_is_no_procfile
    assert_equal "bin/rails server", session.web_command
    assert_empty session.secondaries
    refute_predicate session, :secondaries?
  end

  def test_a_procfile_with_no_web_line_falls_back_and_treats_everything_as_secondary
    s = session(procfile: "worker: bin/jobs\ncss: bin/watch\n")

    assert_equal "bin/rails server", s.web_command
    assert_equal %w[worker css], s.secondaries.map(&:name)
  end

  def test_a_procfile_with_only_a_web_line_has_no_secondaries
    s = session(procfile: "web: bin/rails server\n")

    assert_equal "bin/rails server", s.web_command
    refute_predicate s, :secondaries?
  end

  # --- Temporary Procfile ---------------------------------------------------

  def test_writes_secondaries_with_exec_inserted
    s = session(procfile: <<~PROC)
      web: bin/rails server
      css: bin/rails tailwindcss:watch
      log: echo starting; tail -f log/development.log
    PROC

    path = s.write_temp_procfile
    dir = File.dirname(path)
    begin
      contents = File.read(path)

      refute_includes contents, "web:", "the foreground process must not go to foreman"
      assert_includes contents, "css: bin/rails tailwindcss:watch"
      assert_includes contents, "log: echo starting; exec tail -f log/development.log"
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  def test_the_temp_procfile_is_private
    s = session(procfile: "web: bin/rails server\ncss: bin/watch\n")

    path = s.write_temp_procfile
    dir = File.dirname(path)
    begin
      assert_equal "700", format("%o", File.stat(dir).mode & 0o777)
      assert_equal "600", format("%o", File.stat(path).mode & 0o777)
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  def test_warns_once_about_a_line_it_cannot_make_signal_transparent
    out = StringIO.new
    File.write(File.join(@root, "Procfile.dev"), "web: bin/rails server\nlog: bin/watch | tee out\n")
    s = Copse::Session.new(@worktree, root: @root, out: out)

    path = s.write_temp_procfile
    dir = File.dirname(path)
    begin
      assert_includes out.string, "pipeline"
      assert_includes out.string, "`log`"
      # Left unmodified rather than silently "fixed".
      assert_includes File.read(path), "log: bin/watch | tee out"
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  def test_warns_about_a_bare_tailwind_watch_and_still_runs_it
    out = StringIO.new
    File.write(File.join(@root, "Procfile.dev"),
               "web: bin/rails server\ncss: tailwindcss -i a.css -o b.css --watch\n")
    s = Copse::Session.new(@worktree, root: @root, out: out)

    path = s.write_temp_procfile
    dir = File.dirname(path)
    begin
      assert_includes out.string, "`css`"
      assert_includes out.string, "--watch=always"
      # A warning, not a rewrite: the app's own command is what runs.
      assert_includes File.read(path), "css: tailwindcss -i a.css -o b.css --watch"
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  # --- Foreman probe (KTD9) -------------------------------------------------

  def test_the_probe_succeeds_when_foreman_works
    # foreman is a development dependency precisely so this is exercised rather
    # than skipped.
    assert_predicate session, :foreman_available?
    refute_nil session.foreman_version
  end

  def test_the_probe_reports_a_usable_version
    assert_operator Gem::Version.new(session.foreman_version), :>=,
                    Gem::Version.new(Copse::Session::MIN_FOREMAN_VERSION)
    refute_predicate session, :foreman_outdated?
  end

  def test_the_preferred_foreman_environment_restores_the_pre_bundler_path
    # Bundler prepends its own bin directory to PATH. Restoring the original is
    # deliberate: foreman must resolve the way it would outside the bundle, which
    # is exactly what Rails' own /bin/sh `bin/dev` achieves. It also means
    # ENV["PATH"] is not the seam the probe reads -- see PinnedPathSession below.
    skip "not running under bundler" unless defined?(Bundler) && Bundler.respond_to?(:original_env)

    assert_equal Bundler.original_env["PATH"], session.foreman_env_candidates.first["PATH"]
  end

  def test_the_inherited_environment_is_the_second_candidate
    # Stripping the bundle is right for foreman-as-a-system-gem, but it is exactly
    # wrong when foreman is provided *only* by the app's Gemfile. Probing both is
    # what makes those two setups both work.
    skip "not running under bundler" unless defined?(Bundler) && Bundler.respond_to?(:original_env)

    candidates = session.foreman_env_candidates

    # What a child actually sees, since Process.spawn merges: a key the candidate
    # omits is inherited rather than unset. Asserting on the hash alone read a
    # shell-exported BUNDLE_GEMFILE -- how gemfiles/rails71.gemfile is run -- as the
    # bundle leaking through, when the override Copse owes it is only ever back to
    # the pre-bundler value.
    effective = ->(candidate, key) { candidate.key?(key) ? candidate[key] : ENV[key] }

    assert_equal 2, candidates.size
    assert_equal Bundler.original_env["BUNDLE_GEMFILE"],
                 effective.call(candidates.first, "BUNDLE_GEMFILE"),
                 "the preferred candidate still carries this bundle"
    refute candidates.last.key?("BUNDLE_GEMFILE"),
           "the inherited candidate should not override BUNDLE_GEMFILE at all"
  end

  def test_falls_back_to_the_inherited_environment_when_the_stripped_one_cannot_find_foreman
    # Simulates foreman being available only inside the bundle: the first
    # candidate's PATH cannot see it, the second one's can.
    stub_dir = File.join(@root, "bundled")
    FileUtils.mkdir_p(stub_dir)
    stub = File.join(stub_dir, "foreman")
    File.write(stub, "#!/bin/sh\necho 0.90.0\n")
    File.chmod(0o755, stub)

    s = TwoPathSession.new(@worktree, root: @root, out: StringIO.new,
                           first: "", second: stub_dir)

    assert_predicate s, :foreman_available?
    assert_equal "0.90.0", s.foreman_version
    assert_equal stub_dir, s.foreman_env["PATH"],
                 "the spawn must use the environment the probe actually succeeded with"
  end

  class TwoPathSession < Copse::Session
    def initialize(*args, first:, second:, **kwargs)
      super(*args, **kwargs)
      @paths = [first, second]
    end

    def foreman_env_candidates
      @paths.map { |path| copse_env.merge("PATH" => path) }
    end
  end

  # Pins PATH for the probe. Necessary because the candidate environments
  # deliberately restore the pre-bundler PATH, so setting ENV["PATH"] cannot
  # reach them.
  class PinnedPathSession < Copse::Session
    def initialize(*args, path:, **kwargs)
      super(*args, **kwargs)
      @path = path
    end

    def foreman_env_candidates
      super.map { |candidate| candidate.merge("PATH" => @path) }
    end
  end

  def pinned_session(path)
    PinnedPathSession.new(@worktree, root: @root, out: StringIO.new, path: path)
  end

  def test_the_probe_fails_when_foreman_is_not_on_path
    s = pinned_session("")

    refute_predicate s, :foreman_available?
    assert_nil s.foreman_version
  end

  def test_the_probe_swallows_the_shim_backtrace
    # The failure mode this exists for: a version-manager shim that exists and is
    # executable, but explodes with a Gem::GemNotFoundException when run. `command
    # -v` and File.executable? both pass on it; only running it tells the truth.
    shim_dir = File.join(@root, "bin")
    FileUtils.mkdir_p(shim_dir)
    shim = File.join(shim_dir, "foreman")
    File.write(shim, <<~SH)
      #!/bin/sh
      echo "can't find gem foreman (>= 0.a) with executable foreman (Gem::GemNotFoundException)" >&2
      exit 1
    SH
    File.chmod(0o755, shim)

    s = pinned_session(shim_dir)

    assert File.executable?(shim), "the shim is executable, so a file check would pass it"
    refute_predicate s, :foreman_available?, "probing must catch what a file check cannot"
    assert_nil s.foreman_version
  end

  def test_the_probe_reports_an_outdated_foreman
    stub_dir = File.join(@root, "old")
    FileUtils.mkdir_p(stub_dir)
    stub = File.join(stub_dir, "foreman")
    File.write(stub, "#!/bin/sh\necho 0.87.2\n")
    File.chmod(0o755, stub)

    s = pinned_session(stub_dir)

    assert_predicate s, :foreman_available?
    assert_equal "0.87.2", s.foreman_version
    assert_predicate s, :foreman_outdated?
    assert_includes s.foreman_version_warning, Copse::Session::MIN_FOREMAN_VERSION
  end

  def test_the_error_message_names_a_cause_and_carries_no_backtrace
    s = session(procfile: "web: bin/rails server\ncss: bin/watch\n")
    message = s.foreman_error_message

    assert_includes message, "Gemfile"
    assert_includes message, "version manager"
    refute_match(/\.rb:\d+/, message, "the error leaked a backtrace")
    assert_equal 1, message.lines.size
  end
end
