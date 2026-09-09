require_relative "test_helper"

# The kernels the gem exists for, checked against the same computation
# written as an ordinary Ruby loop.
class TestJitFor < Minitest::Test

  def test_legendre_recurrence
    x = 0.5
    n = 24
    values = CArray.double(n)
    values[0] = 1.0
    values[1] = x
    CArray.jit_for(2...n) { |i|
      w  = x * values[i-1]
      wy = w - values[i-2]
      values[i] = wy + w - wy/i
    }

    expected = Array.new(n, 0.0)
    expected[0] = 1.0
    expected[1] = x
    (2...n).each { |i|
      w = x * expected[i-1]
      wy = w - expected[i-2]
      expected[i] = wy + w - wy/i
    }
    n.times { |i| assert_bits_equal(expected[i], values[i], "cell #{i}") }
  end

  # float32 is the case that catches computing in the wrong precision.  A
  # kernel computes in the array's own type, so every step of this recurrence
  # rounds to float32 -- which is what CArray's own operators do, and is not
  # what the same loop written in Ruby does, Ruby having no float32 to
  # compute in.  The reference rounds each step by hand for that reason.
  def test_float32_computes_in_float32
    x = 0.5
    n = 24
    values = CArray.float(n)
    values[0] = 1.0
    values[1] = x
    CArray.jit_for(2...n) { |i|
      w  = x * values[i-1]
      wy = w - values[i-2]
      values[i] = wy + w - wy/i
    }

    narrow = ->(value) { [value].pack("f").unpack1("f") }
    expected = CArray.float(n)
    expected[0] = 1.0
    expected[1] = x
    (2...n).each { |i|
      w = narrow.call(x * expected[i-1])
      wy = narrow.call(w - expected[i-2])
      expected[i] = narrow.call(narrow.call(wy + w) - narrow.call(wy/i))
    }
    n.times { |i|
      assert_equal([expected[i]].pack("f"), [values[i]].pack("f"), "cell #{i}")
    }
  end

  # Reading forward means the loop has to run backward, and the extent has to
  # say so: the call site is the only place a reader sees the order, and an
  # offset typo would otherwise flip the loop silently.
  def test_a_downward_loop
    n = 16
    values = CArray.double(n)
    values[n-1] = 3.0
    CArray.jit_for((n-2).step(0, -1)) { |i| values[i] = 0.5 * values[i+1] + 1.0 }

    expected = Array.new(n, 0.0)
    expected[n-1] = 3.0
    (n-2).downto(0) { |i| expected[i] = 0.5 * expected[i+1] + 1.0 }
    n.times { |i| assert_bits_equal(expected[i], values[i], "cell #{i}") }
  end

  def test_two_dimensional_stencil
    rows, columns = 6, 7
    source = CArray.double(rows, columns).seq!
    result = CArray.double(rows, columns)
    CArray.jit_for(1...(rows-1), 1...(columns-1)) { |i, j|
      result[i, j] = 0.25 * (source[i-1, j] + source[i+1, j] +
                             source[i, j-1] + source[i, j+1])
    }

    expected = CArray.double(rows, columns)
    (1...(rows-1)).each do |i|
      (1...(columns-1)).each do |j|
        expected[i, j] = 0.25 * (source[i-1, j] + source[i+1, j] +
                                 source[i, j-1] + source[i, j+1])
      end
    end
    assert_equal(expected.to_a, result.to_a)
    assert_equal([0.0] * columns, result[0, nil].to_a, "the border stays untouched")
  end

  # One axis carries a dependency and the other does not, so they run
  # independently: j ascending because of j-1, i in any order.
  def test_dependency_on_one_axis_only
    rows, columns = 4, 6
    values = CArray.double(rows, columns)
    increments = CArray.double(rows, columns).seq!
    rows.times { |i| values[i, 0] = 1.0 }
    CArray.jit_for(0...rows, 1...columns) { |i, j|
      values[i, j] = values[i, j-1] + increments[i, j]
    }

    expected = CArray.double(rows, columns)
    rows.times do |i|
      expected[i, 0] = 1.0
      (1...columns).each { |j| expected[i, j] = expected[i, j-1] + increments[i, j] }
    end
    assert_equal(expected.to_a, values.to_a)
  end

  # An extent may be a plain count, so a whole array is jit_for(*array.dim).
  def test_extent_may_be_a_count
    values = CArray.double(3, 4)
    CArray.jit_for(*values.dim) { |i, j| values[i, j] = 1.0 * i * 10 + j }
    assert_equal([[0.0, 1.0, 2.0, 3.0],
                  [10.0, 11.0, 12.0, 13.0],
                  [20.0, 21.0, 22.0, 23.0]], values.to_a)
  end

  def test_inclusive_range
    values = CArray.double(5)
    CArray.jit_for(1..3) { |i| values[i] = 2.0 }
    assert_equal([0.0, 2.0, 2.0, 2.0, 0.0], values.to_a)
  end

  def test_empty_range_does_nothing
    values = CArray.double(4).seq!
    CArray.jit_for(2...2) { |i| values[i] = -1.0 }
    assert_equal([0.0, 1.0, 2.0, 3.0], values.to_a)
  end

  def test_math_function
    values = CArray.double(10)
    values[0] = 4.0
    CArray.jit_for(1...10) { |i| values[i] = Math.sqrt(values[i-1]) + 1.0 }

    expected = Array.new(10, 0.0)
    expected[0] = 4.0
    (1...10).each { |i| expected[i] = Math.sqrt(expected[i-1]) + 1.0 }
    10.times { |i| assert_bits_equal(expected[i], values[i], "cell #{i}") }
  end

  # `erf` and `erfc` are 1:1 with math.h -- Ruby calls those very functions
  # -- so the two agree to the bit, infinities included.
  def test_the_error_function
    inputs = [0.0, 0.5, -3.0, 1e-8, 30.0, Float::INFINITY, -Float::INFINITY]
    values = CArray.double(inputs.size) { |i| inputs[i] }
    integral = CArray.double(inputs.size)
    complement = CArray.double(inputs.size)

    CArray.jit_for(inputs.size) { |i|
      integral[i] = Math.erf(values[i])
      complement[i] = Math.erfc(values[i])
    }

    inputs.each_with_index do |x, i|
      assert_bits_equal(Math.erf(x), integral[i], "erf of #{x}")
      assert_bits_equal(Math.erfc(x), complement[i], "erfc of #{x}")
    end
  end

  # A float32 cell is worked on narrow, so the call is `erff` -- the rule
  # every other libm call over that cell already takes.
  def test_the_error_function_on_a_float32
    values = CArray.float32(2) { |i| [0.5, -1.0][i] }
    out = CArray.float32(2)
    kernel = CArray.jit_for(2) { |i| out[i] = Math.erf(values[i]) }
    assert_includes(kernel.c_source, "erff(")
    assert_in_delta(Math.erf(0.5), out[0], 1e-7)
    assert_in_delta(Math.erf(-1.0), out[1], 1e-7)
  end

  # The names Ruby's Math has that this does not lower say why, and the
  # reason is never that C has no such function -- it has all four.
  def test_the_math_names_that_are_not_lowered
    values = CArray.double(2)
    out = CArray.double(2)
    [[proc { CArray.jit_for(2) { |i| out[i] = Math.gamma(values[i]) } },
      /a table of exact values, which is not what tgamma computes/],
     [proc { CArray.jit_for(2) { |i| out[i] = Math.lgamma(values[i]) } },
      /answer is a pair -- the value and the sign/],
     [proc { CArray.jit_for(2) { |i| out[i] = Math.frexp(values[i]) } },
      /answer is a pair -- the fraction and the exponent/],
     [proc { CArray.jit_for(2) { |i| out[i] = Math.ldexp(values[i], 3) } },
      /second argument is an exponent rather than a number/],
     [proc { CArray.jit_for(2) { |i| out[i] = Math.nosuch(values[i]) } },
      /Math.nosuch is not a name this compiles/],
    ].each do |attempt, reason|
      error = assert_raises(CArray::JIT::Unsupported) { attempt.call }
      assert_match(reason, error.message)
      refute_match(/no math.h counterpart/, error.message)
    end
  end

  def test_conditional_expression
    values = CArray.double(12)
    values[0] = 10.0
    CArray.jit_for(1...12) { |i|
      values[i] = if values[i-1] > 1.0
                    values[i-1] / 2.0
                  else
                    values[i-1] + 1.0
                  end
    }
    expected = Array.new(12, 0.0)
    expected[0] = 10.0
    (1...12).each { |i|
      expected[i] = expected[i-1] > 1.0 ? expected[i-1] / 2.0 : expected[i-1] + 1.0
    }
    12.times { |i| assert_bits_equal(expected[i], values[i], "cell #{i}") }
  end

  def test_reading_the_cell_being_written
    values = CArray.double(5).seq!
    CArray.jit_for(0...5) { |i| values[i] = values[i] * 2.0 + 1.0 }
    assert_equal([1.0, 3.0, 5.0, 7.0, 9.0], values.to_a)
  end

  # Multi-dimensional work is written multi-dimensionally; reshaping is not
  # needed for that, and measures the same.  Its one use is making a single
  # kernel serve several ranks, which is sound for element-wise work because
  # the index there is only "which cell".
  def test_one_kernel_serves_any_rank_after_reshape
    two = CArray.double(3, 4).seq!
    three = CArray.double(2, 3, 4).seq!
    out_two = CArray.double(3, 4)
    out_three = CArray.double(2, 3, 4)

    flat_source = two.reshape(two.elements)
    flat_result = out_two.reshape(out_two.elements)
    first = CArray.jit_for(two.elements) { |i|
      flat_result[i] = Math.sqrt(flat_source[i])
    }

    flat_source = three.reshape(three.elements)
    flat_result = out_three.reshape(out_three.elements)
    second = CArray.jit_for(three.elements) { |i|
      flat_result[i] = Math.sqrt(flat_source[i])
    }

    assert_same(first, second, "the same kernel serves both ranks")
    assert_in_delta(Math.sqrt(11), out_two[2, 3], 1e-15)
    assert_in_delta(Math.sqrt(23), out_three[1, 2, 3], 1e-15)
  end

  def test_element_wise_work_at_rank_two
    source = CArray.double(4, 5).seq!
    result = CArray.double(4, 5)
    CArray.jit_for(*source.dim) { |i, j| result[i, j] = Math.sqrt(source[i, j]) }
    4.times { |i| 5.times { |j|
      assert_bits_equal(Math.sqrt(source[i, j]), result[i, j], "cell #{i},#{j}") } }
  end

  def test_captured_integer_scalar
    step = 3
    values = CArray.double(6)
    values[0] = 1.0
    CArray.jit_for(1...6) { |i| values[i] = values[i-1] * step }
    assert_equal([1.0, 3.0, 9.0, 27.0, 81.0, 243.0], values.to_a)
  end

  def test_capture_values_are_reread_each_call
    weight = 2.0
    values = CArray.double(4)
    kernel = proc { |i| values[i] = values[i-1] * weight }
    values[0] = 1.0
    CArray.jit_for(1...4, &kernel)
    assert_equal([1.0, 2.0, 4.0, 8.0], values.to_a)

    weight = 3.0
    values[0] = 1.0
    CArray.jit_for(1...4, &kernel)
    assert_equal([1.0, 3.0, 9.0, 27.0], values.to_a)
  end

end
