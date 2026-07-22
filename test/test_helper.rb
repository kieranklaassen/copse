# frozen_string_literal: true

require "copse"

require "minitest/autorun"
require "fileutils"
require "tmpdir"

module CopseTestHelpers
  # Builds a throwaway git repository and yields its path. Used by the identity
  # tests, which shell out to real git rather than stubbing it.
  def with_git_repo(branch: "main")
    Dir.mktmpdir("copse-repo") do |dir|
      root = File.realpath(dir)
      git(root, "init", "--initial-branch", branch)
      git(root, "config", "user.email", "test@example.com")
      git(root, "config", "user.name", "Copse Test")
      File.write(File.join(root, "README.md"), "seed\n")
      git(root, "add", ".")
      git(root, "commit", "-m", "seed")
      yield root
    end
  end

  # Adds a linked worktree to `root` on a new branch and yields its path.
  def with_linked_worktree(root, branch)
    Dir.mktmpdir("copse-linked") do |dir|
      path = File.join(File.realpath(dir), "checkout")
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

  # Returns the pids of every descendant of `pid`, so teardown tests can assert
  # nothing survived rather than trusting an exit status.
  def descendant_pids(pid)
    out = `ps -eo pid=,ppid=`
    children = out.lines.map { |l| l.split.map(&:to_i) }
    collect = lambda do |parent|
      direct = children.select { |_, ppid| ppid == parent }.map(&:first)
      direct + direct.flat_map { |c| collect.call(c) }
    end
    collect.call(pid)
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
