require_relative "test_helper"

# A subscript the kernel works out -- `table[index[i]]`, `hist[bin]` -- cannot
# be checked before the kernel runs, so it is checked as it is reached.  Every
# other subscript keeps the check it had, which is the one that costs nothing.
class TestComputedSubscripts < Minitest::Test

  def test_a_gather_matches_the_ruby_loop
    table = CArray.double(5) { |i| (i * i).to_f }
    index = CArray.int32(6) { |i| i % 5 }
    result = CArray.double(6)
    CArray.jit_for(6) { |i| result[i] = table[index[i]] }
    assert_equal((0...6).map { |i| table[index[i]] }, result.to_a)
  end

  def test_a_subscript_may_be_a_local
    table = CArray.double(5) { |i| (i * i).to_f }
    result = CArray.double(6)
    CArray.jit_for(6) { |i|
      j = i / 2
      result[i] = table[j]
    }
    assert_equal((0...6).map { |i| table[i / 2] }, result.to_a)
  end

  def test_a_read_outside_the_array_raises_where_the_ruby_loop_raises
    table = CArray.double(5) { |i| (i * i).to_f }
    index = CArray.int32(6) { |i| i }        # 5 is outside
    result = CArray.double(6)
    assert_raises(IndexError) do
      CArray.jit_for(6) { |i| result[i] = table[index[i]] }
    end
    assert_equal([0.0, 1.0, 4.0, 9.0, 16.0], result[0..4].to_a,
                 "the cells before it were written")
    assert_equal(0.0, result[5], "and the failing one was not")
  end

  def test_a_scatter_matches_the_ruby_loop
    values = CArray.double(20) { |i| (i * 7 % 20) / 4.0 }
    histogram = CArray.int32(5)
    CArray.jit_for(20) { |i|
      bin = values[i].floor
      histogram[bin] = histogram[bin] + 1
    }
    reference = Array.new(5, 0)
    20.times { |i| reference[values[i].floor] += 1 }
    assert_equal(reference, histogram.to_a)
  end

  # Reading outside an array can be made harmless; writing outside it cannot,
  # so the write is skipped and the loop stops -- which is where the Ruby loop
  # stops as well.
  def test_a_scatter_outside_the_array_writes_nothing_and_stops
    histogram = CArray.int32(3) { |i| 7 }
    bins = CArray.int32(4) { |i| [0, 5, 1, -1][i] }
    assert_raises(IndexError) do
      CArray.jit_for(4) { |i| histogram[bins[i]] = histogram[bins[i]] + 1 }
    end

    reference = [7, 7, 7]
    assert_raises(IndexError) do
      4.times { |i| reference[bins[i]] = reference.fetch(bins[i]) + 1 }
    end
    assert_equal(reference, histogram.to_a)
    assert_equal([8, 7, 7], histogram.to_a)
  end

  # A view with no stride expression is handed the box the kernel says it will
  # touch.  A computed index says nothing in advance, so the box becomes the
  # whole view -- which costs what copying it would have cost, and is what the
  # caller would otherwise have written by hand.
  def test_a_gather_view_takes_a_computed_index_by_crossing_whole
    whole = CArray.double(16).seq!
    view = whole[whole >= 8.0]
    index = CArray.int32(4) { |i| 3 - i }
    result = CArray.double(4)
    CArray.jit_for(4) { |i| result[i] = view[index[i]] }
    assert_equal((0...4).map { |i| view[3 - i] }, result.to_a)
  end

  def test_a_scatter_through_a_gather_view_reaches_the_parent
    whole = CArray.double(16).seq!
    view = whole[whole >= 8.0]
    index = CArray.int32(4) { |i| 3 - i }
    CArray.jit_for(4) { |i| view[index[i]] = -1.0 }
    assert_equal([-1.0] * 4, whole[8..11].to_a)
    assert_equal([7.0, 12.0], [whole[7], whole[12]], "outside it is untouched")
  end

  def test_a_strided_view_takes_one
    column = CArray.double(8, 3).seq![nil, 1]
    index = CArray.int32(4) { |i| i }
    result = CArray.double(4)
    CArray.jit_for(4) { |i| result[i] = column[index[i]] }
    assert_equal((0...4).map { |i| column[i] }, result.to_a)
  end

  # A displaced write reaches one cell past the extent, and that is the whole
  # of what is wrong with it here: the answer to a subscript running off the
  # end is the bounds check, not a refusal to compile the shape.  A computed
  # one is a scatter, and is checked at the cell instead.
  def test_writing_a_neighbouring_cell_is_bounds_checked
    values = CArray.double(6)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(6) { |i| values[i + 1] = 1.0 }
    end
    assert_match(/cannot end at 6 for an extent of 6/, error.message)
    assert_equal([0.0] * 6, values.to_a, "nothing ran")

    CArray.jit_for(5) { |i| values[i + 1] = 1.0 }
    assert_equal([0.0] + [1.0] * 5, values.to_a)
  end

  # The value under a masked cell is out of contract, so an index that only
  # ever feeds one is not an error the caller asked about -- the same rule
  # integer division by zero already follows.
  def test_a_masked_cell_swallows_the_index_error
    source = CArray.double(4).seq!(1.0)
    source[2] = UNDEF
    index = CArray.int32(4) { |i| i == 2 ? 99 : i }
    result = CArray.double(4)
    CArray.jit_for(4) { |i|
      result[i] = source[i] * 0.0 + source[index[i]]
    }
    assert(result.is_masked[2])
    refute(result.is_masked[0])
  end

end
