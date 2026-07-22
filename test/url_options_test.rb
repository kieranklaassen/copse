# frozen_string_literal: true

require "test_helper"

# The three guards, tested without Rails. This is where the exhaustive coverage
# lives, because only one Rails::Application can be initialized per process --
# see railtie_test.rb for the booted-application checks.
class UrlOptionsTest < Minitest::Test
  COPSE_ENV = {
    "COPSE_URL" => "http://cora.localhost:5368",
    "COPSE_HOST" => "cora.localhost",
    "COPSE_PORT" => "5368",
    "PORT" => "5368"
  }.freeze

  def test_applies_in_development_when_booted_by_copse_and_no_host_is_set
    assert Copse::UrlOptions.apply?(env: COPSE_ENV, rails_env: "development")
  end

  def test_does_not_apply_outside_development
    %w[production test staging].each do |rails_env|
      refute Copse::UrlOptions.apply?(env: COPSE_ENV, rails_env: rails_env),
             "applied in #{rails_env}"
    end
  end

  def test_does_not_apply_without_copse_url
    # A plain `bin/rails server` must be untouched.
    refute Copse::UrlOptions.apply?(env: {}, rails_env: "development")
    refute Copse::UrlOptions.apply?(env: { "COPSE_URL" => "" }, rails_env: "development")
  end

  def test_does_not_apply_when_the_app_already_set_a_host
    refute Copse::UrlOptions.apply?(env: COPSE_ENV, rails_env: "development",
                                    existing_host: "example.com")
  end

  def test_an_empty_existing_host_does_not_count_as_set
    assert Copse::UrlOptions.apply?(env: COPSE_ENV, rails_env: "development", existing_host: "")
    assert Copse::UrlOptions.apply?(env: COPSE_ENV, rails_env: "development", existing_host: nil)
  end

  def test_builds_host_and_integer_port
    assert_equal({ host: "cora.localhost", port: 5368 },
                 Copse::UrlOptions.for(env: COPSE_ENV))
  end

  def test_prefers_copse_port_over_port
    # Under foreman, PORT is rewritten per child (base_port + index * 100), so
    # PORT is not trustworthy in a secondary process. COPSE_PORT always carries
    # the derived port.
    env = COPSE_ENV.merge("PORT" => "5468")

    assert_equal 5368, Copse::UrlOptions.for(env: env)[:port]
  end

  def test_falls_back_to_port_when_copse_port_is_absent
    env = COPSE_ENV.reject { |key, _| key == "COPSE_PORT" }

    assert_equal 5368, Copse::UrlOptions.for(env: env)[:port]
  end

  def test_omits_a_port_that_is_not_a_number
    env = COPSE_ENV.merge("COPSE_PORT" => "not-a-port", "PORT" => "also-not")

    refute_includes Copse::UrlOptions.for(env: env), :port
  end

  def test_omits_keys_with_no_value_rather_than_setting_nil
    assert_empty Copse::UrlOptions.for(env: {})
  end
end
