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

  # ---------- a captured Integer, and which width it travels in ----------
  #
  # Ruby's Integer has no width, so a capture's value is what decides one:
  # int64 while it fits, uint64 above that.  It is the only thing about a
  # capture the value decides, and it is sound because the value is in the
  # kernel's cache key -- `5` and `2**63 + 5` are two kernels.
  #
  # Before that, a capture above 2**63 was packed into the int64 slot and read
  # back as a negative number.  Addition and multiplication survived it, two's
  # complement being what it is; division, comparison and the conversion to a
  # double did not, and said nothing.

  def test_a_captured_integer_above_int64_is_carried_whole
    big = 2**64 - 1
    quotient = CArray.uint64(1)
    CArray.jit_for(1) { |i| quotient[i] = big / 3 }
    assert_equal(big / 3, quotient[0], "the quotient Ruby gives")

    marks = CArray.boolean(1)
    CArray.jit_for(1) { |i| marks[i] = big > 100 }
    assert_equal([true], marks.to_a, "`big > 100` is true, as it is in Ruby")

    real = CArray.float64(1)
    CArray.jit_for(1) { |i| real[i] = big * 1.0 }
    assert_bits_equal(big * 1.0, real[0])
  end

  # The same source, twice, with the width the value asks for each time -- and
  # the second kernel is a second kernel rather than the first one handed back.
  def test_a_captured_integers_width_follows_its_value
    [[3, 3 / 3], [2**63 + 3, (2**63 + 3) / 3]].each do |value, expected|
      out = CArray.uint64(1)
      kernel = CArray.jit_for(1) { |i| out[i] = value / 3 }
      assert_equal(expected, out[0], "#{value} / 3")
      wanted = value > 2**63 - 1 ? /const uint64_t value = \(uint64_t\) integers\[0\]/
                                 : /const int64_t value = integers\[0\]/
      assert_match(wanted, kernel.c_source, "how #{value} arrives")
    end
  end

  # Both widths at once, beside an extent the kernel reads at run time -- the
  # three of them share the integers buffer, and the slots have to line up
  # between what the caller packs and what the C reads.  A scatter is what
  # asks for the extent.
  def test_a_captured_uint64_travels_beside_a_signed_integer
    big = 2**63 + 5
    small = 7
    bin = CArray.int32(4) { |i| i % 2 }
    counts = CArray.uint64(2)
    kernel = CArray.jit_for(4) { |i|
      counts[bin[i]] = counts[bin[i]] + (big / 3 + small)
    }
    assert_equal([(2 * (big / 3 + small)) % 2**64] * 2, counts.to_a)
    # The order, said out loud, because it is the one thing the caller and the
    # C have to agree about and neither can see the other doing it.
    assert_match(/const int64_t small = integers\[0\];/, kernel.c_source)
    assert_match(/const uint64_t big = \(uint64_t\) integers\[1\];/,
                 kernel.c_source)
    assert_match(/const int64_t counts_n0 = integers\[2\];/, kernel.c_source)
  end

  # The other loop packs the same buffer, so it carries the same capture.
  def test_a_captured_uint64_reaches_the_swept_loop
    big = 2**64 - 1
    out = CArray.uint64(3)
    CArray.jit_each { out = big / 3 }
    assert_equal([big / 3] * 3, out.to_a)
  end

  # Meeting an integer is where it stops, and CArray is why.  A bare Ruby
  # Integer is absorbed -- it takes the other side's width rather than widening
  # it, which is what keeps `f32 * 2.0` a float32 -- and this value came from
  # no width at all.  CArray refuses the same expression whatever the array's
  # own type is, `u + 2**63` raising `bignum too big to convert into 'long
  # long'` over a uint64 array as over an int64 one, so this refuses it too
  # rather than answering beside it.
  def test_a_captured_uint64_meeting_an_integer_is_refused
    big = 2**64 - 1
    out = CArray.uint64(1)
    [[CArray.int64(1) { 3 }, "int64"], [CArray.uint64(1) { 3 }, "uint64"]].each do |divisor, type|
      error = assert_raises(CArray::JIT::Unsupported, "over a #{type} array") do
        CArray.jit_for(1) { |i| out[i] = big / divisor[i] }
      end
      assert_match(/captured Integer above 2\*\*63-1/, error.message)
      assert_match(/CScalar\.uint64\(\) \{ big \}/, error.message,
                   "the message names the way through")
    end

    # And that way through is a one-cell array, so it meets the other array as
    # an array does -- which is CArray's own answer to the same expression.
    scalar = CScalar.uint64() { big }
    divisor = CArray.uint64(1) { 3 }
    CArray.jit_for(1) { |i| out[i] = scalar / divisor[i] }
    assert_equal(big / 3, out[0])
  end

  # A Float or a Complex on the other side is not the same question: the wider
  # kind wins, no width is being handed to the capture, and CArray converts it
  # the same way.
  def test_a_captured_uint64_still_meets_a_float_and_a_complex
    big = 2**64 - 1
    scale = CArray.float32(1) { 2.0 }
    real = CArray.float32(1)
    CArray.jit_for(1) { |i| real[i] = scale[i] * big }
    assert_bits_equal((scale * CScalar.uint64() { big })[0], real[0])

    turn = CArray.cmplx128(1) { Complex(1, 2) }
    spun = CArray.cmplx128(1)
    CArray.jit_for(1) { |i| spun[i] = turn[i] * big }
    assert_bits_equal((turn * CScalar.uint64() { big })[0], spun[0])
  end

  # An accumulator is the same refusal reached from the other side: `total`
  # carries a width by the second pass, and the capture meets it.
  def test_a_captured_uint64_in_an_accumulator_is_refused
    big = 2**64 - 1
    out = CArray.uint64(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i|
        total = 0
        (0...2).each { |j| total = total + big }
        out[i] = total
      }
    end
    assert_match(/captured Integer above 2\*\*63-1/, error.message)

    # With the width said once, the loop is the one the uint64 section above
    # is about: a CScalar seeds the accumulator and another carries the value.
    value = CScalar.uint64() { big }
    seed = CScalar.uint64() { 0 }
    CArray.jit_for(1) { |i|
      total = seed
      (0...2).each { |j| total = total + value }
      out[i] = total
    }
    assert_equal((2 * big) % 2**64, out[0])
  end

  # And a value neither width holds is refused where the capture is read.
  # `pack("q")` would have taken it modulo the width and handed back a number
  # nobody wrote -- 2**64 arriving as a zero.
  def test_a_captured_integer_wider_than_uint64_is_refused
    out = CArray.uint64(1)
    [2**64, -(2**63) - 1].each do |value|
      error = assert_raises(CArray::JIT::Unsupported) do
        CArray.jit_for(1) { |i| out[i] = value + 1 }
      end
      assert_match(/outside the integers a kernel computes in/, error.message,
                   "#{value} is not one")
    end
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
