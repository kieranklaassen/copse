# frozen_string_literal: true

require "test_helper"
require "active_record"
require "active_record/database_configurations"

# The rename decisions, and the one Active Record method they are applied
# through. Nothing here opens a connection, so no adapter gem is needed -- which
# is also why the booted-application coverage in railtie_test.rb stops short of
# Active Record.
class DatabaseTest < Minitest::Test
  def test_applies_only_in_development
    assert Copse::Database.apply?(rails_env: "development")

    %w[production test staging].each do |rails_env|
      refute Copse::Database.apply?(rails_env: rails_env), "applied in #{rails_env}"
    end
  end

  def test_suffixes_the_database_with_the_worktree_slug
    assert_equal "cora_development_fix_billing",
                 rename("cora_development", suffix: "fix_billing")
  end

  def test_no_suffix_means_no_rename
    # A main worktree keeps the database the app already has.
    assert_nil rename("cora_development", suffix: nil)
    assert_nil rename("cora_development", suffix: "")
  end

  def test_repeating_the_rename_does_not_keep_appending
    assert_nil rename("cora_development_fix_billing", suffix: "fix_billing")
  end

  def test_file_backed_databases_are_left_alone
    # A linked worktree is its own directory, so storage/development.sqlite3 is
    # already a different database. Renaming would only move the file.
    assert_nil rename("storage/development.sqlite3", adapter: "sqlite3", suffix: "fix_billing")
    assert_nil rename("storage/development.sqlite3", adapter: "postgresql", suffix: "fix_billing")
    assert_nil rename("development.sqlite3", adapter: "sqlite3", suffix: "fix_billing")
  end

  def test_a_configuration_with_no_database_is_left_alone
    assert_nil rename(nil, suffix: "fix_billing")
    assert_nil rename("", suffix: "fix_billing")
  end

  def test_the_composed_name_is_capped_at_the_identifier_limit
    # PostgreSQL truncates past 63 bytes with only a notice, MySQL rejects past
    # 64. The suffix is what gets trimmed; the app's own name stays intact.
    renamed = rename("cora_development", suffix: "a" * 80)

    assert_equal Copse::Database::NAME_LIMIT, renamed.bytesize
    assert renamed.start_with?("cora_development_")
  end

  def test_a_database_name_with_no_room_for_a_suffix_is_left_alone
    # Renaming to something indistinguishable from another worktree's would be
    # worse than not renaming at all.
    assert_nil rename("d" * Copse::Database::NAME_LIMIT, suffix: "fix_billing")
  end

  def test_the_suffix_comes_from_the_exported_environment_when_present
    # `bin/dev` exports it, so a process Copse started does not shell out to git.
    assert_equal "fix_billing",
                 Copse::Database.suffix(env: { "COPSE_DATABASE_SUFFIX" => "fix_billing" },
                                        root: Dir.pwd)
  end

  def test_the_suffix_falls_back_to_the_worktree
    # Which is what makes `bin/rails db:prepare` reach the same database as
    # `bin/dev`, having never been started by Copse.
    with_git_repo(name: "cora") do |root|
      assert_nil Copse::Database.suffix(env: {}, root: root)

      with_linked_worktree(root, "feat/fix-billing") do |linked|
        assert_equal "fix_billing", Copse::Database.suffix(env: {}, root: linked)[-11..]
        assert_equal "feat_fix_billing", Copse::Database.suffix(env: {}, root: linked)
      end
    end
  end

  def test_a_main_worktree_has_no_suffix
    with_git_repo(name: "cora") do |root|
      assert_nil Copse::Worktree.new(root).database_suffix
    end
  end

  def test_apply_renames_every_development_database_in_place
    configurations = configurations_for(
      "development" => {
        "primary" => { "adapter" => "postgresql", "database" => "cora_development" },
        "queue" => { "adapter" => "postgresql", "database" => "cora_queue_development" }
      },
      "production" => { "adapter" => "postgresql", "database" => "cora_production" }
    )

    renamed = Copse::Database.apply(configurations, suffix: "fix_billing")

    assert_equal %w[cora_development_fix_billing cora_queue_development_fix_billing].sort,
                 renamed.sort
    assert_equal "cora_development_fix_billing", database(configurations, "primary")
    assert_equal "cora_queue_development_fix_billing", database(configurations, "queue")
    # Every other environment is untouched.
    assert_equal "cora_production",
                 configurations.configs_for(env_name: "production", name: "primary").database
  end

  def test_apply_leaves_a_database_rails_does_not_own_alone
    # `database_tasks: false` is how an app says this is someone else's database.
    # Copse cannot rename what no rake task will create.
    configurations = configurations_for(
      "development" => {
        "primary" => { "adapter" => "postgresql", "database" => "cora_development" },
        "analytics" => { "adapter" => "postgresql", "database" => "warehouse",
                         "database_tasks" => false }
      }
    )

    Copse::Database.apply(configurations, suffix: "fix_billing")

    assert_equal "cora_development_fix_billing", database(configurations, "primary")
    assert_equal "warehouse", database(configurations, "analytics")
  end

  def test_apply_renames_replicas_too
    # A replica points at the same database, and configs_for hides it by default.
    configurations = configurations_for(
      "development" => {
        "primary" => { "adapter" => "postgresql", "database" => "cora_development" },
        "primary_replica" => { "adapter" => "postgresql", "database" => "cora_development",
                               "replica" => true }
      }
    )

    Copse::Database.apply(configurations, suffix: "fix_billing")

    assert_equal "cora_development_fix_billing", database(configurations, "primary_replica")
  end

  private

  def rename(database, suffix:, adapter: "postgresql")
    Copse::Database.rename(database: database, adapter: adapter, suffix: suffix)
  end

  def configurations_for(hash)
    ActiveRecord::DatabaseConfigurations.new(hash)
  end

  def database(configurations, name)
    configurations.configs_for(env_name: "development", name: name, include_hidden: true).database
  end
end
