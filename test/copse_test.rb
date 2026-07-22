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
