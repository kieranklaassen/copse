# frozen_string_literal: true

require "test_helper"

# The optional naming mode: `<branch>.<project>.<machine>.local` published over
# multicast DNS, instead of `<branch>.<project>.localhost` published to nobody.
class ZeroconfTest < Minitest::Test
  # --- Opting in ------------------------------------------------------------

  def test_off_by_default
    refute Copse::Zeroconf.requested?(nil, env: {})
  end

  def test_the_environment_opts_in
    Copse::Zeroconf::TRUTHY.each do |value|
      assert Copse::Zeroconf.requested?(nil, env: { "COPSE_ZEROCONF" => value }),
             "#{value.inspect} should opt in"
      assert Copse::Zeroconf.requested?(nil, env: { "COPSE_ZEROCONF" => value.upcase }),
             "#{value.upcase.inspect} should opt in"
    end
  end

  # The variable is meant for a shell profile, where turning something off by
  # setting it to 0 is the reflex. Treating any value as truthy would make that
  # spelling do the opposite of what it says.
  def test_the_environment_can_say_no
    ["", "0", "false", "no", "off", " "].each do |value|
      refute Copse::Zeroconf.requested?(nil, env: { "COPSE_ZEROCONF" => value }),
             "#{value.inspect} should not opt in"
    end
  end

  def test_an_explicit_argument_beats_the_environment_in_both_directions
    refute Copse::Zeroconf.requested?(false, env: { "COPSE_ZEROCONF" => "1" })
    assert Copse::Zeroconf.requested?(true, env: {})
  end

  # --- The apex -------------------------------------------------------------

  def test_the_domain_is_the_machines_own_name_under_local
    assert_equal "thicc.local", Copse::Zeroconf.domain("thicc")
  end

  # Socket.gethostname already answers `thicc.local` on a Mac; appending the TLD
  # to that would publish thicc.local.local.
  def test_a_machine_name_that_already_ends_in_local_does_not_get_it_twice
    assert_equal "thicc.local", Copse::Zeroconf.domain("thicc.local")
  end

  def test_the_machine_name_is_reduced_to_one_label
    assert_equal "julik-s-macbook-pro.local", Copse::Zeroconf.domain("Julik's MacBook Pro.lan")
  end

  def test_an_unusable_machine_name_falls_back_rather_than_producing_a_bare_local
    assert_equal "workstation.local", Copse::Zeroconf.domain("!!!")
  end

  def test_the_real_machine_name_is_a_usable_domain
    assert_match(/\A[a-z0-9][a-z0-9-]*\.local\z/, Copse::Zeroconf.domain)
  end

  # --- Extra subdomains -----------------------------------------------------

  def test_subdomains_come_from_the_environment_as_a_list
    assert_equal %w[jane peter tom],
                 Copse::Zeroconf.subdomains(nil, env: { "COPSE_SUBDOMAINS" => "jane, peter,tom" })
  end

  # They arrive from an environment variable and end up in a DNS record, so they
  # go through the same whitelist a branch name does.
  def test_subdomains_are_slugged_and_deduplicated
    assert_equal %w[jane-co tom],
                 Copse::Zeroconf.subdomains(nil, env: { "COPSE_SUBDOMAINS" => "Jane&Co, tom, TOM, $( )" })
  end

  def test_no_subdomains_is_an_empty_list_not_a_nil
    assert_empty Copse::Zeroconf.subdomains(nil, env: {})
  end

  def test_hostnames_are_the_apps_own_plus_one_per_subdomain
    assert_equal ["cora.thicc.local", "jane.cora.thicc.local", "peter.cora.thicc.local"],
                 Copse::Zeroconf.hostnames("cora.thicc.local", %w[jane peter])
  end

  # --- Service instance names -----------------------------------------------

  # The gem raises on a dotted instance name, and every hostname Copse derives has
  # dots in it. This is the display name in `dns-sd -B _http._tcp`; the hostname
  # keeps its dots.
  def test_the_instance_name_flattens_the_hostname
    assert_equal "fix-billing-cora-thicc-local",
                 Copse::Zeroconf::Advertiser.instance_name("fix-billing.cora.thicc.local")
  end

  def test_the_instance_name_fits_one_dns_label
    name = Copse::Zeroconf::Advertiser.instance_name(["a" * 63, "b" * 63, "c" * 63].join("."))

    assert_equal Copse::Worktree::LABEL_LIMIT, name.length
  end

  # A dotted instance name is what the gem rejects, so prove the flattening is
  # what keeps a real Service constructible.
  def test_a_derived_hostname_is_advertisable_as_it_stands
    require "zeroconf"

    hostname = "fix-billing.cora.thicc.local"
    service = ZeroConf::Service.new(Copse::Zeroconf::SERVICE, 5368, hostname,
                                    instance_name: Copse::Zeroconf::Advertiser.instance_name(hostname),
                                    service_interfaces: [])

    assert_equal "fix-billing.cora.thicc.local.", service.qualified_host
    assert_equal "fix-billing-cora-thicc-local.#{Copse::Zeroconf::SERVICE}", service.service_name
  end

  # --- Worktree naming ------------------------------------------------------

  def test_a_worktree_publishes_under_the_domain_it_is_given
    with_git_repo(name: "cora") do |root|
      worktree = Copse::Worktree.new(root, domain: "thicc.local")

      assert_equal "cora.thicc.local", worktree.host
      assert_equal "http://cora.thicc.local:#{worktree.port}", worktree.url
    end
  end

  def test_a_linked_worktree_publishes_under_the_domain_too
    with_git_repo(name: "cora") do |root|
      with_linked_worktree(root, "fix-billing") do |path|
        assert_equal "fix-billing.cora.thicc.local",
                     Copse::Worktree.new(path, domain: "thicc.local").host
      end
    end
  end

  # The load-bearing one. Turning zeroconf naming on is about names; it must not
  # move a port, or teammates on .localhost and this machine would disagree, and
  # every bookmark and callback URL on this machine would break.
  def test_the_naming_mode_does_not_move_the_port
    with_git_repo(name: "cora") do |root|
      localhost = Copse::Worktree.new(root)
      zeroconf = Copse::Worktree.new(root, domain: "thicc.local")

      assert_equal "cora.localhost", zeroconf.canonical_host
      assert_equal localhost.port, zeroconf.port
      assert_equal localhost.companion_port, zeroconf.companion_port
      assert_equal Copse.port_for("cora.localhost"), zeroconf.port
    end
  end

  def test_the_database_suffix_is_unaffected_by_the_naming_mode
    with_git_repo(name: "cora") do |root|
      with_linked_worktree(root, "fix-billing") do |path|
        assert_equal "fix_billing", Copse::Worktree.new(path, domain: "thicc.local").database_suffix
      end
    end
  end

  # --- Copse.derive ---------------------------------------------------------

  def test_derive_returns_no_advertiser_when_zeroconf_was_not_asked_for
    with_git_repo(name: "cora") do |root|
      worktree, advertiser = Copse.derive(root: root, env: {})

      assert_equal "cora.localhost", worktree.host
      assert_nil advertiser
    end
  end

  def test_derive_builds_an_advertiser_for_the_hostname_and_its_subdomains
    with_git_repo(name: "cora") do |root|
      worktree, advertiser = Copse.derive(root: root, zeroconf: true, subdomains: %w[jane],
                                          env: {})

      assert_equal Copse::Zeroconf.domain, worktree.domain
      assert_equal [worktree.host, "jane.#{worktree.host}"], advertiser.hostnames
      assert_equal worktree.port, advertiser.port
    end
  end

  def test_derive_reads_the_environment_for_both_the_mode_and_the_subdomains
    with_git_repo(name: "cora") do |root|
      env = { "COPSE_ZEROCONF" => "1", "COPSE_SUBDOMAINS" => "jane,peter" }
      worktree, advertiser = Copse.derive(root: root, env: env)

      assert_equal Copse::Zeroconf.domain, worktree.domain
      assert_equal 3, advertiser.hostnames.size
    end
  end

  # A committed bin/dev can ask for a mode a given machine cannot provide, which
  # is the same shape as a teammate without overmind: boot anyway, and say why.
  #
  # Run in a child with rubygems disabled, because that is the only way to make
  # the gem genuinely absent in a suite whose Gemfile has it -- and a stub of
  # `available?` would prove the fallback without proving the require it hinges on.
  def test_a_missing_zeroconf_gem_falls_back_to_localhost_with_one_line
    with_git_repo(name: "cora") do |root|
      script = <<~RUBY
        $LOAD_PATH.unshift(#{File.expand_path("../lib", __dir__).inspect})
        require "copse"
        raise "the gem is still reachable" if Copse::Zeroconf.available?

        worktree, advertiser = Copse.derive(root: #{root.inspect}, zeroconf: true, env: {})
        raise "advertising without the gem" unless advertiser.nil?
        raise "wrong host \#{worktree.host}" unless worktree.host == "cora.localhost"
      RUBY
      # RUBYOPT and RUBYLIB carry this suite's own bundler setup, which would put
      # the gem back on the load path that --disable-gems just took away.
      out, err, status = Open3.capture3({ "RUBYOPT" => nil, "RUBYLIB" => nil },
                                        RbConfig.ruby, "--disable-gems", "-e", script)

      assert_predicate status, :success?, "#{err}#{out}"
      assert_match(/zeroconf/, out)
      assert_match(/\.localhost instead/, out)
      assert_equal 1, out.lines.size, "one clear line, never a backtrace"
      assert_empty err
    end
  end

  # --- The advertiser, against the real implementation ----------------------

  def test_it_advertises_and_withdraws
    advertiser = live_advertiser(%w[copse-test copse-test-sub])
    skip "no multicast-capable interface here" unless advertiser.start

    assert_predicate advertiser, :advertising?

    advertiser.stop

    refute_predicate advertiser, :advertising?
  end

  # The Overmind path: Copse `exec`s, so the advertiser has to survive into a
  # process Copse no longer exists to signal. It watches the pid it was forked
  # from -- which `exec` preserves -- and withdraws the names when that pid is
  # gone. Proven with SIGKILL, so nothing can be attributed to the parent politely
  # signalling anyone on its way out.
  def test_a_forked_advertiser_outlives_its_parent_and_then_stops_by_itself
    require "zeroconf"
    skip "no multicast-capable interface here" if ZeroConf.service_interfaces.empty?

    Dir.mktmpdir("copse-fork") do |dir|
      pidfile = File.join(dir, "advertiser.pid")
      script = <<~RUBY
        $LOAD_PATH.unshift(#{File.expand_path("../lib", __dir__).inspect})
        require "copse"
        advertiser = Copse::Zeroconf::Advertiser.new(
          ["copse-fork-\#{Process.pid}.\#{Copse::Zeroconf.domain}"], port: 5368,
          out: File.open(File::NULL, "w")
        )
        File.write(#{pidfile.inspect}, advertiser.fork_watching_parent)
        sleep 60
      RUBY
      parent = Process.spawn(RbConfig.ruby, "-e", script)
      advertiser = Integer(wait_for_file(pidfile))

      begin
        assert alive?(advertiser), "the forked advertiser did not start"

        Process.kill("KILL", parent)
        Process.waitpid(parent)

        assert wait_until { !alive?(advertiser) },
               "the advertiser outlived the process it was forked from"
      ensure
        Process.kill("KILL", advertiser) if alive?(advertiser)
      end
    end
  end

  def test_stopping_an_advertiser_that_never_started_is_harmless
    advertiser = live_advertiser(%w[copse-test])

    advertiser.stop

    refute_predicate advertiser, :advertising?
  end

  private

  # A name nothing else on the network is announcing: the pid keeps two runs of
  # this suite on one network from colliding, which mDNS otherwise resolves by
  # whoever announced last.
  def live_advertiser(labels)
    hostnames = labels.map { |label| "#{label}-#{Process.pid}.#{Copse::Zeroconf.domain}" }
    Copse::Zeroconf::Advertiser.new(hostnames, port: 5368, out: StringIO.new)
  end

  def wait_for_file(path, timeout: 10)
    wait_until(timeout: timeout) { File.exist?(path) && !File.read(path).strip.empty? }
    File.read(path).strip
  end

  # Generous, and only paid on failure: the fork polls its parent once a second.
  def wait_until(timeout: 10)
    deadline = Time.now + timeout
    until Time.now >= deadline
      return true if yield

      sleep 0.05
    end
    false
  end
end
