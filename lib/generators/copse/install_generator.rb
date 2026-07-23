# frozen_string_literal: true

require "rails/generators/base"

require "copse"

module Copse
  module Generators
    # `bin/rails generate copse:install`
    #
    # Wires an app to Copse the way `tailwindcss:install` wires up Tailwind: the
    # app commits a `bin/dev` the whole team shares.
    class InstallGenerator < ::Rails::Generators::Base
      BIN_DEV = "bin/dev"
      PROCFILE = "Procfile.dev"
      MARKER = "Copse.start"
      OVERMIND_MARKER = "process_manager: :overmind"

      source_root File.expand_path("templates", __dir__)

      class_option :process_manager, type: :string, default: nil,
                                     desc: "Supervisor bin/dev uses: #{Copse::PROCESS_MANAGERS.join(' or ')}"

      def create_bin_dev
        # Resolved before anything is written: detection reads the very bin/dev
        # this method is about to overwrite.
        process_manager

        if exists?(BIN_DEV)
          existing = File.read(absolute(BIN_DEV))

          if existing.include?(MARKER)
            if existing.include?(OVERMIND_MARKER) == overmind?
              # Already wired to this supervisor. Running the generator twice is a
              # no-op.
              say_status :identical, BIN_DEV, :blue
              return
            end

            # Same wiring, other supervisor. Switching is the whole point of the
            # flag, and a Copse bin/dev holds nothing of the app's own to preserve,
            # so this one is rewritten without a backup.
            say_status :force, "#{BIN_DEV} (#{process_manager})", :yellow
          else
            # Teams keep real setup logic in bin/dev -- dependency checks, database
            # bootstrapping. Replacing it without a copy would destroy that in one
            # command with nothing to recover from, and prompting is not an option
            # in a scripted run.
            backup = "#{BIN_DEV}.before-copse"
            FileUtils.cp(absolute(BIN_DEV), absolute(backup))
            say_status :backup, backup, :yellow
          end
        end

        template "dev.tt", BIN_DEV, force: true
        chmod BIN_DEV, 0o755
      end

      def create_procfile_dev
        if exists?(PROCFILE)
          # R10: never overwritten, and never silently. Whatever the app already
          # runs -- a tailwindcss:watch line, a vite line -- is left exactly as is.
          say_status :skip, "#{PROCFILE} already exists, leaving it untouched", :yellow
          return
        end

        template "Procfile.dev.tt", PROCFILE
      end

      def report_process_manager
        return unless File.exist?(absolute(PROCFILE))

        if overmind?
          say ""
          say "bin/dev hands all of Procfile.dev to overmind; attach with `overmind connect web`."
          say "Keep `web` first in Procfile.dev: overmind gives each process base + index * 100."
          say "Without overmind installed, bin/dev falls back to the foreman session."
          return
        end

        return if Copse::Procfile.parse(File.read(absolute(PROCFILE))).secondaries.empty?

        say ""
        say "Copse runs the `web` process in the foreground and hands the rest to foreman."
        say "Add `gem \"foreman\"` to your Gemfile, or install it for the Ruby you use here."
      end

      private

      # foreman unless asked otherwise -- with one exception. An app whose bin/dev
      # already drives overmind gets the overmind variant by default, because the
      # alternative is what this generator used to do: force-overwrite a working
      # overmind setup with one that drops back to foreman.
      def process_manager
        @process_manager ||= begin
          requested = options[:process_manager]

          if requested.nil?
            existing_overmind? ? "overmind" : "foreman"
          else
            unless Copse::PROCESS_MANAGERS.include?(requested)
              raise Thor::Error, "--process-manager must be one of: #{Copse::PROCESS_MANAGERS.join(', ')}"
            end

            requested
          end
        end
      end

      def overmind? = process_manager == "overmind"

      def existing_overmind?
        exists?(BIN_DEV) && File.read(absolute(BIN_DEV)).match?(/\bovermind\b/)
      end

      # Interpolated into the bin/dev template. ARGV is forwarded only on the
      # overmind path, where it has somewhere to go (`bin/dev -l web`); the foreman
      # session takes no arguments.
      def copse_start_arguments
        overmind? ? "(#{OVERMIND_MARKER}, args: ARGV)" : ""
      end

      def exists?(relative) = File.exist?(absolute(relative))

      def absolute(relative) = File.join(destination_root, relative)
    end
  end
end
