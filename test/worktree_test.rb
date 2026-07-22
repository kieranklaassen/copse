# frozen_string_literal: true

require "test_helper"
require "digest"

class WorktreeTest < Minitest::Test
  # --- Hostname derivation (R1, R2, R3, KTD4) -------------------------------

  def test_main_worktree_uses_its_directory_name
    with_git_repo(name: "cora") do |root|
      worktree = Copse::Worktree.new(root)

      assert_equal "cora.localhost", worktree.host
      refute_predicate worktree, :linked?
    end
  end

  def test_main_worktree_directory_name_is_dasherized
    with_git_repo(name: "My_Cool App") do |root|
      assert_equal "my-cool-app.localhost", Copse::Worktree.new(root).host
    end
  end

  def test_linked_worktree_uses_its_branch_and_the_main_projects_name
    with_git_repo(name: "cora") do |root|
      with_linked_worktree(root, "fix-billing") do |path|
        worktree = Copse::Worktree.new(path)

        assert_predicate worktree, :linked?
        assert_equal "fix-billing.cora.localhost", worktree.host
      end
    end
  end

  def test_linked_worktree_branch_wins_over_its_directory_name
    # The point of KTD4: a conventionally-named directory would otherwise produce
    # cora-fix-billing.cora.localhost, repeating the project.
    with_git_repo(name: "cora") do |root|
      with_linked_worktree(root, "fix-billing", dir: "cora-fix-billing") do |path|
        assert_equal "cora-fix-billing", File.basename(path)
        assert_equal "fix-billing.cora.localhost", Copse::Worktree.new(path).host
      end
    end
  end

  def test_linked_worktree_on_detached_head_falls_back_to_its_directory_name
    with_git_repo(name: "cora") do |root|
      with_linked_worktree(root, "temp-branch", dir: "spike") do |path|
        git(path, "checkout", "--detach")
        worktree = Copse::Worktree.new(path)

        assert_nil worktree.branch
        assert_equal "spike.cora.localhost", worktree.host
      end
    end
  end

  def test_branch_name_with_slashes_becomes_one_label
    with_git_repo(name: "cora") do |root|
      with_linked_worktree(root, "feat/billing-v2") do |path|
        assert_equal "feat-billing-v2.cora.localhost", Copse::Worktree.new(path).host
      end
    end
  end

  # --- Degradation without git ----------------------------------------------

  def test_a_directory_that_is_not_a_git_worktree_uses_its_own_name
    Dir.mktmpdir("copse-plain") do |dir|
      plain = File.join(File.realpath(dir), "standalone")
      FileUtils.mkdir_p(plain)
      worktree = Copse::Worktree.new(plain)

      assert_equal "standalone.localhost", worktree.host
      refute_predicate worktree, :linked?
    end
  end

  def test_git_missing_from_path_still_derives_a_host
    with_git_repo do |root|
      named = File.join(File.dirname(root), "cora")
      FileUtils.mv(root, named)

      original = ENV["PATH"]
      begin
        ENV["PATH"] = ""
        worktree = Copse::Worktree.new(named)

        # Errno::ENOENT from the spawn is not an error condition -- derivation
        # never required git in the first place.
        assert_equal "cora.localhost", worktree.host
      ensure
        ENV["PATH"] = original
      end
    end
  end

  # --- Slug whitelist (security: branch names are not trusted input) --------

  def test_slug_strips_every_shell_metacharacter
    {
      "feat;id" => "feat-id",
      "feat$(id)" => "feat-id",
      "a&&b" => "a-b",
      "a|b" => "a-b",
      "a'b" => "a-b",
      'a"b' => "a-b",
      "a`b`" => "a-b",
      "a>b" => "a-b",
      "feat/foo" => "feat-foo",
      "Feat_Bar" => "feat-bar",
      "--leading-and-trailing--" => "leading-and-trailing"
    }.each do |input, expected|
      assert_equal expected, Copse::Worktree.slug(input), "slug(#{input.inspect})"
    end
  end

  def test_every_slug_is_a_valid_dns_label
    label = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/
    ["feat;id", "feat$(id)", "a&&b", "Feat_Bar", "feat/foo", "x" * 200, "9lives"].each do |input|
      slug = Copse::Worktree.slug(input)

      assert_match label, slug, "slug(#{input.inspect}) is not a valid DNS label"
      assert_operator slug.length, :<=, 63
    end
  end

  def test_a_long_branch_name_is_truncated_without_a_trailing_hyphen
    slug = Copse::Worktree.slug("#{'a' * 62}-#{'b' * 20}")

    assert_equal 62, slug.length
    refute slug.end_with?("-"), "truncation left a trailing hyphen"
  end

  def test_slug_returns_nil_when_nothing_survives
    assert_nil Copse::Worktree.slug("---")
    assert_nil Copse::Worktree.slug('!@#$')
    assert_nil Copse::Worktree.slug("")
  end

  def test_names_differing_only_outside_the_whitelist_collapse_together
    # A real collision path outside the measured birthday model: two branches can
    # share a derived port because they share a slug. Documented, not prevented.
    assert_equal Copse::Worktree.slug("feat/billing"), Copse::Worktree.slug("feat-billing")
  end

  # --- Port derivation (R4, KTD3, KTD3a) ------------------------------------

  def test_a_hostname_derives_the_same_port_every_time
    10.times { assert_equal 5368, Copse.port_for("cora.localhost") }
  end

  def test_a_known_hostname_derives_a_pinned_port
    # Pinned so a refactor of the mapping cannot silently move every developer's
    # port. If this fails, derivation changed: that is a breaking change.
    assert_equal 5368, Copse.port_for("cora.localhost")
    assert_equal 4783, Copse.port_for("fix-billing.cora.localhost")
  end

  def test_the_available_port_set_is_pinned
    # Ports are an index into this ordered set, so adding or removing a single
    # reserved port shifts every index above it and moves most derived ports --
    # breaking the promise that teammates derive the same port (R4). Pinning the
    # whole set, not just one port, is what makes that change impossible to miss.
    digest = Digest::SHA256.hexdigest(Copse::AVAILABLE_PORTS.join(","))[0, 16]

    assert_equal "4aaca2284fb19561", digest,
                 "AVAILABLE_PORTS changed: every derived port moves. This needs a major version bump."
  end

  def test_derived_ports_never_land_on_a_reserved_port
    reserved = Copse::RESERVED_PORTS.to_set
    5_000.times do |i|
      port = Copse.port_for("app-#{i}.localhost")

      refute_includes reserved, port
      assert_includes Copse::PORT_RANGE, port
    end
  end

  def test_distinct_hostnames_mostly_derive_distinct_ports
    hosts = Array.new(50) { |i| "app#{i}.localhost" }
    ports = hosts.map { |h| Copse.port_for(h) }

    # Uncoordinated derivation cannot promise zero collisions; at 50 names the
    # expected rate is a few percent. Assert the shape, not perfection.
    assert_operator ports.uniq.size, :>=, 48
  end

  def test_collision_rate_stays_under_the_documented_headroom_ceiling
    rate = collision_rate(names: 10, ports_per_name: 1)

    # Analytic mean for 10 names over 6,975 ports is 0.64%. The ceiling is
    # headroom, not the expected value: asserting 0.7% against an unseeded sample
    # would go red about one run in six with no defect present.
    assert_operator rate, :<, 1.0, "ten-name collision rate regressed to #{rate}%"
    assert_operator rate, :>, 0.3, "collision rate implausibly low -- is the sample actually varying?"
  end

  def test_a_vite_worktree_draws_two_ports_so_its_collision_rate_is_higher
    one = collision_rate(names: 10, ports_per_name: 1)
    two = collision_rate(names: 10, ports_per_name: 2)

    # The documented bound is per port drawn, not per worktree: ten vite
    # worktrees is twenty draws, so ~2.7% rather than ~0.64%.
    assert_operator two, :>, one * 2
    assert_operator two, :<, 4.0
  end

  # --- Companion port (U2 contract, exercised here since derivation lives here)

  def test_companion_port_is_stable_and_never_equals_the_primary
    %w[cora.localhost fix-billing.cora.localhost app.localhost].each do |host|
      companion = Copse.companion_port_for(host)

      assert_equal companion, Copse.companion_port_for(host)
      refute_equal Copse.port_for(host), companion
      assert_includes Copse::AVAILABLE_PORTS, companion
    end
  end

  def test_companion_ports_differ_across_worktrees
    a = Copse.companion_port_for("main.cora.localhost")
    b = Copse.companion_port_for("fix-billing.cora.localhost")

    refute_equal a, b
  end

  def test_companion_port_is_never_a_reserved_service_port
    reserved = Copse::RESERVED_PORTS.to_set
    2_000.times { |i| refute_includes reserved, Copse.companion_port_for("app-#{i}.localhost") }
  end

  private

  ALPHABET = (("a".."z").to_a + ("0".."9").to_a).freeze

  # Two tests need the same 1-port measurement, and each run is a 20,000 x 10
  # Monte Carlo. Caching by argument tuple is safe because the result is a pure
  # function of those arguments -- it introduces no cross-test ordering dependence.
  COLLISION_RATES = {}

  # Deterministic Monte Carlo. The seed is the whole point: derivation is a pure
  # function, so the only randomness is the synthetic hostname corpus, and an
  # unseeded corpus makes the assertion flaky rather than meaningful.
  def collision_rate(names:, ports_per_name:, trials: 20_000, seed: 20_260_721)
    key = [names, ports_per_name, trials, seed]
    cached = COLLISION_RATES[key]
    return cached if cached

    rng = Random.new(seed)
    collisions = 0

    trials.times do
      seen = {}
      collided = false
      names.times do
        host = "#{Array.new(12) { ALPHABET.sample(random: rng) }.join}.localhost"
        ports = [Copse.port_for(host)]
        ports << Copse.companion_port_for(host) if ports_per_name == 2
        ports.each do |port|
          collided ||= seen.key?(port)
          seen[port] = true
        end
      end
      collisions += 1 if collided
    end

    COLLISION_RATES[key] = 100.0 * collisions / trials
  end
end
