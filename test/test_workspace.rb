require_relative "test_helper"

# A row of workspace per outer cell: `work[i, k] = ...` fills it, and the
# same inner index reads it back.  The point of it is the algorithm that
# needs somewhere to put a few numbers per cell -- a small dense solve, a
# tableau -- which otherwise has to be split into kernels that each pay a
# call.
class TestWorkspace < Minitest::Test

  def test_filling_a_row_and_reading_it_back
    rows, width = 5, 4
    source = CArray.double(rows) { |i| i + 1.0 }
    work = CArray.double(rows, width)
    out = CArray.double(rows)

    CArray.jit_for(rows) { |i|
      (0...width).each { |k| work[i, k] = source[i] * (k + 1) }
      total = 0.0
      (0...width).each { |k| total = total + work[i, k] }
      out[i] = total
    }

    expected_work = Array.new(rows) { |i| Array.new(width) { |k| (i + 1.0) * (k + 1) } }
    assert_equal(expected_work, work.to_a)
    assert_equal(expected_work.map(&:sum), out.to_a)
  end

  # Walking back down the row is the other half of it, and says so with the
  # stride an extent says a downward sweep with.
  def test_walking_the_row_back_down
    rows, width = 3, 5
    work = CArray.double(rows, width)
    out = CArray.double(rows)

    CArray.jit_for(rows) { |i|
      (0...width).each { |k| work[i, k] = i + k * 0.5 }
      carried = 0.0
      (width-1).step(0, -1) { |k| carried = carried * 0.5 + work[i, k] }
      out[i] = carried
    }

    expected = Array.new(rows) { |i|
      row = Array.new(width) { |k| i + k * 0.5 }
      carried = 0.0
      (width - 1).downto(0) { |k| carried = carried * 0.5 + row[k] }
      carried
    }
    assert_equal(expected, out.to_a)
  end

  # The whole reason for the axis: a tridiagonal solve per row, in one
  # kernel, where each row's forward sweep needs somewhere of its own to
  # keep the coefficients it hands to the back substitution.
  def test_a_tridiagonal_solve_per_row
    rows, width = 4, 6
    random = Random.new(20260910)
    lower = CArray.double(rows, width) { random.rand(-1.0..1.0) }
    diagonal = CArray.double(rows, width) { 4.0 + random.rand }
    upper = CArray.double(rows, width) { random.rand(-1.0..1.0) }
    right = CArray.double(rows, width) { random.rand(-1.0..1.0) }
    (0...rows).each { |i| lower[i, 0] = 0.0 ; upper[i, width - 1] = 0.0 }

    swept = CArray.double(rows, width)
    carried = CArray.double(rows, width)
    answer = CArray.double(rows, width)

    CArray.jit_for(rows) { |i|
      swept[i, 0] = upper[i, 0] / diagonal[i, 0]
      carried[i, 0] = right[i, 0] / diagonal[i, 0]
      (1...width).each { |k|
        denominator = diagonal[i, k] - lower[i, k] * swept[i, k-1]
        swept[i, k] = upper[i, k] / denominator
        carried[i, k] = (right[i, k] - lower[i, k] * carried[i, k-1]) / denominator
      }
      answer[i, width-1] = carried[i, width-1]
      (width-2).step(0, -1) { |k|
        answer[i, k] = carried[i, k] - swept[i, k] * answer[i, k+1]
      }
    }

    residual = 0.0
    (0...rows).each do |i|
      (0...width).each do |k|
        row = diagonal[i, k] * answer[i, k]
        row += lower[i, k] * answer[i, k-1] if k > 0
        row += upper[i, k] * answer[i, k+1] if k < width - 1
        residual = [residual, (row - right[i, k]).abs].max
      end
    end
    assert_operator(residual, :<, 1e-12)
  end

  # An axis the write walks with the outer index is the axis the row belongs
  # to, so a row may be read from the cell before it: that row was finished
  # by the outer iteration before this one, which is what the same Ruby loop
  # would have read.
  def test_a_row_reading_the_row_before_it
    rows, width = 4, 3
    work = CArray.double(rows, width)
    (0...width).each { |k| work[0, k] = k + 1.0 }

    CArray.jit_for(1...rows) { |i|
      (0...width).each { |k| work[i, k] = work[i-1, k] * 2.0 }
    }

    expected = Array.new(rows) { |i| Array.new(width) { |k| (k + 1.0) * 2 ** i } }
    assert_equal(expected, work.to_a)
  end

  # A sort inside the row moves cells about at positions the body works
  # out, and the row is still the cell's own: what picks it is axis 0, which
  # every write and every read here walks with `i`.  This is a median
  # filter, which is the shape that has no expression as an extra axis --
  # the window has to be somewhere while it is being sorted.
  def test_sorting_within_the_row
    values = [3.0, 1.0, 4.0, 1.0, 5.0, 90.0, 2.0, 6.0, 5.0, 3.0]
    width = 5
    half = width / 2
    signal = CArray.double(values.size) { |i| values[i] }
    window = CArray.double(values.size, width)
    median = CArray.double(values.size)

    CArray.jit_for(half...(values.size - half)) { |i|
      (0...width).each { |k| window[i, k] = signal[i - half + k] }
      (1...width).each { |k|
        key = window[i, k]
        placed = k - 1
        while placed >= 0 && window[i, placed] > key
          window[i, placed+1] = window[i, placed]
          placed = placed - 1
        end
        window[i, placed+1] = key
      }
      median[i] = window[i, half]
    }

    expected = (half...(values.size - half)).map { |i|
      values[(i - half)..(i + half)].sort[half]
    }
    assert_equal(expected, median[half...(values.size - half)].to_a)
  end

  # The reach is checked before anything runs, as a displaced write through
  # an outer index is.
  def test_a_displaced_write_through_an_inner_index_is_bounds_checked
    work = CArray.double(3, 4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| (0...4).each { |k| work[i, k+1] = 1.0 } }
    end
    assert_match(/the range on `k` cannot end at 4 for an extent of 4/, error.message)
    assert_equal([[0.0] * 4] * 3, work.to_a, "nothing ran")
  end

  # What stays refused: reading an array this kernel writes through an inner
  # index on an axis the writes do not walk with that index.  There the read
  # reaches cells another outer iteration owns.
  def test_reading_a_written_array_on_an_axis_the_write_does_not_share
    work = CArray.double(3, 4)
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i|
        (0...4).each { |k| work[i, k] = 1.0 }
        total = 0.0
        (0...3).each { |k| total = total + work[k, 0] }
        out[i] = total
      }
    end
    assert_match(/`work` is written on axis 0 through `i`/, error.message)
    assert_match(/cannot also be read through the inner index `k`/, error.message)
  end

  # The rule this replaces was stopping a spelling rather than a thing:
  # writing at `k` was refused while writing at a local holding `k` compiled,
  # as a scatter.  Both are accepted now, and the direct one is the cheaper
  # of the two -- an index needs no bounds check as it is reached.
  def test_the_index_and_a_local_holding_it_agree
    work = CArray.double(3, 4)
    copy = CArray.double(3, 4)

    direct = CArray.jit_for(3) { |i| (0...4).each { |k| work[i, k] = i + k } }
    through_a_local =
      CArray.jit_for(3) { |i| (0...4).each { |k| position = k + 0 ; copy[i, position] = i + k } }

    assert_equal(work.to_a, copy.to_a)
    assert_includes(through_a_local.c_source, ">= 0 &&",
                    "the local is a scatter, and is checked as it is reached")
    refute_includes(direct.c_source, ">= 0 &&",
                    "the index is the loop's own, and needs no check")
  end

end
