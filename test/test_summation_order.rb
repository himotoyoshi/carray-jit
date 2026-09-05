require_relative "test_helper"

# Floating-point addition is not associative, so what order a reduction takes
# its terms in is part of what it computes.  A kernel takes partial sums by
# default, as CArray's own reduce kernels do; `reassociate: false` asks for
# the order a serial Ruby loop would have taken, to the last bit.
class TestSummationOrder < Minitest::Test

  def cancelling_row (length)
    values = CArray.double(1, length)
    length.times { |j| values[0, j] = (j.even? ? 1.0e8 : 1.0e-8) + j * 1.0e-9 }
    values
  end

  def summed (length, values, **licence)
    box = CArray.double(1)
    CArray.jit_for(1, **licence) { |i|
      accumulator = 0.0
      (0...length).each { |j| accumulator = accumulator + values[0, j] }
      box[i] = accumulator
    }
    box[0]
  end

  def test_a_refused_licence_sums_in_the_order_ruby_would
    length = 4096
    values = cancelling_row(length)

    serial = 0.0
    length.times { |j| serial += values[0, j] }

    assert_bits_equal(serial, summed(length, values, reassociate: false))
  end

  # The licensed kernel is the default, and it is the one that differs from
  # the Ruby loop.  Its answer is the better of the two here: the row cancels,
  # and splitting the accumulation is what limits that.
  def test_the_licence_is_taken_by_default
    length = 4096
    values = cancelling_row(length)

    serial = 0.0
    length.times { |j| serial += values[0, j] }
    exact = values.to_a[0].sort_by(&:abs).inject(0.0, :+)

    licensed = summed(length, values)
    refute_equal([serial].pack("d"), [licensed].pack("d"),
                 "the default kernel accumulates in a different order")
    assert_in_epsilon exact, licensed, 1.0e-12
    assert_operator (licensed - exact).abs, :<, (serial - exact).abs
  end

  # The licence is part of the kernel rather than of the call, so the two
  # spellings are two kernels and neither is served from the other's cache.
  def test_the_two_licences_are_two_kernels
    length = 4096
    values = cancelling_row(length)

    refute_equal([summed(length, values, reassociate: false)].pack("d"),
                 [summed(length, values, reassociate: true)].pack("d"))
  end

  # Not a defect on either side: the partial sums are usually the more
  # accurate answer.  It is pinned here because it is the reason the two
  # numbers differ at all.
  def test_carrays_own_reduction_reassociates
    length = 4096
    values = cancelling_row(length)

    serial = 0.0
    length.times { |j| serial += values[0, j] }

    refute_equal([serial].pack("d"), [values.sum(axis: 1)[0]].pack("d"),
                 "a SIMD reduction accumulates in a different order")
  end

  # ---------- grouping is part of the expression ----------
  #
  # Every operator here groups to the left, so a right operand of the same
  # precedence needs parentheses in the C whatever the operator is.  Not
  # because C would compute a different number for integers -- it would not --
  # but because floating-point arithmetic does not associate, and this
  # compiler's claim is that it computes what the same expression computes in
  # Ruby.  `a + (b + c)` emitted as `a + b + c` is `(a + b) + c`, a different
  # sum, and it was emitted that way: `-` and `/` were parenthesised and `+`
  # and `*` were not, on the reasoning that they associate.  They associate in
  # arithmetic; doubles are not arithmetic.
  def test_addition_keeps_the_grouping_it_was_written_with
    a = CArray.double(1) { 1.0 }
    b = CArray.double(1) { 1e-16 }
    c = CArray.double(1) { 1e-16 }
    out = CArray.double(1)
    CArray.jit_each { out = a + (b + c) }
    assert_bits_equal(1.0 + (1e-16 + 1e-16), out[0])
    refute_equal((1.0 + 1e-16) + 1e-16, out[0],
                 "the two groupings differ, which is what makes this a test")
  end

  def test_multiplication_keeps_the_grouping_it_was_written_with
    a = CArray.double(1) { 1e300 }
    b = CArray.double(1) { 1e300 }
    c = CArray.double(1) { 1e-300 }
    out = CArray.double(1)
    CArray.jit_each { out = a * (b * c) }
    assert_bits_equal(1e300 * (1e300 * 1e-300), out[0])
    assert_predicate(out[0], :finite?, "regrouped, the product overflows")
  end

  def test_subtraction_and_division_too
    a = CArray.double(1) { 12.0 }
    b = CArray.double(1) { 4.0 }
    c = CArray.double(1) { 2.0 }
    out = CArray.double(1)
    CArray.jit_each { out = a - (b - c) }
    assert_bits_equal(12.0 - (4.0 - 2.0), out[0])
    CArray.jit_each { out = a / (b / c) }
    assert_bits_equal(12.0 / (4.0 / 2.0), out[0])
  end

  # The generated C says it, which is the level the bug lived at.
  def test_the_parentheses_reach_the_generated_c
    a = CArray.double(1) { 1.0 }
    b = CArray.double(1) { 1.0 }
    c = CArray.double(1) { 1.0 }
    out = CArray.double(1)
    kernel = CArray.jit_each { out = a + (b + c) }
    assert_match(/\+ \(.*\+.*\)/, kernel.c_source,
                 "the right operand of a `+` was flattened into the left")
  end

  # A long chain of mixed groupings, against the same expression in Ruby.
  def test_a_deep_expression_agrees_cell_for_cell
    n = 500
    x = CArray.double(n).seq!(1.0, 1e-13)
    y = CArray.double(n).seq!(0.5, 1e-13)
    out = CArray.double(n)
    CArray.jit_each { out = x + (y + (x + (y + (x + (y + (x + y)))))) }
    n.times do |i|
      expected = x[i] + (y[i] + (x[i] + (y[i] + (x[i] + (y[i] + (x[i] + y[i]))))))
      assert_bits_equal(expected, out[i], "cell #{i}")
    end
  end

end
