# frozen_string_literal: true

require "test_helper"

class CopseTest < Minitest::Test
  def test_version_is_a_frozen_string
    assert_kind_of String, Copse::VERSION
    assert_predicate Copse::VERSION, :frozen?
  end

  def test_start_is_defined
    assert_respond_to Copse, :start
  end

  def test_the_railtie_loads_automatically_when_rails_is_already_present
    # The path every real Rails app takes, and the one the railtie tests bypass:
    # they require "copse/railtie" explicitly because copse was already loaded
    # without Rails. Run in a child so this process stays Rails-free.
    # `require "rails"` is what an app's boot does, and it is the only supported way
    # in: `rails/railtie` on its own fails, because it needs ActiveSupport's core
    # extensions loaded first.
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.expand_path("../lib", __dir__).inspect})
      require "rails"
      require "copse"
      raise "railtie was not auto-loaded" unless Copse.const_defined?(:Railtie)
      raise "not a Railtie" unless Copse::Railtie < Rails::Railtie
      puts "ok"
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-e", script)

    assert_predicate status, :success?, "#{err}#{out}"
    assert_equal "ok", out.strip
  end

  def test_the_gem_loads_without_rails_and_defines_no_railtie
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.expand_path("../lib", __dir__).inspect})
      require "copse"
      raise "Railtie defined without Rails" if Copse.const_defined?(:Railtie)
      puts "ok"
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-e", script)

    assert_predicate status, :success?, "#{err}#{out}"
    assert_equal "ok", out.strip
  end

  def test_available_ports_excludes_every_reserved_port
    Copse::RESERVED_PORTS.each do |reserved|
      refute_includes Copse::AVAILABLE_PORTS, reserved,
                      "reserved port #{reserved} is reachable by derivation"
    end
  end

  def test_available_ports_is_the_range_minus_the_reserved_list
    assert_equal Copse::PORT_RANGE.count - Copse::RESERVED_PORTS.uniq.count,
                 Copse::AVAILABLE_PORTS.size
    assert_equal Copse::RESERVED_PORTS, Copse::RESERVED_PORTS.uniq,
                 "the reserved list has duplicates, which would silently shrink the available set"
  end
end
