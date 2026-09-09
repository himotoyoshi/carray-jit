require_relative "test_helper"

# An inner loop counts by the stride it was written with: `a.step(b, s)`,
# which is what an extent takes a direction in, and `(a...b).step(s)`, which
# is Ruby's other spelling of the same thing.  A downward sweep is the one
# that had to be written round the other way before.
class TestInnerSteps < Minitest::Test

  def test_a_downward_sweep
    rows, width = 3, 6
    source = CArray.double(rows, width) { |i, k| i * 10 + k }
    out = CArray.double(rows, width)

    CArray.jit_for(rows) { |i|
      carried = 0.0
      (width-1).step(0, -1) { |k|
        carried = carried * 0.5 + source[i, k]
        out[i, k] = carried
      }
    }

    expected = Array.new(rows) { |i|
      row = Array.new(width)
      carried = 0.0
      (width - 1).downto(0) { |k| carried = carried * 0.5 + (i * 10 + k) ; row[k] = carried }
      row
    }
    assert_equal(expected, out.to_a)
  end

  # The same sweep written round the other way, which was the only way to
  # write it before.  Both are still the same numbers.
  def test_the_reversed_index_agrees
    width = 6
    source = CArray.double(1, width) { |i, k| k + 1.0 }
    stepped = CArray.double(1, width)
    reversed = CArray.double(1, width)

    CArray.jit_for(1) { |i|
      carried = 0.0
      (width-1).step(0, -1) { |k|
        carried = carried * 0.5 + source[i, k]
        stepped[i, k] = carried
      }
    }
    CArray.jit_for(1) { |i|
      carried = 0.0
      (0...width).each { |t|
        k = width - 1 - t
        carried = carried * 0.5 + source[i, k]
        reversed[i, k] = carried
      }
    }
    assert_equal(stepped.to_a, reversed.to_a)
  end

  # `step` includes the index it is given, as Ruby's does, where a `...`
  # range excludes it.
  def test_the_last_index_is_included
    visited = CArray.int32(8)
    CArray.jit_for(1) { |i| 6.step(0, -2) { |k| visited[k] = 1 } }
    expected = Array.new(8, 0)
    6.step(0, -2) { |k| expected[k] = 1 }
    assert_equal(expected, visited.to_a)
    assert_equal(1, visited[0], "`step` visits the index it was given")
  end

  def test_an_ascending_stride
    width = 7
    source = CArray.double(2, width) { |i, k| k * 1.0 }
    out = CArray.double(2)
    CArray.jit_for(2) { |i|
      total = 0.0
      0.step(width-1, 2) { |k| total = total + source[i, k] }
      out[i] = total
    }
    assert_equal([12.0, 12.0], out.to_a)
  end

  # A range states its own ends, so it takes the stride alone.
  def test_a_range_with_a_stride
    source = CArray.double(2, 7) { |i, k| k * 1.0 }
    out = CArray.double(2)
    CArray.jit_for(2) { |i|
      total = 0.0
      (0...7).step(2) { |k| total = total + source[i, k] }
      out[i] = total
    }
    assert_equal([12.0, 12.0], out.to_a)

    inclusive = CArray.double(2)
    CArray.jit_for(2) { |i|
      total = 0.0
      (0..6).step(3) { |k| total = total + source[i, k] }
      inclusive[i] = total
    }
    assert_equal([9.0, 9.0], inclusive.to_a)
  end

  # Every cell the loop lands on has to exist, whichever way it runs.
  def test_the_span_a_stride_covers_is_bounds_checked
    source = CArray.double(2, 6)
    out = CArray.double(2)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i|
        total = 0.0
        5.step(0, -1) { |k| total = total + source[i, k-1] }
        out[i] = total
      }
    end
    assert_match(/the range on `k` cannot start at 0/, error.message)
  end

  def test_a_stride_that_is_not_a_literal
    source = CArray.double(2, 6)
    out = CArray.double(2)
    stride = -1
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i|
        total = 0.0
        5.step(0, stride) { |k| total = total + source[i, k] }
        out[i] = total
      }
    end
    assert_match(/says which way it runs, so it is an integer literal/, error.message)
  end

  def test_a_stride_of_zero
    source = CArray.double(2, 6)
    out = CArray.double(2)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i| 0.step(5, 0) { |k| out[i] = source[i, k] } }
    end
    assert_match(/stride cannot be zero/, error.message)
  end

  # A range that steps backwards raises in Ruby too, so the message names
  # the spelling that does count down.
  def test_a_range_cannot_step_backwards
    source = CArray.double(2, 6)
    out = CArray.double(2)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i| (0...6).step(-1) { |k| out[i] = source[i, k] } }
    end
    assert_match(/a range cannot step backwards/, error.message)
  end

  # Ruby's other ways of counting are refused by name, with the spelling to
  # use rather than a list to search.
  def test_downto_says_what_to_write_instead
    source = CArray.double(2, 6)
    out = CArray.double(2)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i|
        total = 0.0
        5.downto(0) { |k| total = total + source[i, k] }
        out[i] = total
      }
    end
    assert_match(/`downto` is not one of them/, error.message)
  end

  # Two sweeps in a body are written `{ |k| ... }` twice, and their ranges
  # are not the same one: `a[k-1]` in a loop from 1 is in bounds where the
  # same reach from 0 would not be.  Each loop gets an identifier of its own
  # for that, and the message still speaks the name the block wrote.
  def test_two_loops_may_share_the_index_name
    width = 6
    source = CArray.double(1, width) { |i, k| k + 1.0 }
    forward = CArray.double(1, width)
    backward = CArray.double(1, width)

    kernel = CArray.jit_for(1) { |i|
      (1...width).each { |k| forward[i, k] = source[i, k] - source[i, k-1] }
      (width-2).step(0, -1) { |k| backward[i, k] = forward[i, k+1] * 2.0 }
    }

    assert_equal([[0.0] + [1.0] * (width - 1)], forward.to_a)
    assert_equal([[2.0] * (width - 1) + [0.0]], backward.to_a)
    assert_includes(kernel.c_source, "int64_t k__2",
                    "the second loop counts in an identifier of its own")
  end

  def test_a_reused_index_name_is_reported_as_it_was_written
    width = 6
    source = CArray.double(1, width)
    out = CArray.double(1, width)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i|
        (1...width).each { |k| out[i, k] = source[i, k] }
        (0...width).each { |k| out[i, k] = source[i, k-1] }
      }
    end
    assert_match(/`source` is indexed at `source\[k - 1\]`/, error.message)
    refute_match(/k__2/, error.message)
  end

  # The accumulator is split into partial sums only for a loop that counts by
  # one; a stride keeps the serial chain, and so keeps Ruby's order.
  def test_a_stride_keeps_the_serial_accumulator
    source = CArray.double(1, 64) { |i, k| k * 1.0 }
    out = CArray.double(1)

    serial = CArray.jit_for(1) { |i|
      total = 0.0
      0.step(63, 2) { |k| total = total + source[i, k] }
      out[i] = total
    }
    assert_equal([(0..63).step(2).sum.to_f], out.to_a)
    refute_includes(serial.c_source, "total__p0")

    split = CArray.jit_for(1) { |i|
      total = 0.0
      (0...64).each { |k| total = total + source[i, k] }
      out[i] = total
    }
    assert_includes(split.c_source, "total__p0")
  end

end
