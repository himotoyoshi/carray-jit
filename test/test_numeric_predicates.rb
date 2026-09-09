require_relative "test_helper"

# `x.nan?` and `x.finite?` are the guards numerical code is written with, and
# each answers what Ruby answers -- including by refusing where Ruby raises.
class TestNumericPredicates < Minitest::Test

  VALUES = [1.0, 0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0, -2.5].freeze

  def test_nan_and_finite_on_floats
    values = CArray.double(VALUES.size) { |i| VALUES[i] }
    missing = CArray.boolean(VALUES.size)
    bounded = CArray.boolean(VALUES.size)

    CArray.jit_for(VALUES.size) { |i|
      missing[i] = values[i].nan?
      bounded[i] = values[i].finite?
    }

    assert_equal(VALUES.map(&:nan?), missing.to_a)
    assert_equal(VALUES.map(&:finite?), bounded.to_a)
  end

  def test_on_float32
    values = CArray.float32(3) { |i| VALUES[i] }
    missing = CArray.boolean(3)
    CArray.jit_for(3) { |i| missing[i] = values[i].nan? }
    assert_equal(VALUES.first(3).map(&:nan?), missing.to_a)
  end

  # As a guard, which is what it is for: the branch decides and nothing
  # divides by a number that is not there.
  def test_as_a_condition
    values = CArray.double(VALUES.size) { |i| VALUES[i] }
    out = CArray.double(VALUES.size)
    CArray.jit_for(VALUES.size) { |i|
      if values[i].finite?
        out[i] = values[i] * 2.0
      else
        out[i] = 0.0
      end
    }
    expected = VALUES.map { |v| v.finite? ? v * 2.0 : 0.0 }
    assert_equal(expected, out.to_a)
  end

  # `Integer#finite?` is true, whatever the integer, and the kernel says the
  # same rather than refusing a question Ruby answers.
  def test_finite_on_integers
    values = CArray.int32(3) { |i| i - 1 }
    bounded = CArray.boolean(3)
    CArray.jit_for(3) { |i| bounded[i] = values[i].finite? }
    assert_equal([true, true, true], bounded.to_a)
  end

  # `Complex#finite?` is both parts finite, which is what Ruby asks and not
  # what `isfinite` of a complex would mean.
  def test_finite_on_complex
    numbers = [Complex(1.0, 2.0), Complex(1.0 / 0.0, 2.0),
               Complex(1.0, 0.0 / 0.0)]
    [:cmplx128, :cmplx64].each do |type|
      values = CArray.new(type, [numbers.size]) { |i| numbers[i] }
      bounded = CArray.boolean(numbers.size)
      CArray.jit_for(numbers.size) { |i| bounded[i] = values[i].finite? }
      assert_equal(numbers.map(&:finite?), bounded.to_a, type.to_s)
    end
  end

  # A value is read to ask about it, so a missing cell carries into the
  # answer, as it does anywhere a value is read.
  def test_a_missing_cell
    values = CArray.double(3) { 1.0 }
    values[1] = UNDEF
    missing = CArray.boolean(3)
    CArray.jit_for(3) { |i| missing[i] = values[i].nan? }
    assert_equal(false, missing[0])
    assert_equal(UNDEF, missing[1])
    assert_equal(false, missing[2])
  end

  def test_nan_is_refused_for_an_integer
    values = CArray.int32(3)
    out = CArray.boolean(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| out[i] = values[i].nan? }
    end
    assert_match(/`nan\?` is a Float's question/, error.message)
    assert_match(/an Integer has no method by that name/, error.message)
  end

  def test_nan_is_refused_for_a_complex
    values = CArray.cmplx128(3)
    out = CArray.boolean(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| out[i] = values[i].nan? }
    end
    assert_match(/a Complex has no method by that name/, error.message)
  end

  # `infinite?` answers nil, 1 or -1 rather than true or false, and a kernel
  # has no nil, so it is refused with the comparison to write instead.
  def test_infinite_is_refused
    values = CArray.double(3)
    out = CArray.boolean(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| out[i] = values[i].infinite? }
    end
    assert_match(/answers nil, 1 or -1 in Ruby/, error.message)
    assert_match(/`x\.abs == Float::INFINITY`/, error.message)
  end

  # And the comparison the message names does answer, so the advice is
  # advice that works.
  def test_the_comparison_the_message_names
    values = CArray.double(VALUES.size) { |i| VALUES[i] }
    unbounded = CArray.boolean(VALUES.size)
    CArray.jit_for(VALUES.size) { |i| unbounded[i] = values[i].abs == Float::INFINITY }
    assert_equal(VALUES.map { |v| !v.infinite?.nil? }, unbounded.to_a)
  end

end
