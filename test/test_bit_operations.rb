require_relative "test_helper"

# Bit operators, and the integer widths they are usually reached for.
#
# Where Ruby's Integer is unbounded and C's is not, the kernel follows C --
# and so does CArray, whose own `<<` compiles to the same C shift.  So the
# reference for the edges is CArray's operator rather than plain Ruby, and
# these tests check against it.
class TestBitOperations < Minitest::Test

  def test_and_or_xor_match_ruby
    flags = CArray.int32(6) { |i| i * 37 }
    result = CArray.int32(6)
    mask = 0b1010
    CArray.jit_for(6) { |i| result[i] = (flags[i] & mask) | (flags[i] ^ 255) }
    assert_equal((0...6).map { |i| (flags[i] & mask) | (flags[i] ^ 255) },
                 result.to_a)
  end

  def test_not_and_shifts_match_ruby_in_range
    flags = CArray.int32(6) { |i| i * 37 }
    result = CArray.int32(6)
    CArray.jit_for(6) { |i| result[i] = ~flags[i] << 1 | (flags[i] >> 2) }
    assert_equal((0...6).map { |i| ~flags[i] << 1 | (flags[i] >> 2) },
                 result.to_a)
  end

  def test_a_shift_count_may_come_from_a_cell
    values = CArray.int64(6) { |i| 1 }
    counts = CArray.int64(6) { |i| i }
    result = CArray.int64(6)
    CArray.jit_for(6) { |i| result[i] = values[i] << counts[i] }
    assert_equal((0...6).map { |i| values[i] << counts[i] }, result.to_a)
  end

  # Past the width of the type, C takes the count modulo the width and Ruby
  # keeps counting.  CArray's own shift is the C one, and this agrees with it.
  def test_a_shift_past_the_width_agrees_with_carray
    values = CArray.int64(4) { |i| [1, -1, 255, -256][i] }
    result = CArray.int64(4)
    [63, 64, 65].each do |count|
      CArray.jit_for(4) { |i| result[i] = values[i] << count }
      assert_equal((values << count).to_a, result.to_a,
                   "<< #{count} is what CArray's own operator gives")
    end
  end

  def test_integer_overflow_agrees_with_carray
    values = CArray.int64(2) { |i| 2 ** 62 }
    result = CArray.int64(2)
    CArray.jit_for(2) { |i| result[i] = values[i] * 4 }
    assert_equal((values * 4).to_a, result.to_a)
    assert_equal([0, 0], result.to_a, "which is C's answer, not Ruby's")
  end

  def test_booleans_join_with_and_or_xor
    left = CArray.boolean(6) { |i| i.even? ? 1 : 0 }
    right = CArray.boolean(6) { |i| i < 3 ? 1 : 0 }
    result = CArray.boolean(6)
    CArray.jit_for(6) { |i| result[i] = left[i] & right[i] }
    assert_equal((0...6).map { |i| left[i] & right[i] }, result.to_a)
    CArray.jit_for(6) { |i| result[i] = left[i] ^ right[i] }
    assert_equal((0...6).map { |i| left[i] ^ right[i] }, result.to_a)
  end

  def test_a_float_does_not_take_a_bit_operator
    values = CArray.double(4).seq!
    result = CArray.int32(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| result[i] = values[i] & 1 }
    end
    assert_match(/joins two integers or two booleans/, error.message)
  end

  # The widths images and flags actually come in.
  def test_unsigned_arrays
    { 8 => CArray.uint8(5), 16 => CArray.uint16(5), 32 => CArray.uint32(5) }
      .each do |width, source|
      5.times { |i| source[i] = i * 7 }
      result = source.template
      CArray.jit_for(5) { |i| result[i] = source[i] * 3 + 1 }

      reference = source.template
      5.times { |i| reference[i] = source[i] * 3 + 1 }
      assert_equal(reference.to_a, result.to_a, "uint#{width}")
    end
  end

  def test_an_unsigned_store_wraps_as_carray_wraps
    source = CArray.uint8(4) { |i| 200 + i * 20 }
    result = CArray.uint8(4)
    CArray.jit_for(4) { |i| result[i] = source[i] + 60 }

    reference = CArray.uint8(4)
    4.times { |i| reference[i] = source[i] + 60 }
    assert_equal(reference.to_a, result.to_a)
  end

  # uint64 is the width that cannot be folded into the int64 the other
  # integers compute in -- it carries values above 2**63 -- so it computes in
  # a type of its own.  What that type has to answer is CArray, since Ruby's
  # Integer has no width to have an opinion about: every one of these is
  # checked against the same expression over the arrays.
  def test_uint64_computes_as_carray_does
    max = 2**64 - 1
    u = CArray.uint64(4) { |i| [max, 10, 2**63, 7][i] }
    v = CArray.uint64(4) { |i| [1, 3, 2, 2][i] }
    out = CArray.uint64(4)

    # Written out one by one because a kernel reads the block where it was
    # written: there is no loop that could stand in for these.
    CArray.jit_each { out = u + v };   assert_equal((u + v).to_a, out.to_a, "+")
    CArray.jit_each { out = u - v };   assert_equal((u - v).to_a, out.to_a, "-")
    CArray.jit_each { out = u * v };   assert_equal((u * v).to_a, out.to_a, "*")
    CArray.jit_each { out = u / v };   assert_equal((u / v).to_a, out.to_a, "/")
    CArray.jit_each { out = u % v };   assert_equal((u % v).to_a, out.to_a, "%")
    CArray.jit_each { out = u & v };   assert_equal((u & v).to_a, out.to_a, "&")
    CArray.jit_each { out = u | v };   assert_equal((u | v).to_a, out.to_a, "|")
    CArray.jit_each { out = u ^ v };   assert_equal((u ^ v).to_a, out.to_a, "^")
    CArray.jit_each { out = u >> v };  assert_equal((u >> v).to_a, out.to_a, ">>")
    CArray.jit_each { out = v ** 3 };  assert_equal((v ** 3).to_a, out.to_a, "**")
    CArray.jit_each { out = -u };      assert_equal((-u).to_a, out.to_a, "-@")
    CArray.jit_each { out = u.abs };   assert_equal(u.to_a, out.to_a, "abs")

    marks = CArray.boolean(4)
    CArray.jit_each { marks = u > v }
    assert_equal((u > v).to_a, marks.to_a, ">")
  end

  # The value that made the old refusal right: int64 cannot hold it, so a
  # kernel that folded uint64 into int64 would have had to wrap it.
  def test_a_uint64_cell_survives_above_2_63
    max = 2**64 - 1
    source = CArray.uint64(1) { max }
    out = CArray.uint64(1)
    CArray.jit_each { out = source }
    assert_equal(max, out[0])
  end

  # Mixed with the other numeric types, the result type is CArray's: an
  # int64 operand joins uint64 rather than the other way round, and a float
  # takes both out of the integers.
  def test_uint64_mixes_as_carray_mixes
    u = CArray.uint64(2) { |i| [2**64 - 1, 5][i] }
    i = CArray.int64(2) { |k| [-1, 3][k] }
    f = CArray.float64(2).seq!(1.0)

    unsigned = CArray.uint64(2)
    CArray.jit_each { unsigned = u + i }
    assert_equal((u + i).to_a, unsigned.to_a, "uint64 + int64")

    real = CArray.float64(2)
    CArray.jit_each { real = u * f }
    assert_equal((u * f).to_a, real.to_a, "uint64 * float64")
  end

  # `%d` of a uint64_t above 2**63 would print a negative number, so the
  # signed conversion becomes its unsigned twin and prints what Ruby prints.
  def test_a_uint64_prints_the_value_it_holds
    max = 2**64 - 1
    source = CArray.uint64(1) { max }
    out = CArray.uint64(1)
    printed = capture_subprocess_io do
      CArray.jit_for(1) { |i| printf("%d\n", source[i]); out[i] = source[i] }
    end.first
    assert_equal("#{max}\n", printed)
  end

  # `floor`, `ceil`, `round` and `to_i` name int64 as what they produce, which
  # is right for a Float and wrong for a uint64 -- Ruby's Integer#floor is the
  # number itself, and a value above 2**63 would come back saturated.
  def test_rounding_a_uint64_is_the_number_itself
    max = 2**64 - 1
    source = CArray.uint64(1) { max }
    out = CArray.uint64(1)
    CArray.jit_each { out = source.floor }
    assert_equal(max, out[0], "floor")
    CArray.jit_each { out = source.ceil }
    assert_equal(max, out[0], "ceil")
    CArray.jit_each { out = source.round }
    assert_equal(max, out[0], "round")
  end

  # An accumulator started at `0` is an int64 and comes back round a uint64,
  # which one C variable cannot be.  The refusal says which two types those
  # are -- both would read as "an Integer" if uint64 borrowed Ruby's name --
  # and a CScalar is what gives the accumulator the type instead.
  def test_a_uint64_accumulator_says_what_it_needs
    source = CArray.uint64(2) { |i| [2**64 - 1, 5][i] }
    out = CArray.uint64(1)

    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i|
        total = 0
        (0...2).each { |j| total = total + source[j] }
        out[i] = total
      }
    end
    assert_match(/as an Integer and comes back round as a uint64/, error.message)

    seed = CScalar.uint64() { 0 }
    CArray.jit_for(1) { |i|
      total = seed
      (0...2).each { |j| total = total + source[j] }
      out[i] = total
    }
    assert_equal((2**64 - 1 + 5) % 2**64, out[0])
  end

  def test_a_uint64_divisor_of_zero_is_reported
    source = CArray.uint64(1) { 10 }
    zero = CArray.uint64(1) { 0 }
    out = CArray.uint64(1)
    assert_raises(ZeroDivisionError) do
      CArray.jit_each { out = source / zero }
    end
  end

end
