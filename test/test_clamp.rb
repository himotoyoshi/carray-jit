require_relative "test_helper"

# `x.clamp(low, high)` answers the value or whichever bound it ran past, and
# raises what Ruby raises for the two cases Ruby has no answer for.
class TestClamp < Minitest::Test

  VALUES = [-1.0, 0.25, 5.0].freeze

  def test_a_float
    values = CArray.double(3) { |i| VALUES[i] }
    out = CArray.double(3)
    CArray.jit_for(3) { |i| out[i] = values[i].clamp(0.0, 1.0) }
    assert_equal(VALUES.map { |v| v.clamp(0.0, 1.0) }, out.to_a)
  end

  def test_an_integer
    numbers = [-3, 1, 9]
    values = CArray.int32(3) { |i| numbers[i] }
    out = CArray.int32(3)
    CArray.jit_for(3) { |i| out[i] = values[i].clamp(0, 4) }
    assert_equal(numbers.map { |v| v.clamp(0, 4) }, out.to_a)
  end

  def test_a_uint64
    numbers = [0, 5, 20]
    values = CArray.uint64(3) { |i| numbers[i] }
    out = CArray.uint64(3)
    CArray.jit_for(3) { |i| out[i] = values[i].clamp(1, 10) }
    assert_equal(numbers.map { |v| v.clamp(1, 10) }, out.to_a)
  end

  # A float32 cell is a Ruby Float, as a double is, so one class runs
  # through and the answer takes the receiver's width.
  def test_a_float32_keeps_its_width
    values = CArray.float32(3) { |i| VALUES[i] }
    out = CArray.float32(3)
    CArray.jit_for(3) { |i| out[i] = values[i].clamp(0.0, 1.0) }
    assert_equal(VALUES.map { |v| v.clamp(0.0, 1.0) }, out.to_a)
  end

  def test_bounds_that_are_captured_or_read
    values = CArray.double(3) { |i| VALUES[i] }
    low, high = 0.0, 1.0
    captured = CArray.double(3)
    CArray.jit_for(3) { |i| captured[i] = values[i].clamp(low, high) }
    assert_equal(VALUES.map { |v| v.clamp(0.0, 1.0) }, captured.to_a)

    lows = CArray.double(3) { 0.0 }
    highs = CArray.double(3) { |i| i * 1.0 }
    per_cell = CArray.double(3)
    CArray.jit_for(3) { |i| per_cell[i] = values[i].clamp(lows[i], highs[i]) }
    expected = (0...3).map { |i| VALUES[i].clamp(0.0, i * 1.0) }
    assert_equal(expected, per_cell.to_a)
  end

  # Ruby raises rather than answering when the bounds are the wrong way
  # round, and so does the kernel -- with Ruby's class and Ruby's words.
  def test_bounds_the_wrong_way_round
    values = CArray.double(3) { |i| VALUES[i] }
    out = CArray.double(3)
    error = assert_raises(ArgumentError) do
      CArray.jit_for(3) { |i| out[i] = values[i].clamp(1.0, 0.0) }
    end
    in_ruby = assert_raises(ArgumentError) { 1.0.clamp(1.0, 0.0) }
    assert_equal(in_ruby.message, error.message)
  end

  # A NaN cannot be ordered, so Ruby raises ArgumentError; the class is the
  # same here, and the message names the reason rather than the value, the
  # error slot carrying a code rather than a number.
  def test_a_nan_value
    values = CArray.double(1) { 0.0 / 0.0 }
    out = CArray.double(1)
    error = assert_raises(ArgumentError) do
      CArray.jit_for(1) { |i| out[i] = values[i].clamp(0.0, 1.0) }
    end
    assert_match(/NaN/, error.message)
    assert_raises(ArgumentError) { (0.0 / 0.0).clamp(0.0, 1.0) }
  end

  def test_a_nan_bound
    values = CArray.double(1) { 1.0 }
    out = CArray.double(1)
    error = assert_raises(ArgumentError) do
      CArray.jit_for(1) { |i| out[i] = values[i].clamp(0.0 / 0.0, 1.0) }
    end
    assert_match(/NaN/, error.message)
    assert_raises(ArgumentError) { 1.0.clamp(0.0 / 0.0, 1.0) }
  end

  # A cell with no value in it does not raise, which is the rule the
  # division helpers already keep.
  def test_a_missing_cell_does_not_raise
    values = CArray.double(3) { |i| VALUES[i] }
    values[1] = UNDEF
    out = CArray.double(3)
    CArray.jit_for(3) { |i| out[i] = values[i].clamp(0.0, 1.0) }
    assert_equal(0.0, out[0])
    assert_equal(UNDEF, out[1])
    assert_equal(1.0, out[2])
  end

  # An Integer bound under a Float value is the case Ruby answers with two
  # different classes depending on the value, so it is refused.
  def test_an_integer_bound_on_a_float
    values = CArray.double(3)
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| out[i] = values[i].clamp(0, 1) }
    end
    assert_match(/a Float value and an Integer bound/, error.message)
    assert_match(/write the bounds with a decimal point/, error.message)
    # Which is what Ruby does: the class of the answer follows the value.
    assert_equal(Integer, 5.0.clamp(0, 1).class)
    assert_equal(Float, 0.5.clamp(0, 1).class)
  end

  def test_a_float_bound_on_an_integer
    values = CArray.int32(3)
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| out[i] = values[i].clamp(0.0, 1.0) }
    end
    assert_match(/an Integer value and a Float bound/, error.message)
    assert_match(/write the bounds as Integers/, error.message)
  end

  def test_the_range_form_is_refused
    values = CArray.double(3)
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| out[i] = values[i].clamp(0.0..1.0) }
    end
    assert_match(/`clamp` takes the two bounds/, error.message)
    assert_match(/the range form is not in the subset/, error.message)
  end

  def test_a_complex_is_refused
    values = CArray.cmplx128(3)
    out = CArray.cmplx128(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| out[i] = values[i].clamp(0.0, 1.0) }
    end
    assert_match(/has no meaning for a Complex/, error.message)
  end

  # In a compiled function too, where the failure reports through the flag
  # the body already reports a division by zero through.
  def test_in_a_compiled_function
    bound = CArray.jit_function("double bound(double x)") { |x|
      x.clamp(0.0, 1.0)
    }
    assert_equal(1.0, bound.call(5.0))
    assert_equal(bound.block.call(5.0), bound.call(5.0))
    assert_raises(ArgumentError) { bound.call(0.0 / 0.0) }
  end

end
