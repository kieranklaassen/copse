# frozen_string_literal: true

require "open3"

module Copse
  # Answers "what am I called, and what port do I get" by shelling out to git.
  #
  # Holds no state and touches no files. Nothing here needs git to succeed --
  # git only answers the naming question more precisely. A plain directory, or a
  # machine with no git at all, degrades to the directory name.
  class Worktree
    LABEL_LIMIT = 63

    # RFC 6761's own loopback TLD, and the default: a name under it needs no
    # advertising, no listener, and no /etc/hosts entry on a client that honours
    # it. Copse::Zeroconf swaps in `<machine>.local` for the clients that do not.
    LOCALHOST_DOMAIN = "localhost"

    attr_reader :root, :domain

    def initialize(root = Dir.pwd, domain: LOCALHOST_DOMAIN)
      @root = File.expand_path(root)
      @domain = domain
    end

    # `<project>.<domain>` for a main worktree, `<branch>.<project>.<domain>` for
    # a linked one.
    def host
      @host ||= [slug, project, domain].compact.join(".")
    end

    # The name the port is derived from, which is the `.localhost` one whatever
    # domain the app is published under.
    #
    # Deriving from `host` instead would make the port a function of the naming
    # mode, and both directions of that are wrong. A developer switching their own
    # machine to zeroconf naming would find every port moved -- bookmarks, OAuth
    # callback registrations, a `-p` typed into a script -- for a change that is
    # supposed to be about names. And the zeroconf name carries the *machine's*
    # name, so every teammate would derive a different port for the same branch,
    # which is the coordination-free promise (R4) going the wrong way.
    def canonical_host
      @canonical_host ||= [slug, project, LOCALHOST_DOMAIN].compact.join(".")
    end

    def port
      @port ||= Copse.port_for(canonical_host)
    end

    def companion_port
      @companion_port ||= Copse.companion_port_for(canonical_host)
    end

    def url
      "http://#{host}:#{port}"
    end

    # What a linked worktree's development database name is suffixed with, or nil
    # in a main worktree -- which keeps the app's plain database.
    #
    # The same slug the hostname uses, with `-` swapped for `_`: a hyphen is
    # legal in a database name but has to be quoted on every `psql` and `mysql`
    # command line, and `_` is what Rails' own `<app>_development` already uses.
    def database_suffix
      slug&.tr("-", "_")
    end

    # The project name: the main worktree's directory name, even when called from
    # a linked worktree.
    def project
      @project ||= self.class.slug(File.basename(main_root)) || "app"
    end

    # nil for a main worktree; the branch name (or this directory's name on a
    # detached HEAD) for a linked one.
    def slug
      return @slug if defined?(@slug)

      @slug = if linked?
                self.class.slug(branch) || self.class.slug(File.basename(toplevel))
              end
    end

    def linked?
      return @linked if defined?(@linked)

      @linked = !main_root.nil? && !toplevel.nil? && main_root != toplevel
    end

    def branch
      return @branch if defined?(@branch)

      name = git("rev-parse", "--abbrev-ref", "HEAD")
      # "HEAD" means detached; there is no branch to name the worktree after.
      @branch = (name == "HEAD" ? nil : name)
    end

    # Reduces an arbitrary string to a single valid DNS label.
    #
    # A whitelist, not a substitution list. Git accepts branch names containing
    # `;`, `$(`, `&&`, quotes, and more, and the slug flows into COPSE_HOST,
    # COPSE_URL, every child process's environment, and a generated Procfile that
    # a shell will execute -- so anything outside [a-z0-9-] is replaced rather
    # than passed through. Branch names also arrive from collaborators via
    # `git fetch`; they are not necessarily the developer's own input.
    #
    # Returns nil when nothing survives, so callers can fall back.
    def self.slug(value)
      collapsed = value.to_s.downcase.gsub(/[^a-z0-9]+/, "-")
      trimmed = collapsed[0, LABEL_LIMIT].to_s.gsub(/\A-+|-+\z/, "")
      trimmed.empty? ? nil : trimmed
    end

    private

    def toplevel
      return @toplevel if defined?(@toplevel)

      path = git("rev-parse", "--show-toplevel")
      @toplevel = path && File.realpath(path)
    rescue Errno::ENOENT
      @toplevel = nil
    end

    # The main worktree's root. `--git-common-dir` points at the shared `.git`
    # directory from anywhere in the repository, including a linked worktree, so
    # its parent is the main checkout.
    def main_root
      return @main_root if defined?(@main_root)

      common = git("rev-parse", "--git-common-dir")
      @main_root =
        if common
          File.realpath(File.dirname(File.expand_path(common, @root)))
        else
          # Not a git worktree, or no git: fall back to this directory's name.
          @root
        end
    rescue Errno::ENOENT
      @main_root = @root
    end

    # Returns the trimmed stdout, or nil when git fails for any reason --
    # including not being installed.
    def git(*args)
      out, _err, status = Open3.capture3("git", "-C", @root, *args)
      status.success? ? out.strip : nil
    rescue Errno::ENOENT, Errno::EACCES
      # No git on PATH. Not an error: derivation does not require it.
      nil
    end
  end
end
