# frozen_string_literal: true

require "test_helper"

class ProcfileTest < Minitest::Test
  # --- Parsing ---------------------------------------------------------------

  def test_splits_the_web_entry_from_the_rest
    procfile = Copse::Procfile.parse(<<~PROC)
      web: bin/rails server
      css: bin/rails tailwindcss:watch
      js: yarn build --watch
    PROC

    assert_equal "bin/rails server", procfile.web.command
    assert_equal %w[css js], procfile.secondaries.map(&:name)
  end

  def test_finds_the_web_entry_when_it_is_env_prefixed
    # jsbundling-rails and cssbundling-rails both ship this shape.
    procfile = Copse::Procfile.parse("web: env RUBY_DEBUG_OPEN=true bin/rails server\n")

    refute_nil procfile.web
    assert_equal "env RUBY_DEBUG_OPEN=true bin/rails server", procfile.web.command
  end

  def test_ignores_blank_lines_and_comments
    procfile = Copse::Procfile.parse(<<~PROC)

      # the web process
      web: bin/rails server

      # assets
      css: bin/rails tailwindcss:watch
    PROC

    assert_equal %w[web css], procfile.entries.map(&:name)
  end

  def test_ignores_a_name_with_no_command
    procfile = Copse::Procfile.parse("web:\ncss: bin/watch\n")

    assert_nil procfile.web
    assert_equal %w[css], procfile.entries.map(&:name)
  end

  def test_a_procfile_with_only_a_web_line_has_no_secondaries
    procfile = Copse::Procfile.parse("web: bin/rails server\n")

    assert_empty procfile.secondaries
  end

  def test_a_procfile_with_no_web_line_returns_nil_for_web
    procfile = Copse::Procfile.parse("worker: bin/jobs\ncss: bin/watch\n")

    assert_nil procfile.web
    assert_equal %w[worker css], procfile.entries.map(&:name)
  end

  # --- Port flag stripping (Q4: strip rather than refuse) --------------------

  def test_strips_every_spelling_of_an_explicit_port_flag
    {
      "bin/rails s --port 3000" => "bin/rails s",
      "bin/rails s --port=3000" => "bin/rails s",
      "bin/rails s -p 3000" => "bin/rails s",
      "bin/rails server -p 3000 -b 0.0.0.0" => "bin/rails server -b 0.0.0.0"
    }.each do |input, expected|
      assert_equal expected, Copse::Procfile.strip_port_flag(input)
    end
  end

  def test_leaves_a_command_without_a_port_flag_alone
    assert_equal "bin/rails server", Copse::Procfile.strip_port_flag("bin/rails server")
  end

  def test_does_not_mistake_other_flags_for_a_port
    assert_equal "bin/rails s -b 0.0.0.0", Copse::Procfile.strip_port_flag("bin/rails s -b 0.0.0.0")
    assert_equal "bin/vite dev --pretty", Copse::Procfile.strip_port_flag("bin/vite dev --pretty")
  end

  # --- exec transform (KTD8) ------------------------------------------------

  def test_a_plain_command_is_left_alone
    command, warning = Copse::Procfile.signal_transparent("bin/rails tailwindcss:watch")

    assert_equal "bin/rails tailwindcss:watch", command
    assert_nil warning
  end

  def test_an_env_prefixed_command_is_left_alone
    command, warning = Copse::Procfile.signal_transparent("env FOO=1 bin/watch")

    assert_equal "env FOO=1 bin/watch", command
    assert_nil warning
  end

  def test_exec_goes_before_the_final_command_of_a_chain
    # Not `exec echo hi; sleep 300` -- that replaces the shell with echo and the
    # sleep never runs. Not `exec sh -c "..."` -- the recorded pid is still sh.
    command, warning = Copse::Procfile.signal_transparent("echo hi; sleep 300")

    assert_equal "echo hi; exec sleep 300", command
    assert_nil warning
  end

  def test_exec_placement_for_and_and_or_chains
    assert_equal ["true && exec bin/watch", nil],
                 Copse::Procfile.signal_transparent("true && bin/watch")
    assert_equal ["bin/try || exec bin/fallback", nil],
                 Copse::Procfile.signal_transparent("bin/try || bin/fallback")
  end

  def test_exec_goes_before_the_last_command_of_a_longer_chain
    command, = Copse::Procfile.signal_transparent("a; b; c")

    assert_equal "a; b; exec c", command
  end

  def test_a_single_command_needing_a_shell_gets_an_exec_prefix
    # A redirect or a glob still routes through /bin/sh, but it is one command,
    # so prefixing exec replaces the shell with it.
    assert_equal ["exec bin/watch > log/watch.log", nil],
                 Copse::Procfile.signal_transparent("bin/watch > log/watch.log")
  end

  def test_a_quoted_semicolon_is_not_a_chain
    # One command with a quoted argument, not two commands.
    command, warning = Copse::Procfile.signal_transparent("bin/rails runner 'A.watch; B.watch'")

    assert_equal "exec bin/rails runner 'A.watch; B.watch'", command
    assert_nil warning
  end

  def test_a_quoted_pipe_is_not_a_pipeline
    command, warning = Copse::Procfile.signal_transparent(%(bin/run --filter "a|b"))

    assert_nil warning, "a quoted pipe was misread as a pipeline"
    assert_equal %(exec bin/run --filter "a|b"), command
  end

  # --- Regressions from code review ----------------------------------------

  def test_an_ampersand_inside_a_redirect_is_not_a_background_operator
    # `2>&1` is a redirect, not a control operator. Reading it as a background `&`
    # made an ordinary watcher line skip the transform entirely and keep a shell in
    # front of the process -- a real orphan on any /bin/sh that forks.
    {
      "yarn build --watch 2>&1" => "exec yarn build --watch 2>&1",
      "bin/jobs >> log/jobs.log 2>&1" => "exec bin/jobs >> log/jobs.log 2>&1",
      "bin/x >&2" => "exec bin/x >&2",
      "bin/x &> out.log" => "exec bin/x &> out.log"
    }.each do |input, expected|
      command, warning = Copse::Procfile.signal_transparent(input)

      assert_nil warning, "#{input.inspect} was misread as a background command"
      assert_equal expected, command
    end

    assert_empty Copse::Procfile.top_level_operators("a 2>&1")
  end

  def test_a_real_background_operator_is_still_detected
    _command, warning = Copse::Procfile.signal_transparent("bin/jobs & bin/tail")

    refute_nil warning, "a genuine background & must still be warned about"
    assert_includes warning, "background"
  end

  def test_a_trailing_separator_does_not_splice_a_bare_exec
    # Without normalisation this produced "echo a; bin/b;exec " -- a no-op exec
    # with no command, silently leaving the shell in front of the real process.
    ["echo a; bin/b;", "echo a; bin/b ;", "echo a; bin/b;  "].each do |input|
      command, warning = Copse::Procfile.signal_transparent(input)

      assert_equal "echo a; exec bin/b", command
      assert_nil warning
      refute_match(/exec\s*\z/, command, "spliced a bare exec with no command")
    end
  end

  def test_an_assignment_prefixed_segment_goes_through_env
    # `exec FOO=1 cmd` makes the shell look for a program literally named "FOO=1"
    # and fail with exit 127, so the assignment form has to route through env(1).
    command, = Copse::Procfile.signal_transparent(%(NODE_OPTIONS="--max-old-space-size=4096" yarn build))

    assert_equal %(exec env NODE_OPTIONS="--max-old-space-size=4096" yarn build), command

    chained, = Copse::Procfile.signal_transparent("echo hi; FOO=1 bin/watch")

    assert_equal "echo hi; exec env FOO=1 bin/watch", chained
  end

  def test_the_rewritten_command_is_accepted_by_the_shell
    # The failure this guards is a rewrite /bin/sh refuses: the old assignment form
    # exited 127 while the suite stayed green, because nothing ever ran the output.
    ["yarn --version 2>&1", "echo a; echo b", %(FOO=1 /bin/echo ok), %(bin/x 2>&1)].each do |input|
      command, warning = Copse::Procfile.signal_transparent(input)
      next if warning

      # Substitute a command that certainly exists, keeping the transform's shape.
      probe = command.sub("yarn --version", "/bin/echo ok").sub("bin/x", "/bin/echo ok")
      out, err, status = Open3.capture3("/bin/sh", "-c", probe)

      assert_predicate status, :success?,
                       "the shell refused #{probe.inspect}: #{err}#{out}"
    end
  end

  def test_a_pipeline_is_warned_about_and_left_unmodified
    # No exec placement collapses a pipeline into one pid: the recorded process is
    # the shell awaiting the whole pipeline.
    command, warning = Copse::Procfile.signal_transparent("bin/watch | tee log/out.log")

    assert_equal "bin/watch | tee log/out.log", command
    refute_nil warning
    assert_includes warning, "pipeline"
  end

  def test_a_background_command_is_warned_about_and_left_unmodified
    command, warning = Copse::Procfile.signal_transparent("bin/jobs & bin/tail")

    assert_equal "bin/jobs & bin/tail", command
    refute_nil warning
    assert_includes warning, "background"
  end

  def test_operator_scan_ignores_quoted_and_escaped_operators
    assert_empty Copse::Procfile.top_level_operators("a 'b;c' d")
    assert_empty Copse::Procfile.top_level_operators(%(a "b|c" d))
    assert_empty Copse::Procfile.top_level_operators("a \\; b")

    assert_equal [";"], Copse::Procfile.top_level_operators("a; b").map { |op| op[:token] }
    assert_equal ["&&"], Copse::Procfile.top_level_operators("a && b").map { |op| op[:token] }
    assert_equal ["|"], Copse::Procfile.top_level_operators("a | b").map { |op| op[:token] }
    assert_equal ["&"], Copse::Procfile.top_level_operators("a & b").map { |op| op[:token] }
  end
end
