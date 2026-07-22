# frozen_string_literal: true

require "rails/railtie"

require_relative "url_options"

module Copse
  # Points generated URLs at the Copse hostname in development, and reports the
  # URL on boot.
  #
  # All the decision logic lives in Copse::UrlOptions, which knows nothing about
  # Rails; this class is only the wiring.
  class Railtie < ::Rails::Railtie
    initializer "copse.default_url_options" do |app|
      routes = app.routes

      if UrlOptions.apply?(rails_env: ::Rails.env, existing_host: routes.default_url_options[:host])
        options = UrlOptions.for
        routes.default_url_options.merge!(options)

        # Reached through on_load rather than `config.action_mailer`, which raises
        # NoMethodError in an app that does not load Action Mailer at all.
        ActiveSupport.on_load(:action_mailer) do
          # Checked again here: an app can set mailer URL options without setting
          # route ones, and Copse should not override either.
          if default_url_options.to_h[:host].to_s.empty?
            self.default_url_options = default_url_options.to_h.merge(options)
          end
        end

        # R14. Puma prints its own `Listening on http://127.0.0.1:<port>` line too;
        # that one reports the bound address, and binding to the hostname would
        # depend on the system resolver. Both lines are correct about different
        # things, which is why this one names Copse explicitly.
        $stdout.puts "=> Copse: #{UrlOptions.url} (Puma reports the bound address separately)"
      end
    end
  end
end
