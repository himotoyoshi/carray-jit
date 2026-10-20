require_relative "test_helper"

class TestTypes < Minitest::Test

  # `wy/i` divides a Float by the Integer loop index; Ruby promotes, so the
  # generated C has to cast rather than divide as integers.
  def test_float_divided_by_index_promotes
    kernel = compile_kernel("->(i) { a[i] = a[i-1] / i }")
    assert_includes(kernel.c_source, "(double)i")
    refute_includes(kernel.c_source, "carray_jit_floor_divide")
  end

  def test_integer_division_is_floored
    kernel = compile_kernel("->(i) { a[i] = a[i-1] / n }",
                            arrays: { :a => "int64" }, scalars: { :n => 3 })
    assert_includes(kernel.c_source, "carray_jit_floor_divide")

    # Negative operands are where C and Ruby part company: Ruby floors and
    # CArray follows it, while C truncates toward zero.
    values = CArray.int64(8)
    values[0] = -7
    n = 3
    CArray.jit_for(1...8) { |i| values[i] = values[i-1] / n }

    expected = Array.new(8, 0)
    expected[0] = -7
    (1...8).each { |i| expected[i] = expected[i-1] / n }
    assert_equal(expected, values.to_a)
  end

  # Flooring by a positive power of two is just an arithmetic shift, which
  # also happens to be cheaper than the truncating divide C would emit.
  def test_power_of_two_division_becomes_a_shift
    kernel = compile_kernel("->(i) { a[i] = a[i-1] / 8 }",
                            arrays: { :a => "int64" })
    assert_includes(kernel.c_source, ">> 3")
    refute_includes(kernel.c_source, "carray_jit_floor_divide")

    values = CArray.int64(10)
    values[0] = -100
    CArray.jit_for(1...10) { |i| values[i] = values[i-1] / 8 }
    expected = Array.new(10, 0)
    expected[0] = -100
    (1...10).each { |i| expected[i] = expected[i-1] / 8 }
    assert_equal(expected, values.to_a)
  end

  def test_integer_division_by_zero_raises
    values = CArray.int64(4)
    values[0] = 1
    n = 0
    assert_raises(ZeroDivisionError) do
      CArray.jit_for(1...4) { |i| values[i] = values[i-1] / n }
    end
  end

  def test_float32_storage_computes_in_float
    kernel = compile_kernel("->(i) { a[i] = a[i-1] * 0.5 }",
                            arrays: { :a => "float32" })
    assert_includes(kernel.c_source, "(float *)")
    refute_includes(kernel.c_source, "(double)",
                    "a float32 cell is not widened to be worked on")
    assert_includes(kernel.c_source, "0.5f",
                    "and the literal it meets takes the same width, since one " \
                    "double in the expression would take all of it back")
  end

  def test_arrays_of_different_types_in_one_kernel
    doubles = CArray.double(6).seq!
    integers = CArray.int64(6)
    CArray.jit_for(0...6) { |i| integers[i] = doubles[i] * 2 }
    assert_equal([0, 2, 4, 6, 8, 10], integers.to_a)
  end

  def test_capture_of_an_unsupported_class_is_refused
    error = assert_raises(CArray::JIT::Unsupported) do
      compile_kernel("->(i) { a[i] = s * a[i] }", scalars: { :s => "text" })
    end
    assert_match(/Float, Integer or Complex/, error.message)
  end

  def test_scalar_and_array_captures_are_told_apart
    factor = 0.25
    offset = 2
    values = CArray.double(8)
    values[0] = 1.0
    kernel = CArray.jit_for(1...8) { |i| values[i] = factor * values[i-1] + offset }

    assert_equal([:values], kernel.arrays)
    assert_equal([:factor], kernel.reals)
    assert_equal([:offset], kernel.integers)
  end

  def test_storage_type_mismatch_is_refused
    kernel = compile_kernel("->(i) { a[i] = a[i-1] * 2.0 }")
    error = assert_raises(CArray::JIT::Unsupported) do
      kernel.call({ :a => CArray.float(4) }, {}, [[1, 4, 1]])
    end
    assert_match(/float64/, error.message)
  end

  def test_object_array_is_refused
    values = CArray.object(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(0...4) { |i| values[i] = 1.0 }
    end
    assert_match(/data type `object`/, error.message)
  end

  # A local carried across a loop's back edge has to be one type.  `x = 2`
  # outside with `x = 1.5` inside means an integer division on the first pass
  # and a float one after, and one C variable cannot be both -- so this is
  # refused rather than compiled into whichever of the two it saw first.
  def test_a_type_that_changes_across_a_loop_is_refused
    result = CArray.double(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i|
        x = 2
        (0...3).each { |j|
          y = x / 4
          x = 1.5
          result[i] = y
        }
      }
    end
    assert_match(/`x` enters this loop as an Integer and comes back round as a Float/,
                 error.message)
  end

  def test_one_type_across_the_loop_is_accepted
    result = CArray.double(1)
    CArray.jit_for(1) { |i|
      x = 2.0
      (0...3).each { |j|
        y = x / 4
        x = 1.5
        result[i] = y
      }
    }
    x = 2.0
    y = nil
    (0...3).each { |_j| y = x / 4; x = 1.5 }
    assert_equal(y, result[0])
  end

  # A local that only lives inside the loop may still change type: it is
  # assigned before it is read on every pass, so nothing crosses the edge.
  def test_a_local_born_inside_the_loop_may_change_type
    result = CArray.double(1)
    CArray.jit_for(1) { |i|
      (0...3).each { |j|
        t = 3
        u = t / 2
        t = 1.5
        result[i] = u + t
      }
    }
    assert_equal(3 / 2 + 1.5, result[0])
  end

  # The line: the type is C's -- width, wrapping on store, bit patterns -- and
  # A float32 kernel computes in float32, which is what CArray's own
  # operators do and is not what the same loop written in Ruby does: Ruby has
  # no float32 arithmetic to fall back to, so its answer is the double one.
  # The two differ, and the kernel takes CArray's.
  def test_float32_arithmetic_happens_in_float32
    small = CArray.float32(1); small[0] = 1.0e-8
    one = CArray.float32(1); one[0] = 1.0
    result = CArray.float32(1)
    CArray.jit_for(1) { |i| result[i] = (one[i] + small[i]) - one[i] }

    assert_bits_equal(((one + small) - one)[0], result[0],
                      "CArray's own float32 operators")
    refute_equal((one[0] + small[0]) - one[0], result[0],
                 "the same loop in Ruby computes in double and keeps it")
  end

  # The integers are the other half of what used to be one rule, and they
  # stay as they were: narrowing them changes the answer and buys nothing,
  # because truncation commutes with add, subtract and multiply, so a
  # compiler narrows the wide computation by itself.
  def test_a_float32_local_takes_the_width_from_what_seeded_it
    source = CArray.float32(4).seq!(0.1, 0.017)
    out = CArray.float32(4)
    CArray.jit_for(4) { |i|
      scaled = source[i] * 0.1
      out[i] = scaled + 0.3
    }
    assert_equal((source * 0.1 + 0.3).to_a, out.to_a)
  end

  def test_narrow_integers_compute_in_int64
    left = CArray.int32(2) { |i| 2_000_000_000 }
    right = CArray.int32(2) { |i| 2_000_000_000 }
    result = CArray.int64(2)
    CArray.jit_for(2) { |i| result[i] = left[i] + right[i] }
    assert_equal([4_000_000_000, 4_000_000_000], result.to_a,
                 "int32 + int32 in C is int arithmetic, and would overflow")
    assert_equal((0...2).map { |i| left[i] + right[i] }, result.to_a)
  end

  def test_a_narrow_read_is_widened_before_the_arithmetic
    source = CArray.uint8(3) { |i| 100 + i }
    result = CArray.int64(3)
    CArray.jit_for(3) { |i| result[i] = source[i] * 1000 }
    assert_equal((0...3).map { |i| source[i] * 1000 }, result.to_a)
  end

  # What the type does decide is the store, and there C's answer is CArray's
  # conversion.  The reference converts with `to_type`, which narrows as C
  # does; `reference[0] = 300` raises RangeError since CArray 3.0.4.
  def test_the_store_wraps_as_carray_wraps
    result = CArray.int8(1)
    CArray.jit_for(1) { |i| result[i] = 300 }
    reference = CArray.int64(1) { 300 }.to_type(:int8)
    assert_equal(reference.to_a, result.to_a)
    assert_equal([44], result.to_a)
  end

  # A real stored into an integer cell keeps its integer part, as CArray's
  # store does, up to the edge of the type and not past it.
  def test_a_real_store_keeps_the_integer_part
    [[:int8,   [-128.9, 127.9, -0.5]],
     [:uint8,  [-0.9, 255.9, 7.5]],
     [:int64,  [-(2.0**63), 9.2e18, -3.7]],
     [:uint64, [2.0**64 - 2048, 0.0, 1.5]]].each do |type, values|
      source = CArray.float64(3) { values }
      result = CArray.new(type, [3])
      CArray.jit_for(3) { |i| result[i] = source[i] }
      reference = CArray.new(type, [3])
      reference[] = source
      assert_equal(reference.to_a, result.to_a, type.to_s)
    end
  end

  # And one the type has no integer for is refused as CArray refuses it.  C
  # leaves the conversion undefined, and x86 and ARM gave different numbers.
  def test_a_real_store_out_of_range_raises
    [[:int8, 128.0], [:int32, 1e20], [:int64, 2.0**63], [:uint8, -1.0],
     [:uint64, 2.0**64]].each do |type, value|
      source = CArray.float64(2) { [1.0, value] }
      result = CArray.new(type, [2])
      assert_raises(RangeError, type.to_s) do
        CArray.jit_for(2) { |i| result[i] = source[i] }
      end
      reference = CArray.new(type, [2])
      assert_raises(RangeError, type.to_s) { reference[] = source }
    end
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |value|
      source = CArray.float64(1) { [value] }
      result = CArray.int32(1)
      assert_raises(FloatDomainError, value.to_s) do
        CArray.jit_for(1) { |i| result[i] = source[i] }
      end
    end
  end

  # A float32 cell is checked at its own value: 2147483647.0 is 2**31 in
  # float, which no int32 holds.
  def test_a_float32_store_is_checked_at_its_value
    source = CArray.float32(1) { [2147483647.0] }
    result = CArray.int32(1)
    assert_raises(RangeError) do
      CArray.jit_for(1) { |i| result[i] = source[i] }
    end
  end

  # A masked cell has no value to refuse, and the element-wise form and a
  # local array are checked as an indexed write is.
  def test_the_real_store_check_reaches_every_write
    source = CArray.float64(3) { [1.0, 1e20, 2.0] }
    source[1] = UNDEF
    result = CArray.int32(3)
    CArray.jit_each { result = source }
    assert_equal([1, UNDEF, 2], result.to_a)

    wide = CArray.float64(2) { [1.0, 1e20] }
    narrow = CArray.int32(2)
    assert_raises(RangeError) { CArray.jit_each { narrow = wide } }
    out = CArray.float64(2)
    assert_raises(RangeError) do
      CArray.jit_for(2) { |i| w = CArray.int32(2); w[i] = wide[i]; out[i] = w[i] }
    end
  end

  # ---------- what a guard asks ----------

  # The sets the guards are written against are derived from one table, so
  # that a computation type added later is a type every guard already knows
  # about.  A guard carrying its own list of names is the shape that goes
  # stale silently: it keeps answering, and answers wrongly, for the type
  # nobody remembered to add to it.
  def test_the_type_sets_follow_the_one_table
    kinds = CArray::JIT::TypeAssignment::KINDS
    assert_equal(kinds.keys.select { |t| kinds[t] == :integer },
                 CArray::JIT::TypeAssignment::INTEGER_TYPES)
    assert_equal(kinds.keys.select { |t| [:integer, :real].include?(kinds[t]) },
                 CArray::JIT::TypeAssignment::REAL_TYPES)
  end

  # And a type the table has never heard of is nothing rather than something:
  # every question answers false, so a guard written as "refuse unless this is
  # a number" refuses it instead of letting it through.
  def test_an_unknown_type_answers_no_to_everything
    assignment = CArray::JIT::TypeAssignment
    [:integer?, :real?, :complex?, :boolean?, :numeric?].each do |question|
      refute(assignment.send(question, :float32), question.to_s)
    end
  end

end
