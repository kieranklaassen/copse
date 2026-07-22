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

      source_root File.expand_path("templates", __dir__)

      def create_bin_dev
        if exists?(BIN_DEV)
          if File.read(absolute(BIN_DEV)).include?(MARKER)
            # Already wired. Running the generator twice is a no-op.
            say_status :identical, BIN_DEV, :blue
            return
          end

          # Teams keep real setup logic in bin/dev -- dependency checks, database
          # bootstrapping. Replacing it without a copy would destroy that in one
          # command with nothing to recover from, and prompting is not an option in
          # a scripted run.
          backup = "#{BIN_DEV}.before-copse"
          FileUtils.cp(absolute(BIN_DEV), absolute(backup))
          say_status :backup, backup, :yellow
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

      def report_foreman_requirement
        return unless File.exist?(absolute(PROCFILE))
        return if Copse::Procfile.parse(File.read(absolute(PROCFILE))).secondaries.empty?

        say ""
        say "Copse runs the `web` process in the foreground and hands the rest to foreman."
        say "Add `gem \"foreman\"` to your Gemfile, or install it for the Ruby you use here."
      end

      private

      def exists?(relative) = File.exist?(absolute(relative))

      def absolute(relative) = File.join(destination_root, relative)
    end
  end
end
