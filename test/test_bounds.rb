require_relative "test_helper"

# The range is given, not guessed.  Every cell the kernel would touch is then
# known before anything runs, so reaching outside the array is a message
# rather than a read past the end.
class TestBounds < Minitest::Test

  def test_range_that_starts_too_early
    values = CArray.double(8)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(0...8) { |i| values[i] = values[i-1] * 2.0 }
    end
    assert_match(/`values` is indexed at `values\[i - 1\]`/, error.message)
    assert_match(/cannot start at 0/, error.message)
  end

  def test_extent_that_reaches_past_the_end
    values = CArray.double(8)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(7.step(0, -1)) { |i| values[i] = values[i+1] * 2.0 }
    end
    assert_match(/cannot end at 8/, error.message)
  end

  def test_depth_two_needs_two_cells_of_room
    values = CArray.double(8)
    assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1...8) { |i| values[i] = values[i-1] + values[i-2] }
    end
    CArray.jit_for(2...8) { |i| values[i] = values[i-1] + values[i-2] }
  end

  def test_bounds_are_checked_per_array
    short = CArray.double(4)
    long = CArray.double(16)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(0...16) { |i| long[i] = short[i] * 2.0 }
    end
    assert_match(/`short`/, error.message)
  end

  def test_bounds_are_checked_per_axis
    values = CArray.double(6, 6)
    other = CArray.double(6, 6).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1...5, 0...6) { |i, j| values[i, j] = other[i, j-1] }
    end
    assert_match(/on `j`/, error.message)
  end

  def test_extent_count_must_match_the_index_count
    values = CArray.double(4, 4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(0...4) { |i, j| values[i, j] = 1.0 }
    end
    assert_match(/names 2 indices, and 1 extent was given/, error.message)
  end

  def test_array_rank_must_match_the_index_count
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(0...4, 0...4) { |i, j| values[i, j] = 1.0 }
    end
    assert_match(/has rank 1/, error.message)
  end

  def test_endless_range_is_refused
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1..) { |i| values[i] = 1.0 }
    end
    assert_match(/endless range/, error.message)
  end

  def test_extent_of_the_wrong_kind_is_refused
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for("all") { |i| values[i] = 1.0 }
    end
    assert_match(/a Range, an Integer or an arithmetic sequence/, error.message)
  end

  # An offset may be an integer the block closed over.  One kernel then serves
  # every value of it, and the judgements that need the value are made when it
  # is called -- alongside the bounds check, which is already there.
  def test_an_offset_may_be_a_captured_integer
    n = 12
    source = CArray.double(n).seq!(1.0)
    result = CArray.double(n)
    before = CArray::JIT.registry.size
    [1, 2, 5].each do |window|
      CArray.jit_for(window...n) { |i| result[i] = source[i] - source[i - window] }
      assert_equal((window...n).map { |i| source[i] - source[i - window] },
                   (window...n).map { |i| result[i] })
    end
    assert_equal(1, CArray::JIT.registry.size - before,
                 "one compiled kernel serves every window")
  end

  def test_a_captured_offset_is_bounds_checked_with_its_value
    n = 12
    source = CArray.double(n).seq!(1.0)
    result = CArray.double(n)
    window = 4
    CArray.jit_for(window...n) { |i| result[i] = source[i - window] }
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2...n) { |i| result[i] = source[i - window] }
    end
    assert_match(/`source` is indexed at `source\[i - 4\]`/, error.message)
    assert_match(/cannot start at 2/, error.message)
  end

  # The extent says which way the loop runs, and the kernel runs it -- both
  # ways are meanings, and each is the one the same Ruby loop has.  Reading
  # ahead of the cell being written propagates downward and not upward, which
  # is a fact about the answer rather than a reason to refuse one of them.
  def test_a_captured_offset_runs_the_direction_it_is_given
    n = 12
    window = 3
    [(0...(n - window)).to_a, (n - window - 1).step(0, -1).to_a].each do |order|
      values = CArray.double(n).seq!(1.0)
      extent = order.first < order.last ? (0...(n - window)) :
                                          (n - window - 1).step(0, -1)
      CArray.jit_for(extent) { |i| values[i] = values[i + window] * 2.0 }

      expected = (1..n).map(&:to_f)
      order.each { |i| expected[i] = expected[i + window] * 2.0 }
      assert_equal(expected, values.to_a, "order #{order.first}..#{order.last}")
    end
  end

  # An offset that comes out zero reads the cell it writes, which is no reach
  # at all -- the same as a literal 0.
  def test_a_captured_offset_of_zero
    values = CArray.double(6).seq!(1.0)
    shift = 0
    CArray.jit_for(6) { |i| values[i] = values[i + shift] + 1.0 }
    assert_equal((2..7).map(&:to_f), values.to_a)
  end

end
