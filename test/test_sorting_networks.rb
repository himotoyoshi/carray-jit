require_relative "test_helper"
require "carray/jit/sorting_networks"

# A table of comparator pairs is exactly the kind of data that is wrong in one
# place and silently almost-right: a network with one pair out of order still
# sorts most inputs, and the ones it fails on are the ones nobody tried.
#
# So none of the table is taken on the word of a citation.  The zero-one
# principle says a comparator network sorts every input if and only if it
# sorts every sequence of zeros and ones, so every length here is checked
# against all 2**n of them -- 65536 at the longest -- and the comparator count
# is checked against the smallest known.
class TestSortingNetworks < Minitest::Test

  NETWORKS = CArray::JIT::SortingNetworks

  # The smallest known, written out here rather than read from the table under
  # test: a count the table derived from itself would agree with itself.
  # Optimal for 2..12, best known for 13..16.
  SMALLEST_KNOWN = {
    2 => 1, 3 => 3, 4 => 5, 5 => 9, 6 => 12, 7 => 16, 8 => 19, 9 => 25,
    10 => 29, 11 => 35, 12 => 39, 13 => 45, 14 => 51, 15 => 56, 16 => 60,
  }.freeze

  # Runs the network over one arrangement of zeros and ones.
  def run_network (network, values)
    channels = values.dup
    network.each do |low, high|
      if channels[low] > channels[high]
        channels[low], channels[high] = channels[high], channels[low]
      end
    end
    channels
  end

  def test_every_length_from_two_to_sixteen_has_a_network
    assert_equal((2..16).to_a, NETWORKS::NETWORKS.keys.sort)
    assert_equal(16, NETWORKS::LONGEST)
  end

  # One test per length rather than one loop over all of them, so a failure
  # names the length that is wrong.
  (2..16).each do |length|
    define_method("test_the_network_for_#{length}_sorts_every_zero_one_input") do
      network = NETWORKS.for(length)
      refute_nil(network, "no network for #{length}")
      (0...(1 << length)).each do |bits|
        values = (0...length).map { |channel| (bits >> channel) & 1 }
        sorted = run_network(network, values)
        assert_equal(values.sort, sorted,
                     "#{length} channels, input #{values.inspect}")
      end
    end

    define_method("test_the_network_for_#{length}_is_the_smallest_known") do
      assert_equal(SMALLEST_KNOWN.fetch(length), NETWORKS.for(length).size,
                   "the network for #{length} should have " \
                   "#{SMALLEST_KNOWN.fetch(length)} comparators")
    end

    define_method("test_every_comparator_for_#{length}_is_a_pair_in_range") do
      NETWORKS.for(length).each do |comparator|
        assert_equal(2, comparator.size, "#{comparator.inspect} is not a pair")
        low, high = comparator
        assert_operator(low, :<, high,
                        "#{comparator.inspect} is not written low first")
        assert_operator(low, :>=, 0, "#{comparator.inspect} is out of range")
        assert_operator(high, :<, length,
                        "#{comparator.inspect} reaches past #{length} channels")
      end
    end
  end

  def test_the_sizes_table_agrees_with_the_networks
    assert_equal(SMALLEST_KNOWN, NETWORKS::SIZES)
  end

  # What the generator asks before it chooses between a network and a loop.
  def test_one_channel_is_covered_without_a_comparator
    assert(NETWORKS.covers?(1))
    assert_nil(NETWORKS.for(1))
  end

  def test_a_length_past_the_longest_is_not_covered
    assert(NETWORKS.covers?(16))
    refute(NETWORKS.covers?(17))
    assert_nil(NETWORKS.for(17))
  end

  # Pruning is what 9, 14 and 15 were derived by, so the derivation is checked
  # too: setting the channels above a length to positive infinity makes every
  # comparator touching one a no-op on the rest.
  def test_pruning_a_network_sorts_the_channels_that_are_left
    pruned = NETWORKS.prune(NETWORKS::GREEN_16, 11)
    (0...(1 << 11)).each do |bits|
      values = (0...11).map { |channel| (bits >> channel) & 1 }
      assert_equal(values.sort, run_network(pruned, values),
                   "pruned to 11, input #{values.inspect}")
    end
  end

  def test_pruning_reaches_no_channel_it_dropped
    NETWORKS.prune(NETWORKS::GREEN_16, 9).each do |low, high|
      assert_operator(high, :<, 9)
      assert_operator(low, :<, 9)
    end
  end

  # A network is applied in order, so the tables are frozen: one kernel's
  # sort would otherwise be able to change another's.
  def test_the_tables_are_frozen
    assert_predicate(NETWORKS::NETWORKS, :frozen?)
    NETWORKS::NETWORKS.each_value { |network| assert_predicate(network, :frozen?) }
  end

end
