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
  def boot(env:, rails_env: "development", preset: nil, load_mailer: true)
    reader, writer = IO.pipe

    pid = fork do
      reader.close
      $stdout.reopen(File.join(@dir, "boot.log"), "a")
      $stderr.reopen($stdout)

      env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      ENV["RAILS_ENV"] = rails_env

      require "rails"
      require "action_controller/railtie"
      require "action_mailer/railtie" if load_mailer
      # copse itself was required without Rails present, so the railtie was
      # skipped. Load it explicitly now that Rails::Railtie exists.
      require "copse/railtie"

      app = Class.new(Rails::Application) do
        config.root = __dir__
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
        config.secret_key_base = "copse-test-secret"
        config.hosts.clear
      end
      Object.const_set(:CopseProbeApp, app)

      instance_eval(&preset) if preset

      app.initialize!

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

  def test_an_app_without_action_mailer_boots_without_a_no_method_error
    # The reason on_load is used instead of config.action_mailer, which would
    # raise NoMethodError here.
    result = boot(env: COPSE_ENV, load_mailer: false)

    assert_nil result[:error], result[:error]
    assert_equal "cora.localhost", result.dig(:routes, :host)
  end
end
