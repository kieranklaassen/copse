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

  def run_generator
    Copse::Generators::InstallGenerator.start(["--quiet"], destination_root: @root)
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
