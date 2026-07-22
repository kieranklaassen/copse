# frozen_string_literal: true

require_relative "lib/copse/version"

Gem::Specification.new do |spec|
  spec.name = "copse"
  spec.version = Copse::VERSION
  spec.authors = ["Kieran Klaassen"]

  spec.summary = "A hostname and a port for every Rails app and every git worktree."
  spec.description = <<~DESC.tr("\n", " ").strip
    Copse derives a hostname and a port for each Rails app and each git worktree, so several
    can run at once without colliding and without anyone choosing numbers. The web process stays
    in the foreground and owns the TTY, so binding.irb and debug keep working. No daemon, no
    reverse proxy, no privileged listener, and no runtime dependencies.
  DESC

  spec.homepage = "https://github.com/kieranklaassen/copse"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir[
    "lib/**/*.rb",
    "lib/generators/**/*.tt",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt"
  ]
  spec.require_paths = ["lib"]

  # Zero dependencies, runtime or development. Development dependencies live in
  # Gemfile only -- see KTD6 in docs/plans. Foreman is invoked as a subprocess,
  # never required, so it is not a dependency of this gem either.
end
