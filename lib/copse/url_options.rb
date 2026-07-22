# frozen_string_literal: true

module Copse
  # Decides whether Copse should set `default_url_options`, and to what.
  #
  # Deliberately Rails-free so every guard can be tested without booting an
  # application -- which matters because only one Rails::Application can be
  # initialized per process.
  module UrlOptions
    # Copse only speaks up when all three are true:
    #   * this is development,
    #   * the app was actually booted by Copse (COPSE_URL is present), and
    #   * the app has not already set its own host.
    #
    # A plain `bin/rails server`, any other environment, and any app with explicit
    # URL options are all left alone.
    def self.apply?(env: ENV, rails_env:, existing_host: nil)
      return false unless rails_env.to_s == "development"
      return false if env["COPSE_URL"].to_s.empty?
      return false unless existing_host.to_s.empty?

      true
    end

    # The options to merge. Prefers COPSE_PORT over PORT: under foreman, PORT is
    # rewritten per child, while COPSE_PORT always carries the derived port.
    def self.for(env: ENV)
      options = { host: env["COPSE_HOST"] }
      port = env["COPSE_PORT"] || env["PORT"]
      options[:port] = Integer(port, exception: false) unless port.to_s.empty?
      options.compact
    end

    def self.url(env: ENV)
      env["COPSE_URL"]
    end
  end
end
