class CArray
  module JIT

    # Comparator networks for the lengths a local array is sorted at without a
    # loop: a fixed sequence of compare-exchange pairs, the same one every
    # time, with no branch and nothing to predict.
    #
    # A network is a list of `[i, j]` with `i < j`, applied in order.  Each
    # pair says "put the smaller of these two channels in i and the larger in
    # j"; run them all and the channels come out ordered, whatever they held.
    # That is the whole of the interface -- the generator turns each pair into
    # one compare-exchange in C, and what decides which pair comes first is
    # nothing but this list.
    #
    # ## Where these came from
    #
    # The sizes are the smallest known for each length, and for n <= 12 they
    # are known to be optimal (Codish, Cruz-Filipe, Frank and Schneider-Kamp,
    # "Twenty-Five Comparators Is Optimal When Sorting Nine Inputs (and
    # Twenty-Nine for Ten)", 2014, for 9 and 10; the smaller ones are in
    # Knuth, *The Art of Computer Programming*, vol. 3, section 5.3.4).  For
    # 13 to 16 they are the best known rather than proven optimal; the
    # 16-input network with 60 comparators is Green's, given in Knuth's
    # section 5.3.4 and figure 51.
    #
    # | n | comparators | n | comparators |
    # |---|---|---|---|
    # | 2 | 1 | 10 | 29 |
    # | 3 | 3 | 11 | 35 |
    # | 4 | 5 | 12 | 39 |
    # | 5 | 9 | 13 | 45 |
    # | 6 | 12 | 14 | 51 |
    # | 7 | 16 | 15 | 56 |
    # | 8 | 19 | 16 | 60 |
    # | 9 | 25 | | |
    #
    # ## Why they can be trusted
    #
    # A table of pairs is exactly the kind of data that is wrong in one place
    # and silently almost-right, so none of it is taken on the word of a
    # citation.  Every network here is checked by the **zero-one principle**:
    # a comparator network sorts every input if and only if it sorts every
    # sequence of zeros and ones.  For n channels that is 2**n sequences --
    # 65536 at the largest length here -- and `test/test_sorting_networks.rb`
    # runs all of them for all fifteen lengths, along with the comparator
    # count and the shape of each pair.  A network that is wrong fails there
    # rather than in somebody's median filter.
    #
    # ## Pruning
    #
    # Where one of these was derived from a longer one, it was derived by
    # pruning: set the last input to positive infinity and every comparator
    # touching that channel becomes a no-op on the others, so deleting them
    # leaves a network that sorts the rest.  14 and 15 are the 16-input
    # network pruned that way, and 9 is the 10-input one pruned.  The others
    # are written out.
    module SortingNetworks

      # The longest length that gets a network.  Above it the generator emits
      # an insertion sort, which is a loop: the tables would keep growing and
      # the win over a loop shrinks as the length rises, there being more
      # comparators than the machine has registers long before this.
      LONGEST = 16

      # Green's 16-input network, 60 comparators.  14 and 15 are pruned from
      # it below, which is where their 51 and 56 come from.
      GREEN_16 = [
        [0, 1], [2, 3], [4, 5], [6, 7], [8, 9], [10, 11], [12, 13], [14, 15],
        [0, 2], [4, 6], [8, 10], [12, 14], [1, 3], [5, 7], [9, 11], [13, 15],
        [0, 4], [8, 12], [1, 5], [9, 13], [2, 6], [10, 14], [3, 7], [11, 15],
        [0, 8], [1, 9], [2, 10], [3, 11], [4, 12], [5, 13], [6, 14], [7, 15],
        [5, 10], [6, 9], [3, 12], [13, 14], [7, 11], [1, 2], [4, 8],
        [1, 4], [7, 13], [2, 8], [11, 14],
        [5, 6], [9, 10],
        [2, 4], [11, 13], [3, 8], [7, 12],
        [6, 8], [10, 12], [3, 5], [7, 9],
        [3, 4], [5, 6], [7, 8], [9, 10], [11, 12],
        [6, 7], [8, 9],
      ].freeze

      # The 10-input network, 29 comparators.  9 is pruned from it.
      TEN = [
        [0, 8], [1, 9], [2, 7], [3, 5], [4, 6],
        [0, 2], [1, 4], [5, 8], [7, 9],
        [0, 3], [2, 4], [5, 7], [6, 9],
        [0, 1], [3, 6], [8, 9],
        [1, 5], [2, 3], [4, 8], [6, 7],
        [1, 2], [3, 5], [4, 6], [7, 8],
        [2, 3], [4, 5], [6, 7],
        [3, 4], [5, 6],
      ].freeze

      # Sets the channels at or above `channels` to positive infinity, which
      # makes every comparator that touches one a no-op on the rest.
      def self.prune (network, channels)
        network.reject { |low, high| low >= channels || high >= channels }
      end

      NETWORKS = {
        2  => [[0, 1]],

        3  => [[0, 2], [0, 1], [1, 2]],

        4  => [[0, 1], [2, 3], [0, 2], [1, 3], [1, 2]],

        5  => [[0, 1], [3, 4], [2, 4], [2, 3], [1, 4],
               [0, 3], [0, 2], [1, 3], [1, 2]],

        6  => [[1, 2], [4, 5], [0, 2], [3, 5], [0, 1], [3, 4],
               [2, 5], [0, 3], [1, 4], [2, 4], [1, 3], [2, 3]],

        7  => [[1, 2], [3, 4], [5, 6], [0, 2], [3, 5], [4, 6],
               [0, 1], [4, 5], [2, 6], [0, 4], [1, 5], [0, 3],
               [2, 5], [1, 3], [2, 4], [2, 3]],

        # Batcher's odd-even merge, which at this length is also the smallest.
        8  => [[0, 2], [1, 3], [4, 6], [5, 7],
               [0, 4], [1, 5], [2, 6], [3, 7],
               [0, 1], [2, 3], [4, 5], [6, 7],
               [2, 4], [3, 5],
               [1, 4], [3, 6],
               [1, 2], [3, 4], [5, 6]],

        9  => prune(TEN, 9),

        10 => TEN,

        11 => [[0, 9], [1, 6], [2, 4], [3, 7], [5, 8],
               [0, 1], [3, 5], [4, 10], [6, 9], [7, 8],
               [1, 3], [2, 5], [4, 7], [8, 10],
               [0, 4], [1, 2], [3, 7], [5, 9], [6, 8],
               [0, 1], [2, 6], [4, 5], [7, 8], [9, 10],
               [2, 4], [3, 6], [5, 7], [8, 9],
               [1, 2], [3, 4], [5, 6], [7, 8],
               [2, 3], [4, 5], [6, 7]],

        12 => [[0, 8], [1, 7], [2, 6], [3, 11], [4, 10], [5, 9],
               [0, 1], [2, 5], [3, 4], [6, 9], [7, 8], [10, 11],
               [0, 2], [1, 6], [5, 10], [9, 11],
               [0, 3], [1, 2], [4, 6], [5, 7], [8, 11], [9, 10],
               [1, 4], [3, 5], [6, 8], [7, 10],
               [1, 3], [2, 5], [6, 9], [8, 10],
               [2, 3], [4, 5], [6, 7], [8, 9],
               [4, 6], [5, 7],
               [3, 4], [5, 6], [7, 8]],

        13 => [[0, 12], [1, 10], [2, 9], [3, 7], [5, 11], [6, 8],
               [1, 6], [2, 3], [4, 11], [7, 9], [8, 10],
               [0, 4], [1, 2], [3, 6], [7, 8], [9, 10], [11, 12],
               [4, 6], [5, 9], [8, 11], [10, 12],
               [0, 5], [3, 8], [4, 7], [6, 11], [9, 10],
               [0, 1], [2, 5], [6, 9], [7, 8], [10, 11],
               [1, 3], [2, 4], [5, 6], [9, 10],
               [1, 2], [3, 4], [5, 7], [6, 8],
               [2, 3], [4, 5], [6, 7], [8, 9],
               [3, 4], [5, 6]],

        14 => prune(GREEN_16, 14),

        15 => prune(GREEN_16, 15),

        16 => GREEN_16,
      }.each_value(&:freeze).freeze

      # The comparator count per length, which the tests assert and the docs
      # quote.  Derived rather than written down a second time.
      SIZES = NETWORKS.transform_values(&:size).freeze

      # The network for `length`, or nil where there is none -- length 1 is
      # already sorted and needs no comparator, and anything above LONGEST
      # gets a loop instead.
      def self.for (length)
        NETWORKS[length]
      end

      def self.covers? (length)
        length == 1 || NETWORKS.key?(length)
      end

    end
  end
end
