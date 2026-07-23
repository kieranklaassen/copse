# frozen_string_literal: true

require_relative "worktree"

module Copse
  # Decides whether Copse renames the development database, and to what.
  #
  # Same shape as UrlOptions and for the same reason: the decisions are
  # Rails-free so they can be tested without booting an application, and the
  # railtie is only the wiring.
  #
  # The suffix comes from the worktree rather than from the environment Copse
  # exports, so `bin/rails db:prepare` and `bin/rails console` in a linked
  # worktree reach the same database `bin/dev` does. A database that only existed
  # when Copse booted the app would be a database no rake task could create.
  module Database
    # A main worktree keeps its plain database name, so only a linked worktree is
    # renamed. That is what makes this safe to add to an existing app: the
    # database you already have is never the one that moves.
    #
    # PostgreSQL silently truncates identifiers past 63 bytes and MySQL rejects
    # them past 64, so the composed name is capped here rather than left to the
    # server. The cap trims the suffix, never the app's own database name --
    # which can make two very long branch names share a database, exactly as the
    # 63-character DNS label cap can make them share a hostname.
    NAME_LIMIT = 63

    # Adapters whose "database" is a path rather than a name on a shared server.
    # A linked worktree is a separate directory, so these are already separate
    # databases; renaming would only move the file inside the worktree.
    FILE_BACKED_ADAPTERS = %w[sqlite3 sqlite].freeze

    # Development only. The point of the rename is that several worktrees of one
    # app can run at once; production has one, and a test database is already
    # partitioned per worker by Rails itself.
    def self.apply?(rails_env:)
      rails_env.to_s == "development"
    end

    # The suffix for this checkout, or nil in a main worktree.
    #
    # Prefers COPSE_DATABASE_SUFFIX, which `bin/dev` exports, so a process Copse
    # started does not shell out to git again -- and so a single value is shared
    # by everything in that session.
    def self.suffix(env: ENV, root: Dir.pwd)
      exported = env["COPSE_DATABASE_SUFFIX"]
      return exported unless exported.to_s.empty?

      Worktree.new(root).database_suffix
    end

    # The renamed database, or nil when this configuration is left alone.
    def self.rename(database:, adapter:, suffix:)
      name = database.to_s
      return nil if suffix.to_s.empty? || name.empty?
      return nil if FILE_BACKED_ADAPTERS.include?(adapter.to_s) || name.include?("/")
      # Idempotent: the railtie can run again in the same process (a reload, a
      # second `db:prepare` in one rake invocation) and must not keep appending.
      return nil if name.end_with?("_#{suffix}")

      compose(name, suffix.to_s)
    end

    # Renames every development database in an
    # ActiveRecord::DatabaseConfigurations, in place.
    #
    # In place is the load-bearing part. Active Record's own
    # `active_record.initialize_database` initializer calls `establish_connection`
    # before this runs, so a *replacement* configuration object would be ignored
    # by the pool that already exists. Mutating the object the pool holds works
    # because the adapter is built from it lazily, at first checkout.
    #
    # Returns the names that changed, for reporting.
    def self.apply(configurations, suffix:, env_name: "development")
      configurations.configs_for(env_name: env_name, include_hidden: true).filter_map do |config|
        # `database_tasks: false` is how an app says Rails does not own this
        # database -- a legacy or shared server it only reads. Copse does not get
        # to rename something the app cannot create.
        #
        # The key is read directly rather than through `database_tasks?`, which is
        # also false for every replica. A replica points at the same database as
        # its primary, so leaving it behind would send reads to another worktree's
        # data.
        next unless config.configuration_hash.fetch(:database_tasks, true)

        renamed = rename(database: config.database, adapter: config.adapter, suffix: suffix)
        next if renamed.nil?

        config._database = renamed
        renamed
      end
    end

    # Composes the name, or nil when the cap leaves no room for a suffix at all
    # -- in which case the database is left alone rather than renamed to
    # something that cannot be told apart from another worktree's.
    def self.compose(database, suffix)
      room = NAME_LIMIT - database.bytesize - 1
      return nil if room < 1

      "#{database}_#{suffix[0, room]}"
    end
    private_class_method :compose
  end
end
