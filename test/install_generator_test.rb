# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "generators/copse/install_generator"

class InstallGeneratorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("copse-install")
    @root = File.realpath(@dir)
    FileUtils.mkdir_p(File.join(@root, "bin"))
  end

  def run_generator(*args)
    Copse::Generators::InstallGenerator.start(["--quiet", *args], destination_root: @root)
  end

  def read(relative) = File.read(File.join(@root, relative))
  def exists?(relative) = File.exist?(File.join(@root, relative))

  # --- bin/dev -------------------------------------------------------------

  def test_creates_an_executable_bin_dev_pointing_at_copse
    run_generator

    assert exists?("bin/dev")
    assert_includes read("bin/dev"), "Copse.start"
    assert File.executable?(File.join(@root, "bin/dev")), "bin/dev is not executable"
  end

  def test_running_twice_changes_nothing
    run_generator
    first = read("bin/dev")
    procfile = read("Procfile.dev")

    run_generator

    assert_equal first, read("bin/dev")
    assert_equal procfile, read("Procfile.dev")
    assert_equal 1, read("bin/dev").scan("Copse.start").size, "bin/dev accumulated duplicate lines"
    refute exists?("bin/dev.before-copse"), "an already-wired bin/dev should not be backed up"
  end

  def test_an_existing_unrelated_bin_dev_is_backed_up_before_being_replaced
    original = "#!/bin/sh\nbundle check || bundle install\nexec foreman start -f Procfile.dev\n"
    File.write(File.join(@root, "bin/dev"), original)

    run_generator

    assert_includes read("bin/dev"), "Copse.start"
    assert exists?("bin/dev.before-copse"), "the app's own bin/dev was destroyed with no copy"
    assert_equal original, read("bin/dev.before-copse")
  end

  # --- Process manager -----------------------------------------------------

  def test_bin_dev_drives_foreman_by_default
    run_generator

    assert_equal "exit Copse.start\n", read("bin/dev").lines.last
  end

  def test_the_overmind_flag_writes_an_overmind_bin_dev
    run_generator("--process-manager=overmind")

    assert_includes read("bin/dev"), "Copse.start(process_manager: :overmind, args: ARGV)"
  end

  def test_an_existing_overmind_bin_dev_is_not_downgraded_to_foreman
    # The reported bug: the generator force-overwrote a working overmind bin/dev
    # with one that dropped back to foreman, losing `overmind connect`.
    File.write(File.join(@root, "bin/dev"), <<~SH)
      #!/bin/sh
      exec overmind start -f Procfile.dev
    SH

    run_generator

    assert_includes read("bin/dev"), "process_manager: :overmind"
    assert_equal "#!/bin/sh\nexec overmind start -f Procfile.dev\n", read("bin/dev.before-copse")
  end

  def test_an_explicit_foreman_flag_beats_detection
    File.write(File.join(@root, "bin/dev"), "#!/bin/sh\nexec overmind start -f Procfile.dev\n")

    run_generator("--process-manager=foreman")

    refute_includes read("bin/dev"), "overmind"
  end

  def test_switching_process_manager_rewrites_an_already_wired_bin_dev
    run_generator
    run_generator("--process-manager=overmind")

    assert_includes read("bin/dev"), "process_manager: :overmind"
    refute exists?("bin/dev.before-copse"), "a Copse bin/dev holds nothing to back up"

    run_generator("--process-manager=foreman")

    refute_includes read("bin/dev"), "overmind"
  end

  def test_an_overmind_bin_dev_survives_a_second_run
    run_generator("--process-manager=overmind")
    first = read("bin/dev")

    run_generator("--process-manager=overmind")
    assert_equal first, read("bin/dev")

    # And with no flag at all: detection reads the bin/dev it just wrote.
    run_generator
    assert_equal first, read("bin/dev")
  end

  def test_an_unknown_process_manager_is_refused_before_anything_is_written
    previous = $stderr
    $stderr = StringIO.new
    begin
      run_generator("--process-manager=hivemind")
      message = $stderr.string
    ensure
      $stderr = previous
    end

    assert_includes message, "foreman"
    assert_includes message, "overmind"
    refute exists?("bin/dev"), "a refused run still wrote bin/dev"
  end

  def test_the_generated_overmind_bin_dev_is_valid_ruby
    run_generator("--process-manager=overmind")

    _out, err, status = Open3.capture3(RbConfig.ruby, "-c", File.join(@root, "bin/dev"))

    assert_predicate status, :success?, err
  end

  # --- Procfile.dev (R10, AE4) --------------------------------------------

  def test_creates_a_minimal_procfile_when_the_app_has_none
    run_generator

    assert exists?("Procfile.dev")
    assert_includes read("Procfile.dev"), "web:"
    assert_equal 1, read("Procfile.dev").lines.count { |l| l.strip.start_with?("web:") }
  end

  def test_an_existing_procfile_is_left_completely_untouched
    # Covers AE4.
    original = "web: bin/rails server\ncss: bin/rails tailwindcss:watch\n"
    File.write(File.join(@root, "Procfile.dev"), original)

    run_generator

    assert_equal original, read("Procfile.dev"),
                 "the app's Procfile.dev was modified"
  end

  def test_an_existing_procfile_survives_a_second_run
    original = "web: bin/rails server\nvite: bin/vite dev\n"
    File.write(File.join(@root, "Procfile.dev"), original)

    run_generator
    run_generator

    assert_equal original, read("Procfile.dev")
  end

  def test_the_generated_procfile_needs_no_foreman
    # The default Procfile has only a web line, so the app it produces boots
    # without foreman at all -- which is why the session skips the preflight.
    run_generator

    procfile = Copse::Procfile.parse(read("Procfile.dev"))

    refute_nil procfile.web
    assert_empty procfile.secondaries
  end

  def test_the_generated_bin_dev_is_valid_ruby
    run_generator

    _out, err, status = Open3.capture3(RbConfig.ruby, "-c", File.join(@root, "bin/dev"))

    assert_predicate status, :success?, err
  end
end
