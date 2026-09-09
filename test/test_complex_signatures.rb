require_relative "test_helper"

# A compiled function may take and return a C99 complex.  A kernel calls one
# as C calls it; a call from Ruby goes round through a second entry point,
# Fiddle having no type to carry a complex by value in.
class TestComplexSignatures < Minitest::Test

  def test_complex_in_and_out
    step = CArray.jit_function("double _Complex step(double _Complex z)") { |z|
      z * z + Complex(0.0, 1.0)
    }
    assert_equal(Complex(-3.0, 5.0), step.call(Complex(1.0, 2.0)))
    assert_equal(step.block.call(Complex(1.0, 2.0)), step.call(Complex(1.0, 2.0)))
  end

  def test_a_complex_argument_and_a_real_result
    magnitude = CArray.jit_function("double magnitude(double _Complex z)") { |z|
      z.abs
    }
    assert_equal(5.0, magnitude.call(Complex(3.0, 4.0)))
    assert_equal(magnitude.block.call(Complex(3.0, 4.0)),
                 magnitude.call(Complex(3.0, 4.0)))
  end

  def test_a_real_argument_and_a_complex_result
    spin = CArray.jit_function("double _Complex spin(double t)") { |t|
      Complex(Math.cos(t), Math.sin(t))
    }
    assert_equal(spin.block.call(0.5), spin.call(0.5))
  end

  # `<complex.h>` spells it `double complex`, and a declaration may say
  # either -- which words were used says nothing about what was declared.
  def test_the_complex_h_spelling
    twice = CArray.jit_function("double complex twice(double complex z)") { |z|
      z * 2.0
    }
    assert_equal(Complex(2.0, -2.0), twice.call(Complex(1.0, -1.0)))
  end

  def test_float_complex
    halve = CArray.jit_function("float _Complex halve(float _Complex z)") { |z|
      z * 0.5
    }
    assert_equal(Complex(0.5, 1.5), halve.call(Complex(1.0, 3.0)))
  end

  # `Complex()` is what Ruby converts with, so an Integer and a Float are
  # taken where a complex is asked for, as they are in Ruby.
  def test_a_real_number_where_a_complex_is_asked_for
    double = CArray.jit_function("double _Complex twice(double _Complex z)") { |z|
      z * 2.0
    }
    assert_equal(Complex(4.0, 0.0), double.call(2))
    assert_equal(Complex(5.0, 0.0), double.call(2.5))
  end

  # A pointer to complex is a cmplx128 array on this side, as a pointer to
  # double is a float64 one.
  def test_a_pointer_to_complex
    weighted = CArray.jit_function(
      "double _Complex weighted(double _Complex v[], int64_t n, double _Complex w)"
    ) { |v, n, w|
      total = Complex(0.0, 0.0)
      (0...n).each { |k| total = total + v[k] * w }
      total
    }
    values = CArray.cmplx128(3) { |i| Complex(i + 1.0, 0.0) }
    assert_equal(Complex(0.0, 6.0), weighted.call(values, 3, Complex(0.0, 1.0)))
    assert_equal(weighted.block.call(values, 3, Complex(0.0, 1.0)),
                 weighted.call(values, 3, Complex(0.0, 1.0)))
  end

  def test_a_pointer_to_complex_checks_the_array_type
    fill = CArray.jit_function("double _Complex first(double _Complex v[])") { |v|
      v[0]
    }
    error = assert_raises(CArray::JIT::Unsupported) do
      fill.call(CArray.double(3))
    end
    assert_match(/takes a cmplx128 array, and this one is float64/, error.message)
  end

  # From a kernel it is C calling C, and the shim is not on that road.
  def test_called_from_a_kernel
    scale = CArray.jit_function(
      "double _Complex scale(double _Complex z, double s)"
    ) { |z, s| z * s }
    values = CArray.cmplx128(3) { |i| Complex(i + 1.0, 1.0) }
    out = CArray.cmplx128(3)
    CArray.jit_for(3) { |i| out[i] = scale.call(values[i], 2.0) }
    expected = (0...3).map { |i| Complex(i + 1.0, 1.0) * 2.0 }
    assert_equal(expected, out.to_a)
  end

  # A borrowed function may be declared with one and called from a kernel;
  # what it cannot be is called from Ruby, there being no body here to reach
  # it through.
  def test_a_borrowed_function
    cexp = CArray.jit_extern("double _Complex cexp(double _Complex)")
    values = CArray.cmplx128(2) { |i| Complex(0.0, i * Math::PI) }
    out = CArray.cmplx128(2)
    CArray.jit_for(2) { |i| out[i] = cexp.call(values[i]) }
    assert_in_delta(1.0, out[0].real, 1e-15)
    assert_in_delta(-1.0, out[1].real, 1e-15)

    error = assert_raises(CArray::JIT::Unsupported) { cexp.call(Complex(0.0, 0.0)) }
    assert_match(/carries a C99 complex by value/, error.message)
    assert_match(/a kernel calls it as C calls it/, error.message)
  end

  # The shim calls the body rather than repeating it, so what the body says
  # travels back through it.
  def test_a_body_that_raises
    guard = CArray.jit_function(
      "double _Complex guard(double _Complex z, int64_t n)"
    ) { |z, n|
      raise "n is zero" if n == 0
      z * n
    }
    assert_equal(Complex(2.0, 2.0), guard.call(Complex(1.0, 1.0), 2))
    error = assert_raises(RuntimeError) { guard.call(Complex(1.0, 1.0), 0) }
    assert_equal("n is zero", error.message)
  end

  # A signature with no complex in it is called directly, as before: the
  # second entry point is only compiled where it is needed.
  def test_a_real_signature_takes_no_shim
    plain = CArray.jit_function("double twice(double x)") { |x| x * 2.0 }
    assert_equal(4.0, plain.call(2.0))
    refute_match(/_from_ruby/, plain.c_source)
  end

  def test_long_double_complex_is_refused
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("long double _Complex f(long double _Complex z)") { |z| z }
    end
    assert_match(/there is no long double here to make one of/, error.message)
  end

end
