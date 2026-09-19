require_relative "test_helper"

# The pieces an algorithm needs beyond arithmetic: compound conditions,
# absolute value, the rounding family, powers, and Math's constants.  Each is
# checked against what Ruby computes, because each is only worth having if it
# agrees.
class TestPrimitives < Minitest::Test

  VALUES = [-2.5, -1.0, 0.0, 0.5, 2.5, 3.7].freeze

  def sample
    array = CArray.double(VALUES.size)
    VALUES.each_with_index { |value, index| array[index] = value }
    array
  end

  def assert_matches_ruby (label)
    source = sample
    result = CArray.double(VALUES.size)
    yield(source, result)
    VALUES.each_with_index do |value, index|
      assert_bits_equal(Float(compute(value)), result[index], "#{label}, cell #{index}")
    end
  end

  def compute (value)
    @formula.call(value)
  end

  def check (label, formula)
    @formula = formula
    assert_matches_ruby(label) { |source, result| yield(source, result) }
  end

  def test_absolute_value
    check("abs", ->(v) { v.abs }) { |a, out|
      CArray.jit_for(VALUES.size) { |i| out[i] = a[i].abs } }
  end

  # An integer's magnitude is an integer, and has its own spelling in C.
  # INT64_MIN has none in an int64, and wraps to itself as every other int64
  # overflow does.
  def test_absolute_value_of_an_integer
    values = CArray.int64(5) { |i| i - 2 }
    values[0] = -2**63
    result = CArray.int64(5)
    CArray.jit_for(5) { |i| result[i] = values[i].abs }
    assert_equal([-2**63, 1, 0, 1, 2], result.to_a)
    small = CArray.int32(3) { |i| i - 1 }
    mapped = CArray.jit_map { small.abs }
    assert_equal([1, 0, 1], mapped.to_a)
    f = CArray.jit_function("int64_t (*)(int64_t)") { |x| x.abs }
    assert_equal(7, f.call(-7))
  end

  # Float#floor and friends hand back an Integer in Ruby, and do here too.
  def test_rounding_family
    check("floor", ->(v) { v.floor }) { |a, out|
      CArray.jit_for(VALUES.size) { |i| out[i] = a[i].floor } }
    check("ceil", ->(v) { v.ceil }) { |a, out|
      CArray.jit_for(VALUES.size) { |i| out[i] = a[i].ceil } }
    check("round", ->(v) { v.round }) { |a, out|
      CArray.jit_for(VALUES.size) { |i| out[i] = a[i].round } }
    check("truncate", ->(v) { v.truncate }) { |a, out|
      CArray.jit_for(VALUES.size) { |i| out[i] = a[i].truncate } }
    check("to_i", ->(v) { v.to_i }) { |a, out|
      CArray.jit_for(VALUES.size) { |i| out[i] = a[i].to_i } }
  end

  # The Integer Ruby answers is exact however large, so a float cell gets it
  # whole: 1e20.floor is 1e20, not the int64 it would have been cast to.
  # Where there is no Integer -- a NaN, an infinity -- Ruby raises, and
  # where there is one an int64 cannot hold, storing it does.
  def test_rounding_past_int64_and_through_nothing
    values = CArray.double(4)
    [1e20, -1e20, 2.5, -2.5].each_with_index { |v, i| values[i] = v }
    into_float = CArray.double(4)
    CArray.jit_for(4) { |i| into_float[i] = values[i].floor }
    assert_equal(values.to_a.map { |v| v.floor.to_f }, into_float.to_a)
    scaled = CArray.double(4)
    CArray.jit_for(4) { |i| scaled[i] = values[i].round * 0.5 }
    assert_equal(values.to_a.map { |v| v.round * 0.5 }, scaled.to_a)
    into_int = CArray.int64(4)
    assert_raises(RangeError) do
      CArray.jit_for(4) { |i| into_int[i] = values[i].floor }
    end
    odd = CArray.double(3)
    odd[0] = Float::NAN; odd[1] = Float::INFINITY; odd[2] = -Float::INFINITY
    ["NaN", "Infinity", "-Infinity"].each_with_index do |message, k|
      error = assert_raises(FloatDomainError) do
        CArray.jit_for(1) { |i| into_float[i] = odd[i + k].ceil }
      end
      assert_equal(message, error.message)
    end
    f = CArray.jit_function("double (*)(double)") { |x| x.truncate }
    assert_equal(1e20, f.call(1e20))
    assert_raises(FloatDomainError) { f.call(Float::NAN) }
  end

  def test_float_power
    check("** 2.0", ->(v) { v ** 2.0 }) { |a, out|
      CArray.jit_for(VALUES.size) { |i| out[i] = a[i] ** 2.0 } }
  end

  # An integer power is squared out, so it is the exact integer Ruby gives
  # rather than pow's double.
  def test_integer_power
    values = CArray.int64(5)
    result = CArray.int64(5)
    5.times { |i| values[i] = i - 2 }
    CArray.jit_for(5) { |i| result[i] = values[i] ** 3 }
    assert_equal([-8, -1, 0, 1, 8], result.to_a)
  end

  def test_an_integer_raised_to_a_variable_power_is_refused
    values = CArray.int64(4)
    exponent = 3
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| values[i] = values[i] ** exponent }
    end
    assert_match(/overflows int64 where Ruby would not/, error.message)
  end

  def test_a_negative_exponent_is_refused
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| values[i] = values[i] ** -1 }
    end
    assert_match(/Rational in Ruby/, error.message)
  end

  def test_math_constants
    check("Math::PI", ->(v) { v * Math::PI }) { |a, out|
      CArray.jit_for(VALUES.size) { |i| out[i] = a[i] * Math::PI } }
    check("Math::E", ->(v) { v * Math::E }) { |a, out|
      CArray.jit_for(VALUES.size) { |i| out[i] = a[i] * Math::E } }
  end

  def test_compound_conditions
    source = sample
    result = CArray.int64(VALUES.size)
    CArray.jit_for(VALUES.size) { |i|
      result[i] = (source[i] > -1.5 && source[i] < 2.6) ? 1 : 0
    }
    assert_equal(VALUES.map { |v| (v > -1.5 && v < 2.6) ? 1 : 0 }, result.to_a)

    CArray.jit_for(VALUES.size) { |i|
      result[i] = (source[i] < -1.5 || source[i] > 2.6) ? 1 : 0
    }
    assert_equal(VALUES.map { |v| (v < -1.5 || v > 2.6) ? 1 : 0 }, result.to_a)

    CArray.jit_for(VALUES.size) { |i| result[i] = (!(source[i] > 0.0)) ? 1 : 0 }
    assert_equal(VALUES.map { |v| (!(v > 0.0)) ? 1 : 0 }, result.to_a)
  end

  def test_logic_on_numbers_is_refused
    refuse("->(i) { a[i] = 1.0 if a[i] && a[i] }", /combines comparisons, not numbers/)
  end

  # Both spellings ask the same question, and Ruby lets both be written.
  def test_undef_compares_either_way_round
    values = CArray.double(4).seq!
    values[1] = UNDEF
    result = CArray.double(4)
    CArray.jit_for(4) { |i| result[i] = (UNDEF == values[i]) ? -1.0 : values[i] }
    assert_equal([0.0, -1.0, 2.0, 3.0], result.to_a)
  end

  # A Ruby local holds whatever it was last assigned, and its type can change
  # along the way.  No single C variable is both, so each type gets one of its
  # own -- and the reads in between have to resolve to the right one.
  def test_a_local_that_changes_type
    result = CArray.double(3)
    CArray.jit_for(3) { |i|
      x = 5
      y = x / 2        # an integer division, as in Ruby
      x = 1.5
      result[i] = y + x
    }
    expected = begin
      x = 5
      y = x / 2
      x = 1.5
      y + x
    end
    assert_bits_equal(Float(expected), result[0])
  end

  def test_a_retyped_local_gets_its_own_c_variable
    kernel = compile_kernel("->(i) { x = 5; y = x / 2; x = 1.5; a[i] = y + x }")
    assert_includes(kernel.c_source, "int64_t x;")
    assert_includes(kernel.c_source, "double x__2;")
    assert_includes(kernel.c_source, "int64_t y;",
                    "the division reads the integer binding")
  end

  def test_reassignment_at_the_same_type_reuses_the_variable
    kernel = compile_kernel("->(i) { w = 1.0; w = w * 2.0; a[i] = w }")
    refute_includes(kernel.c_source, "w__2")
  end

  def test_a_local_bound_to_different_types_in_two_branches
    result = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i|
        if i > 0
          w = 1
        else
          w = 1.5
        end
        result[i] = w
      }
    end
    assert_match(/`w` is read before it is assigned/, error.message)
  end

  def test_an_unknown_constant_is_refused
    refuse("->(i) { a[i] = Math::TAU }", /unsupported constant Math::TAU/)
  end

  # `%` floors with `/`: the remainder takes the sign of the divisor, where
  # C's `%` and fmod take the sign of the dividend.  Mirrors CArray's own
  # `:mod` kernel.
  def test_integer_modulo_floors
    pairs = [[7, 3], [-7, 3], [7, -3], [-7, -3], [6, 3], [-6, 3], [0, 5]]
    left = CArray.int64(pairs.size) { |i| pairs[i][0] }
    right = CArray.int64(pairs.size) { |i| pairs[i][1] }
    result = CArray.int64(pairs.size)
    CArray.jit_for(pairs.size) { |i| result[i] = left[i] % right[i] }
    assert_equal(pairs.map { |x, y| x % y }, result.to_a)
    assert_equal((left % right).to_a, result.to_a)
  end

  def test_float_modulo_floors
    pairs = [[7.5, 3.0], [-7.5, 3.0], [7.5, -3.0], [-7.5, -3.0], [6.0, 3.0]]
    left = CArray.double(pairs.size) { |i| pairs[i][0] }
    right = CArray.double(pairs.size) { |i| pairs[i][1] }
    result = CArray.double(pairs.size)
    CArray.jit_for(pairs.size) { |i| result[i] = left[i] % right[i] }
    assert_equal(pairs.map { |x, y| x % y }, result.to_a)
    assert_equal((left % right).to_a, result.to_a)
  end

  # A zero remainder takes the divisor's sign, so the rule holds without an
  # exception.  Ruby leaves it negative; CArray does not, and this follows
  # CArray, whose kernel this mirrors.
  def test_a_zero_remainder_takes_the_divisors_sign
    left = CArray.double(1) { |i| -6.0 }
    right = CArray.double(1) { |i| 3.0 }
    result = CArray.double(1)
    CArray.jit_for(1) { |i| result[i] = left[i] % right[i] }
    assert_equal((left % right)[0].to_s, result[0].to_s)
    assert_equal("0.0", result[0].to_s)
    assert_equal("-0.0", (-6.0 % 3.0).to_s, "which is not what Ruby gives")
  end

  def test_integer_modulo_by_zero_is_reported
    left = CArray.int64(2).seq!(1)
    right = CArray.int64(2)
    result = CArray.int64(2)
    assert_raises(ZeroDivisionError) do
      CArray.jit_for(2) { |i| result[i] = left[i] % right[i] }
    end
  end

end
