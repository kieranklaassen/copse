# frozen_string_literal: true

require "copse"

require "minitest/autorun"
require "fileutils"
require "tmpdir"

module CopseTestHelpers
  # Builds a throwaway git repository and yields its path. Used by the identity
  # tests, which shell out to real git rather than stubbing it.
  #
  # `name` becomes the repository's directory name, because that is what the
  # hostname is derived from -- so tests ask for the name they need rather than
  # moving the directory afterwards (which would break tmpdir cleanup).
  def with_git_repo(name: "app", branch: "main")
    Dir.mktmpdir("copse-repo") do |dir|
      root = File.join(File.realpath(dir), name)
      FileUtils.mkdir_p(root)
      git(root, "init", "--initial-branch", branch)
      git(root, "config", "user.email", "test@example.com")
      git(root, "config", "user.name", "Copse Test")
      File.write(File.join(root, "README.md"), "seed\n")
      git(root, "add", ".")
      git(root, "commit", "-m", "seed")
      yield root
    end
  end

  # Adds a linked worktree to `root` on a new branch and yields its path. `dir`
  # names the checkout directory, which matters for the detached-HEAD fallback
  # and for proving the branch wins over a conventional directory name.
  def with_linked_worktree(root, branch, dir: "checkout")
    Dir.mktmpdir("copse-linked") do |tmp|
      path = File.join(File.realpath(tmp), dir)
      git(root, "worktree", "add", "-b", branch, path)
      begin
        yield path
      ensure
        git(root, "worktree", "remove", "--force", path)
      end
    end
  end

  def git(root, *args)
    out = IO.popen({ "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null" },
                   ["git", "-C", root, *args], err: [:child, :out], &:read)
    raise "git #{args.join(' ')} failed in #{root}: #{out}" unless $?.success?

    out
  end

  # Removes the temp directory a test's `setup` created. Every suite that builds
  # one needs exactly this, so it lives here rather than four times over.
  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    super
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end
end

class Minitest::Test
  include CopseTestHelpers
end
