# frozen_string_literal: true

require "test_helper"
require "json"

# Verifies the railtie against a really-booted Rails::Application.
#
# Each scenario runs in a forked child because only one Rails::Application can be
# initialized per process: after the first `initialize!`, defining a second
# application raises FrozenError, Rails.application stays memoized to the first
# one, and re-initializing raises "Application has been already initialized."
# Forking is what lets each guard start from a clean boot.
class RailtieTest < Minitest::Test
  def setup
    skip "fork is unavailable on this platform" unless Process.respond_to?(:fork)
    @dir = Dir.mktmpdir("copse-rails")
  end

  # Boots a minimal Rails app in a child process and returns what the railtie did.
  #
  # `preset` runs before initialize!, so a scenario can simulate an app that sets
  # its own URL options.
  # `database_yml` opts the child into Active Record, with that YAML as the app's
  # config/database.yml and @dir as the app root.
  def boot(env:, rails_env: "development", preset: nil, load_mailer: true, database_yml: nil)
    reader, writer = IO.pipe
    root = __dir__

    if database_yml
      root = @dir
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config", "database.yml"), database_yml)
    end

    pid = fork do
      reader.close
      $stdout.reopen(File.join(@dir, "boot.log"), "a")
      $stderr.reopen($stdout)

      env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      ENV["RAILS_ENV"] = rails_env

      require "rails"
      require "action_controller/railtie"
      require "action_mailer/railtie" if load_mailer
      require "active_record/railtie" if database_yml
      # copse itself was required without Rails present, so the railtie was
      # skipped. Load it explicitly now that Rails::Railtie exists.
      require "copse/railtie"

      # A stand-in adapter, so a full boot can be observed without a database gem
      # or a running server. Active Record resolves the adapter class while
      # establishing the connection -- an unregistered or absent one is fatal
      # there -- but never instantiates it, because connecting is lazy.
      if database_yml
        ActiveRecord::ConnectionAdapters.register(
          "copse_probe",
          "ActiveRecord::ConnectionAdapters::AbstractAdapter",
          "active_record/connection_adapters/abstract_adapter"
        )
      end

      app = Class.new(Rails::Application) do
        config.root = root
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
        config.secret_key_base = "copse-test-secret"
        config.hosts.clear
      end
      Object.const_set(:CopseProbeApp, app)

      instance_eval(&preset) if preset

      app.initialize!

      databases =
        if database_yml
          ActiveRecord::Base.configurations
                            .configs_for(env_name: rails_env, include_hidden: true)
                            .to_h { |config| [config.name, config.database] }
        else
          {}
        end

      mailer =
        if load_mailer
          ActionMailer::Base.default_url_options.to_h
        else
          { skipped: true }
        end

      # Flush before reading it back: the railtie's boot line is buffered.
      $stdout.flush
      log = File.join(@dir, "boot.log")

      writer.puts JSON.dump(
        routes: Rails.application.routes.default_url_options,
        mailer: mailer,
        databases: databases,
        # What the connection pool would actually connect to, which is the claim
        # that matters: Active Record establishes the connection before Copse
        # renames anything, so the rename has to reach the pool that already
        # exists.
        pool_database: database_yml ? ActiveRecord::Base.connection_pool.db_config.database : nil,
        stdout: File.exist?(log) ? File.read(log) : ""
      )
      writer.close
      exit!(0)
    rescue Exception => e # rubocop:disable Lint/RescueException
      writer.puts JSON.dump(error: "#{e.class}: #{e.message}")
      writer.close
      exit!(1)
    end

    writer.close
    payload = reader.read
    reader.close
    _, status = Process.waitpid2(pid)

    refute_empty payload, "the child produced no output (exit #{status.exitstatus})"
    JSON.parse(payload, symbolize_names: true)
  end

  COPSE_ENV = {
    "COPSE_URL" => "http://cora.localhost:5368",
    "COPSE_HOST" => "cora.localhost",
    "COPSE_PORT" => "5368",
    "PORT" => "5368"
  }.freeze

  def test_routes_and_mailer_use_the_copse_host_in_development
    result = boot(env: COPSE_ENV)

    assert_nil result[:error], result[:error]
    assert_equal "cora.localhost", result.dig(:routes, :host)
    assert_equal 5368, result.dig(:routes, :port)
    assert_equal "cora.localhost", result.dig(:mailer, :host)
    assert_equal 5368, result.dig(:mailer, :port)
  end

  def test_reports_the_copse_url_on_boot
    result = boot(env: COPSE_ENV)

    assert_includes result[:stdout].to_s, "http://cora.localhost:5368"
  end

  def test_a_plain_rails_server_is_untouched
    # No COPSE_URL: the app was not booted by Copse.
    result = boot(env: { "COPSE_URL" => nil, "COPSE_HOST" => nil, "COPSE_PORT" => nil, "PORT" => nil })

    assert_nil result[:error], result[:error]
    assert_nil result.dig(:routes, :host)
    assert_nil result.dig(:mailer, :host)
  end

  def test_a_non_development_environment_is_untouched
    result = boot(env: COPSE_ENV, rails_env: "production")

    assert_nil result[:error], result[:error]
    assert_nil result.dig(:routes, :host)
  end

  def test_an_app_that_set_its_own_route_host_is_not_overridden
    result = boot(env: COPSE_ENV, preset: proc do
      CopseProbeApp.routes.default_url_options[:host] = "app.example.com"
    end)

    assert_nil result[:error], result[:error]
    assert_equal "app.example.com", result.dig(:routes, :host)
  end

  def test_an_app_that_set_its_own_mailer_host_is_not_overridden
    # Set the way a real app sets it, in config -- which also makes the test
    # independent of whether Copse's on_load hook runs before or after Rails'
    # own action_mailer.set_configs initializer. The app's host must win either way.
    result = boot(env: COPSE_ENV, preset: proc do
      CopseProbeApp.config.action_mailer.default_url_options = { host: "mail.example.com" }
    end)

    assert_nil result[:error], result[:error]
    # Routes still get Copse (the app did not set a route host) ...
    assert_equal "cora.localhost", result.dig(:routes, :host)
    # ... but the mailer keeps what the app chose.
    assert_equal "mail.example.com", result.dig(:mailer, :host)
  end

  DATABASE_YML = <<~YAML
    development:
      primary:
        adapter: copse_probe
        database: cora_development
      queue:
        adapter: copse_probe
        database: cora_queue_development
    production:
      adapter: copse_probe
      database: cora_production
  YAML

  def test_a_linked_worktree_gets_its_own_development_databases
    skip "ActiveRecord::ConnectionAdapters.register needs Rails 7.2+" unless adapter_registry?

    result = boot(env: COPSE_ENV.merge("COPSE_DATABASE_SUFFIX" => "fix_billing"),
                  database_yml: DATABASE_YML)

    assert_nil result[:error], result[:error]
    assert_equal "cora_development_fix_billing", result.dig(:databases, :primary)
    assert_equal "cora_queue_development_fix_billing", result.dig(:databases, :queue)
    # The rename reached the pool Active Record had already established.
    assert_equal "cora_development_fix_billing", result[:pool_database]
    assert_includes result[:stdout].to_s, "cora_development_fix_billing"
  end

  def test_a_main_worktree_keeps_the_database_the_app_already_has
    skip "ActiveRecord::ConnectionAdapters.register needs Rails 7.2+" unless adapter_registry?

    # No suffix: this is the app's own checkout, and its database must not move.
    # The root here is a temp directory, so the fallback derivation finds no
    # linked worktree either.
    result = boot(env: COPSE_ENV.merge("COPSE_DATABASE_SUFFIX" => nil),
                  database_yml: DATABASE_YML)

    assert_nil result[:error], result[:error]
    assert_equal "cora_development", result.dig(:databases, :primary)
    refute_includes result[:stdout].to_s, "database cora"
  end

  def test_a_non_development_environment_keeps_its_database
    skip "ActiveRecord::ConnectionAdapters.register needs Rails 7.2+" unless adapter_registry?

    result = boot(env: COPSE_ENV.merge("COPSE_DATABASE_SUFFIX" => "fix_billing"),
                  rails_env: "production", database_yml: DATABASE_YML)

    assert_nil result[:error], result[:error]
    assert_equal "cora_production", result.dig(:databases, :primary)
  end

  def adapter_registry?
    require "active_record"

    ActiveRecord::ConnectionAdapters.respond_to?(:register)
  end

  def test_an_app_without_action_mailer_boots_without_a_no_method_error
    # The reason on_load is used instead of config.action_mailer, which would
    # raise NoMethodError here.
    result = boot(env: COPSE_ENV, load_mailer: false)

    assert_nil result[:error], result[:error]
    assert_equal "cora.localhost", result.dig(:routes, :host)
  end
end
