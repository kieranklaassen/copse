# frozen_string_literal: true

require "rails/railtie"

require_relative "url_options"
require_relative "database"

module Copse
  # Points generated URLs at the Copse hostname in development, gives a linked
  # worktree its own development database, and reports both on boot.
  #
  # All the decision logic lives in Copse::UrlOptions and Copse::Database, which
  # know nothing about Rails; this class is only the wiring.
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

    # A linked worktree gets its own development database, so two branches of one
    # app do not share one schema.
    #
    # Placed *after* `active_record.initialize_database` because that initializer
    # is what assigns `ActiveRecord::Base.configurations` -- before it there is
    # nothing to rename. It also calls `establish_connection`, which is why
    # Copse::Database mutates each configuration in place rather than replacing
    # it; see the note there.
    #
    # Unlike the URL options this does not require COPSE_URL. The database has to
    # be the same one whether you arrived by `bin/dev`, `bin/rails console`, or
    # `bin/rails db:prepare` -- a database only reachable from `bin/dev` is a
    # database no rake task could create.
    initializer "copse.database", after: "active_record.initialize_database" do
      next unless Database.apply?(rails_env: ::Rails.env)

      suffix = Database.suffix(root: ::Rails.root.to_s)
      next if suffix.to_s.empty?

      ActiveSupport.on_load(:active_record) do
        renamed = Database.apply(ActiveRecord::Base.configurations, suffix: suffix)

        # Only when Copse booted the app. Every other development command
        # (`bin/rails console`, every rake task) is renamed too, and printing there
        # would put a Copse line in front of unrelated output; the tasks that
        # matter name the database themselves.
        unless renamed.empty? || UrlOptions.url.to_s.empty?
          $stdout.puts "=> Copse: database #{renamed.join(', ')}"
        end
      end
    end
  end
end
