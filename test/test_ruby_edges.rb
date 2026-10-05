require_relative "test_helper"

# Where a block's answer could part from Ruby's at the edges of a number:
# the ends of int64, a negative zero, a negative Integer meeting a uint64.
class TestRubyEdges < Minitest::Test

  MIN = -2**63
  MAX = 2**63 - 1

  # Signed overflow wraps within a kernel, so a test on the wrapped value
  # asks about the value that was stored.
  def test_an_overflowed_value_is_tested_as_it_wrapped
    a = CArray.int64(2) { |i| [MIN, 3][i] }
    out = CArray.int64(2)
    CArray.jit_for(2) { |i| y = -a[i]; out[i] = y > 0 ? y : 0 }
    assert_equal [0, 0], out.to_a
    b = CArray.int64(2) { |i| [MAX, 3][i] }
    CArray.jit_for(2) { |i| y = b[i] + 1; out[i] = y > b[i] ? 1 : 0 }
    assert_equal [0, 1], out.to_a
  end

  def test_the_minimum_divided_by_minus_one_is_the_minimum
    a = CArray.int64(2) { |i| [MIN, 7][i] }
    d = CArray.int64(2) { -1 }
    q = CArray.int64(2)
    r = CArray.int64(2)
    CArray.jit_for(2) { |i| q[i] = a[i] / d[i]; r[i] = a[i] % d[i] }
    assert_equal [MIN, -7], q.to_a
    assert_equal [0, 0], r.to_a
  end

  def test_a_shift_means_what_it_means_to_integer
    a = CArray.int64(4) { |i| [-8, 8, 3, -3][i] }
    s = CArray.int64(4) { |i| [-1, -1, 70, 70][i] }
    left = CArray.int64(4)
    right = CArray.int64(4)
    CArray.jit_for(4) { |i| left[i] = a[i] << s[i]; right[i] = a[i] >> s[i] }
    assert_equal [-4, 4, 0, 0], left.to_a
    assert_equal [-16, 16, 0, -1], right.to_a
  end

  # An Integer has no sign of zero.
  def test_rounding_into_a_float_cell_gives_no_negative_zero
    x = CArray.double(1) { -0.3 }
    out = CArray.double(4)
    CArray.jit_for(1) { |i|
      out[0] = x[i].ceil; out[1] = x[i].round; out[2] = x[i].truncate; out[3] = x[i].to_i
    }
    out.to_a.each { |v| assert_equal 1, (1.0 / v).infinite? }
  end

  # Ruby's Float#% keeps the dividend's sign on a zero remainder.
  def test_a_zero_float_remainder_keeps_the_dividends_sign
    x = CArray.double(2) { |i| [-4.0, 4.0][i] }
    out = CArray.double(4)
    CArray.jit_for(2) { |i| out[i] = x[i] % 2.0; out[i + 2] = x[i] % -2.0 }
    signs = out.to_a.map { |v| (1.0 / v).infinite? }
    assert_equal [-1, 1, -1, 1], signs
  end

  def test_a_negative_integer_meeting_a_uint64_is_refused
    w = CArray.uint64(2) { |i| [3, 2**64 - 1][i] }
    f = CArray.double(2)
    assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i| f[i] = w[i] > -1 ? 1.0 : 0.0 }
    end
    neg = -1
    assert_raises(RangeError) do
      CArray.jit_for(2) { |i| f[i] = w[i] > neg ? 1.0 : 0.0 }
    end
    pos = 1
    CArray.jit_for(2) { |i| f[i] = w[i] > pos ? 1.0 : 0.0 }
    assert_equal [1.0, 1.0], f.to_a
  end

  # The loop counts its passes before it starts, so a range that ends at the
  # top of int64 runs as Ruby's does.
  def test_a_loop_ending_at_the_top_of_int64_runs
    out = CArray.int64(1)
    CArray.jit_for(1) { |i|
      n = 0
      (9223372036854775805..9223372036854775807).each { |j| n += 1 }
      out[i] = n
    }
    assert_equal [3], out.to_a
    CArray.jit_for(1) { |i|
      n = 0
      9223372036854775800.step(9223372036854775807, 5) { |j| n += 1 }
      out[i] = n
    }
    assert_equal [2], out.to_a
  end

  def test_a_literal_past_a_double_is_an_infinity
    out = CArray.double(1)
    CArray.jit_for(1) { |i| out[i] = 1e400 }
    assert_equal [Float::INFINITY], out.to_a
  end

  def test_a_literal_past_any_integer_width_is_refused
    out = CArray.double(1)
    assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i| out[i] = 1180591620717411303424 * 1.0 }
    end
  end

  # Ruby answers a negative base to a power that is not an integer with a
  # Complex.  Stored in a complex cell, or joined with one, the kernel gives
  # that Complex; read as a real it stays pow's NaN.
  def test_a_negative_base_to_a_fractional_power_is_complex_where_complex_is_wanted
    x = CA_FLOAT64([-8.0, -8.0, -8.0, 4.0, -2.0, -0.5, -3.0, -8.0])
    y = CA_FLOAT64([1.0 / 3, 2.5, 2.0, 0.5, 0.25, -1.5, 0.1, Float::INFINITY])
    n = x.size
    expected = x.to_a.zip(y.to_a).map { |a, b| (a ** b).to_c }
    z = CArray.cmplx128(n)
    CArray.jit_for(n) { |i| z[i] = x[i] ** y[i] }
    z.to_a.zip(expected).each do |got, want|
      assert_equal [want.real, want.imag.to_f].map { |v| [v].pack("G") },
                   [got.real, got.imag].map { |v| [v].pack("G") }
    end
    w = CArray.cmplx128(n)
    CArray.jit_for(n) { |i| w[i] = x[i] ** y[i] + 1i }
    assert_equal expected.map { |v| v + 1i }, w.to_a
    r = CArray.double(n)
    CArray.jit_for(n) { |i| r[i] = x[i] ** y[i] }
    assert_equal [true, true, false, false, true, true, true, false],
                 r.to_a.map(&:nan?)
  end

  # 2**63 is an Integer in Ruby.  Computed as an int64 it would wrap to a
  # negative number, so the kernel refuses it there; meeting a uint64 or a
  # Float it keeps its value.
  def test_an_integer_literal_past_int64_is_refused_where_it_is_an_int64
    o = CArray.int64(2)
    a = CA_INT64([1, -1])
    assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i| o[i] = 9223372036854775808 }
    end
    assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i| o[i] = a[i] + 9223372036854775808 }
    end
    b = CArray.boolean(2)
    assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i| b[i] = a[i] < 9223372036854775808 }
    end
    u = CArray.uint64(2)
    ua = CA_UINT64([1, 2])
    CArray.jit_for(2) { |i| u[i] = ua[i] + 9223372036854775808 }
    assert_equal [2**63 + 1, 2**63 + 2], u.to_a
    d = CArray.double(2)
    CArray.jit_for(2) { |i| d[i] = 9223372036854775808 }
    assert_equal [2.0**63, 2.0**63], d.to_a
  end
end
