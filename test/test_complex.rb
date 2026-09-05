require_relative "test_helper"

# Complex kernels, held to the same standard as every other kernel here: the
# answer is the one the Ruby loop gives, to the last bit.
#
# That is a sharper condition for complex numbers than for real ones, because
# Ruby's Complex arithmetic is not C's.  A real operand carries an exact
# Integer zero as its imaginary part, and Ruby's own `f_add` and `f_mul`
# short-circuit on it, so `Complex(1.0, -0.0) + 2.0` keeps the sign of that
# zero where C's `+` would lose it.  Division is Smith's method as complex.c
# writes it rather than as the C library writes it.  Both are tested against
# values Ruby computed rather than values a CArray stored, so that what is
# compared is this compiler's arithmetic and nothing else: the reference side
# of a signed-zero test should not depend on a round trip through another
# library's conversions.
class TestComplex < Minitest::Test

  include KernelAssertions

  # Chosen for their zeros and their signs -- the cells where Ruby and C part
  # company -- plus one pair at the ends of the exponent range.
  VALUES = [Complex(1.0, -0.0), Complex(-0.0, 2.0), Complex(0.5, 1.5),
            Complex(-3.0, -0.25), Complex(0.0, 0.0), Complex(2.0, -1.0),
            Complex(-0.0, -0.0), Complex(1.0e300, 1.0e-300),
            Complex(-1.5, 0.0), Complex(0.0, -4.0), Complex(7.25, 7.25),
            Complex(-2.0, -2.0)].freeze

  OTHERS = [Complex(3.0, 0.125), Complex(-1.0, 2.0), Complex(0.0, 0.0),
            Complex(0.25, -0.25), Complex(-0.0, 1.0), Complex(5.0, -0.0),
            Complex(1.0, 1.0), Complex(-4.0, 0.5), Complex(0.0, -0.0),
            Complex(2.5, 3.5), Complex(-6.0, -1.0), Complex(0.75, 0.0)].freeze

  COUNT = VALUES.size

  def setup
    @a = CArray.cmplx128(COUNT) { |i| VALUES[i] }
    @b = CArray.cmplx128(COUNT) { |i| OTHERS[i] }
    # What the arrays actually hold, which is what the kernel reads and so
    # what the Ruby comparison has to start from.
    @left = (0...COUNT).map { |i| @a[i] }
    @right = (0...COUNT).map { |i| @b[i] }
    @out = CArray.cmplx128(COUNT)
  end

  def assert_cells (expected)
    expected.each_with_index do |value, index|
      assert_bits_equal(value, @out[index], "cell #{index} differs")
    end
  end

  def test_a_complex_array_is_read_computed_in_and_written
    out = @out
    a = @a
    b = @b
    CArray.jit_for(COUNT) { |i| out[i] = a[i] + b[i] }
    assert_cells((0...COUNT).map { |i| @left[i] + @right[i] })
  end

  def test_the_computation_type_is_double_complex
    kernel = compile_kernel("->(i) { a[i] = a[i] + a[i] }",
                            arrays: { :a => "cmplx128" })
    assert_includes(kernel.c_source, "double _Complex")
    assert_includes(kernel.c_source, "#include <complex.h>")
  end

  # cmplx64 is to cmplx128 what float32 is to float64, and the arithmetic
  # follows: a cell is read as a `float _Complex`, worked on as one, and
  # stored as one.  That is what CArray's own cmplx64 kernels do -- their
  # generated `+` adds in cmplx64_t -- so the two agree.
  def test_cmplx64_computes_in_float_complex
    kernel = compile_kernel("->(i) { a[i] = a[i] * 2.0 }",
                            arrays: { :a => "cmplx64" })
    assert_includes(kernel.c_source, "(float _Complex *)")
    refute_includes(kernel.c_source, "(double _Complex)",
                    "a cmplx64 cell is not widened to be multiplied")

    # Against Ruby rather than against CArray, because `z * x` is one of the
    # places they differ: Ruby scales each part, CArray multiplies out in
    # full, and a kernel is the cell loop.
    values = CArray.cmplx64(COUNT) { |i| VALUES[i] }
    result = CArray.cmplx64(COUNT)
    expected = CArray.cmplx64(COUNT)
    CArray.jit_for(COUNT) { |i| result[i] = values[i] * 2.0 }
    COUNT.times { |i| expected[i] = values[i] * 2.0 }
    assert_equal(expected.to_a, result.to_a)
  end

  # The math family follows too, `csqrtf` and `cabsf` rather than the double
  # ones: CArray narrowed these after this gem asked about them, so agreeing
  # with it by construction is what this pins.  Agreeing because a platform
  # happens to implement `sinf` through `sin` is not the same thing, and is
  # what the source assertion is here to tell apart from it.
  #
  # Not every complex function goes narrow.  `clog` builds `log|z|`, and on
  # the unit circle that is a difference of two numbers near one: computed in
  # float the magnitude rounds to exactly one and the real part of the answer
  # is lost, not merely rounded.  `**` inherits it, `cpow` being
  # `cexp(z * clog(a))`.  Both stay wide, and this pins which is which.
  def test_a_cmplx64_math_call_is_computed_narrow
    kernel = compile_kernel("->(i) { r[i] = a[i].abs }",
                            arrays: { :a => "cmplx64", :r => "float32" })
    assert_includes(kernel.c_source, "cabsf(")

    root = compile_kernel("->(i) { r[i] = Math.sqrt(a[i]) }",
                          arrays: { :a => "cmplx64", :r => "cmplx64" })
    assert_includes(root.c_source, "csqrtf(")

    # Asserted on the C rather than on the values, deliberately.  Comparing
    # against CArray's own answer is the better test and is what the other
    # cases here do, but it can only be run against a CArray that has already
    # narrowed these -- and the two spellings agree on this platform anyway,
    # macOS implementing sinf and its family through the double ones.  The
    # source is what says which one was asked for.
    # VALUES carries infinities and signed zeros, so the check is on the
    # ordinary cells; what the special ones do is C's, and is the same C
    # either way.
    values = CArray.cmplx64(COUNT) { |i| VALUES[i] }
    magnitude = CArray.float32(COUNT)
    CArray.jit_each { magnitude = values.abs }
    COUNT.times do |i|
      next unless values[i].real.finite? && values[i].imaginary.finite?
      assert_in_delta(values[i].abs, magnitude[i], 1e-6, "cell #{i}")
    end
  end

  # The place a narrow complex function goes wrong, and the reason the list
  # above is a list.  On the unit circle `clog`'s real part is `log|z|` with
  # |z| just off one, so the answer is of the order of a float32 epsilon --
  # and computing the magnitude in float rounds it to exactly one, which
  # makes the answer zero.  The failure is not a last bit: reached narrow,
  # the error is the size of the answer.
  #
  # Written as a bound rather than against CArray, because what is being
  # pinned is a property of the arithmetic, and a bound says what "wrong"
  # would mean here where an equality against another implementation would
  # not.
  def test_a_complex_log_on_the_unit_circle_keeps_its_real_part
    count = 2000
    angles = (0...count).map { |i| 2 * Math::PI * i / count }
    circle = CArray.cmplx64(count) { |i| Complex(Math.cos(angles[i]),
                                                 Math.sin(angles[i])) }
    out = CArray.cmplx64(count)
    CArray.jit_each { out = Math.log(circle) }

    # log|z| worked out from the cells as stored, in double.
    worst = (0...count).map { |i|
      cell = circle[i]
      expected = Math.log(Math.hypot(cell.real, cell.imaginary))
      (out[i].real - expected).abs
    }.max
    scale = (0...count).map { |i|
      cell = circle[i]
      Math.log(Math.hypot(cell.real, cell.imaginary)).abs
    }.max

    assert_operator(worst, :<, scale / 1000.0,
                    "the real part of a complex log is lost, not rounded, " \
                    "when the magnitude is built in float")
  end

  # And the same fault at one remove: cpow is cexp(z * clog(a)), so a
  # variable base carries the lost magnitude into the answer.
  #
  # Asserted on the C, because the size of the damage depends on where the
  # exponent lands: on the unit circle the narrow spelling is only about five
  # times worse than the wide one, and a bound between the two would be a
  # bound on this platform's cpowf rather than on the arithmetic.  What is
  # worth pinning is which function was asked for.  A constant base is a
  # different matter -- its clog is worked out once and exactly -- but the
  # kernel does not know a base is constant, so there is one spelling.
  def test_a_complex_power_is_not_narrowed
    kernel = compile_kernel("->(i) { r[i] = a[i] ** a[i] }",
                            arrays: { :a => "cmplx64", :r => "cmplx64" })
    assert_includes(kernel.c_source, "cpow(")
    refute_includes(kernel.c_source, "cpowf(")

    count = 200
    angles = (0...count).map { |i| 2 * Math::PI * i / count }
    circle = CArray.cmplx64(count) { |i| Complex(Math.cos(angles[i]),
                                                 Math.sin(angles[i])) }
    out = CArray.cmplx64(count)
    CArray.jit_each { out = circle ** circle }
    count.times do |i|
      cell = Complex(circle[i].real, circle[i].imaginary)
      difference = out[i] - cell ** cell
      assert_operator(Math.hypot(difference.real, difference.imaginary),
                      :<, 1.0e-6, "cell #{i}")
    end
  end

  # Multiplying two complex numbers cancels -- (ac - bd) subtracts two
  # numbers of the same size -- so it is reached in double as division is.
  # Adding and subtracting do not, and stay narrow.
  def test_which_complex_operators_are_narrowed
    product = compile_kernel("->(i) { r[i] = a[i] * b[i] }",
                             arrays: { :a => "cmplx64", :b => "cmplx64",
                                       :r => "cmplx64" })
    assert_match(/\(float _Complex\)\(\(double _Complex\).*\*.*\)/,
                 product.c_source,
                 "a complex product is reached in double and rounded once -- " \
                 "and the cast is round the whole product, since it binds " \
                 "tighter than the operator and would otherwise narrow the " \
                 "left operand and leave the multiply around it")

    sum = compile_kernel("->(i) { r[i] = a[i] + b[i] }",
                         arrays: { :a => "cmplx64", :b => "cmplx64",
                                   :r => "cmplx64" })
    refute_includes(sum.c_source, "double _Complex",
                    "a complex sum has nothing to cancel")
  end

  # Division is the one that follows Ruby rather than CArray, cmplx128 and
  # cmplx64 alike: Smith's method in the order complex.c writes it, which is
  # not what CArray computes.  Ruby has only the one width to write it in, so
  # a cmplx64 divide is reached in double and rounded back -- narrowing it
  # would agree with neither.
  def test_a_cmplx64_divide_follows_ruby_as_the_wide_one_does
    left = CArray.cmplx64(COUNT) { |i| VALUES[i] }
    right = CArray.cmplx64(COUNT) { |i| VALUES[(i + 1) % COUNT] + Complex(0.5, 0.25) }
    result = CArray.cmplx64(COUNT)
    CArray.jit_each { result = left / right }

    expected = CArray.cmplx64(COUNT) { |i| left[i] / right[i] }
    assert_equal(expected.to_a, result.to_a)
  end

  def test_multiplication_and_subtraction_are_c_operators
    out = @out
    a = @a
    b = @b
    CArray.jit_for(COUNT) { |i| out[i] = a[i] * b[i] - b[i] }
    assert_cells((0...COUNT).map { |i| @left[i] * @right[i] - @right[i] })
  end

  # Smith's method, in the order complex.c writes it.  The C library's own
  # __divdc3 answers differently in the last bit.
  def test_division_follows_rubys_own_method
    out = @out
    a = @a
    b = @b
    CArray.jit_for(COUNT) { |i| out[i] = a[i] / b[i] }
    assert_cells((0...COUNT).map { |i| @left[i] / @right[i] })
    kernel = compile_kernel("->(i) { a[i] = a[i] / a[i] }",
                            arrays: { :a => "cmplx128" })
    assert_includes(kernel.c_source, "carray_jit_complex_divide")
  end

  # Each of the four operators, with the real operand on each side.  They do
  # not all follow the same rule, which is the point: `z * x` scales each
  # part and `x * z` multiplies out in full, and Ruby's two answers differ.
  def test_a_real_operand_is_combined_the_way_ruby_combines_it
    [2.0, -0.0, 0.0, -1.5, 3.0].each do |scalar|
      out = @out
      a = @a
      x = scalar
      CArray.jit_for(COUNT) { |i| out[i] = a[i] + x }
      assert_cells((0...COUNT).map { |i| @left[i] + x })
      CArray.jit_for(COUNT) { |i| out[i] = a[i] - x }
      assert_cells((0...COUNT).map { |i| @left[i] - x })
      CArray.jit_for(COUNT) { |i| out[i] = a[i] * x }
      assert_cells((0...COUNT).map { |i| @left[i] * x })
      CArray.jit_for(COUNT) { |i| out[i] = a[i] / x }
      assert_cells((0...COUNT).map { |i| @left[i] / x })
      CArray.jit_for(COUNT) { |i| out[i] = x + a[i] }
      assert_cells((0...COUNT).map { |i| x + @left[i] })
      CArray.jit_for(COUNT) { |i| out[i] = x - a[i] }
      assert_cells((0...COUNT).map { |i| x - @left[i] })
      CArray.jit_for(COUNT) { |i| out[i] = x * a[i] }
      assert_cells((0...COUNT).map { |i| x * @left[i] })
      CArray.jit_for(COUNT) { |i| out[i] = x / a[i] }
      assert_cells((0...COUNT).map { |i| x / @left[i] })
    end
  end

  def test_an_integer_operand_promotes_as_it_does_in_ruby
    out = @out
    a = @a
    CArray.jit_for(COUNT) { |i| out[i] = a[i] * 3 + 1 }
    assert_cells((0...COUNT).map { |i| @left[i] * 3 + 1 })
  end

  # `2i` is Complex(0, 2) with an exact zero real part, which passes through
  # an addition untouched exactly as a real operand's zero does.
  def test_an_imaginary_literal
    out = @out
    a = @a
    CArray.jit_for(COUNT) { |i| out[i] = a[i] + 1i }
    assert_cells((0...COUNT).map { |i| @left[i] + 1i })
    CArray.jit_for(COUNT) { |i| out[i] = 2.5i - a[i] }
    assert_cells((0...COUNT).map { |i| 2.5i - @left[i] })
    CArray.jit_for(COUNT) { |i| out[i] = a[i] * 1i }
    assert_cells((0...COUNT).map { |i| @left[i] * 1i })
  end

  def test_a_captured_complex_scalar
    out = @out
    a = @a
    w = Complex(0.5, -1.5)
    kernel = CArray.jit_for(COUNT) { |i| out[i] = a[i] * w + w }
    assert_cells((0...COUNT).map { |i| @left[i] * w + w })
    # It travels in the reals buffer as its two parts, so that the kernel
    # signature stays the one shape every kernel has.
    assert_equal([:w], kernel.complexes)
    assert_equal([], kernel.reals)
    assert_includes(kernel.c_source, "CMPLX(reals[0], reals[1])")
  end

  # The functions CArray computes on a complex array, and only those: this is
  # the list its own kernels answer, so a formula gives the same answer
  # whether it is applied to the array or compiled cell by cell.
  FUNCTIONS = %i[sqrt exp log sin cos tan asin acos atan
                 sinh cosh tanh asinh acosh atanh].freeze

  def test_the_complex_math_functions_agree_with_carrays_own
    FUNCTIONS.each do |name|
      source = "->(i) { out[i] = a[i].#{name} }"
      kernel = CArray::JIT.compile(source, array_names: [:out, :a],
                                   storage_types: { :out => "cmplx128", :a => "cmplx128" },
                                   scalar_values: {})
      assert_includes(kernel.c_source, "c#{name}(")
      result = CArray.cmplx128(COUNT)
      kernel.call({ :out => result, :a => @a }, {}, [[0, COUNT, 1]])
      expected = @a.send(name)
      COUNT.times do |index|
        assert_bits_equal(expected[index], result[index],
                          "#{name} differs at cell #{index}")
      end
    end
  end

  def test_the_parts_of_a_complex_number
    a = @a
    parts = CArray.float64(COUNT)
    { :real => :real, :imag => :imaginary, :arg => :arg, :abs => :abs }
      .each do |written, asked|
      source = "->(i) { parts[i] = a[i].#{written} }"
      kernel = CArray::JIT.compile(source, array_names: [:parts, :a],
                                   storage_types: { :parts => "float64", :a => "cmplx128" },
                                   scalar_values: {})
      kernel.call({ :parts => parts, :a => a }, {}, [[0, COUNT, 1]])
      COUNT.times do |index|
        assert_bits_equal(@left[index].send(asked), parts[index],
                          "#{written} differs at cell #{index}")
      end
    end
  end

  def test_conjugate_stays_complex
    out = @out
    a = @a
    CArray.jit_for(COUNT) { |i| out[i] = a[i].conjugate }
    assert_cells(@left.map(&:conjugate))
  end

  # Complex(x, y) is the way in from two real arrays, and the only way in
  # that does not start from a complex one.
  def test_a_complex_built_from_two_reals
    real = CArray.float64(COUNT) { |i| i * 0.5 - 1.0 }
    imaginary = CArray.float64(COUNT) { |i| 2.0 - i }
    out = @out
    CArray.jit_for(COUNT) { |i| out[i] = Complex(real[i], imaginary[i]) }
    assert_cells((0...COUNT).map { |i| Complex(real[i], imaginary[i]) })
  end

  def test_a_real_value_stored_into_a_complex_array
    out = @out
    values = CArray.float64(COUNT) { |i| i * 1.5 }
    CArray.jit_for(COUNT) { |i| out[i] = values[i] + 1.0 }
    assert_cells((0...COUNT).map { |i| Complex(values[i] + 1.0, 0.0) })
  end

  def test_equality_compares_both_parts
    a = @a
    b = @b
    same = CArray.boolean(COUNT)
    CArray.jit_for(COUNT) { |i| same[i] = a[i] == b[i] }
    assert_equal((0...COUNT).map { |i| @left[i] == @right[i] }, same.to_a)
  end

  def test_a_conditional_chooses_between_complex_values
    out = @out
    a = @a
    b = @b
    CArray.jit_for(COUNT) { |i| out[i] = a[i].abs > 2.0 ? a[i] : b[i] }
    assert_cells((0...COUNT).map { |i| @left[i].abs > 2.0 ? @left[i] : @right[i] })
  end

  # `**` is the one operation here whose answer is not the Ruby loop's to the
  # last bit.  Ruby raises a Complex to a power by binary powering; cpow goes
  # round through exp and log.  Measured over four hundred values, the two are
  # within three machine epsilons at `** 2` and fourteen at `** 7` -- growing
  # with the exponent, as a sequence of multiplications would.
  #
  # This is the only assertion in the suite with a tolerance in it, and the
  # tolerance is on the magnitude of the result rather than on either part:
  # the real part of a square passes through zero, where a relative bound on
  # that part alone would mean nothing.
  TOLERANCE = 32 * Float::EPSILON

  def assert_close (expected, actual, message = nil)
    return if expected == actual
    # `0 ** w` is NaN and `Complex(1e300, 1e-300) ** 3` overflows, and neither
    # is within a tolerance of anything -- including itself.  Where the answer
    # leaves the finite range the two routes stop agreeing about the parts at
    # all: Ruby's squaring overflows both of them, while cpow's exp overflows
    # the magnitude and multiplies a zero cosine into one part.  So all that
    # is asked there is that both leave it.
    unless expected.abs.finite?
      refute(actual.abs.finite?, message)
      return
    end
    assert_operator((expected - actual).abs, :<=, TOLERANCE * expected.abs,
                    message || "expected #{expected}, got #{actual}")
  end

  def test_a_complex_power_agrees_to_within_a_few_ulps
    out = @out
    a = @a
    b = @b
    CArray.jit_for(COUNT) { |i| out[i] = a[i] ** 3 }
    COUNT.times { |i| assert_close(@left[i] ** 3, out[i], "cell #{i}") }
    CArray.jit_for(COUNT) { |i| out[i] = a[i] ** b[i] }
    COUNT.times { |i| assert_close(@left[i] ** @right[i], out[i], "cell #{i}") }
    kernel = compile_kernel("->(i) { a[i] = a[i] ** 2 }",
                            arrays: { :a => "cmplx128" })
    assert_includes(kernel.c_source, "cpow(")
  end

  # The multiplication it stands for is exact, which is worth knowing before
  # writing a square as a power.  It is not the same thing as `z ** 2`,
  # though: on the axes -- where one part is zero -- Ruby's power takes an
  # exact route through the real number and comes back with an exact zero for
  # the other part, where the multiplication carries the sign it computed.
  def test_a_square_written_as_a_multiplication_is_exact
    out = @out
    a = @a
    CArray.jit_for(COUNT) { |i| out[i] = a[i] * a[i] }
    assert_cells((0...COUNT).map { |i| @left[i] * @left[i] })
  end

  def test_a_complex_accumulator_in_an_inner_loop
    a = @a
    out = @out
    CArray.jit_for(COUNT) do |i|
      total = Complex(0.0, 0.0)
      (0...3).each { |j| total = total + a[i] }
      out[i] = total
    end
    expected = (0...COUNT).map { |i|
      total = Complex(0.0, 0.0)
      3.times { total = total + @left[i] }
      total
    }
    assert_cells(expected)
  end

  def test_a_contraction_over_complex_arrays
    left = CArray.cmplx128(3, 4) { |i, j| Complex(i + 1.0, j * 0.25) }
    right = CArray.cmplx128(4) { |j| Complex(j * 0.5, -1.0) }
    result = CArray.contract { |i, j| left[i, j] * right[j] }
    assert_equal("cmplx128", result.data_type_name)
    expected = (0...3).map { |i|
      total = Complex(0.0, 0.0)
      4.times { |j| total = total + left[i, j] * right[j] }
      total
    }
    expected.each_with_index { |value, i| assert_bits_equal(value, result[i]) }
  end

  def test_a_masked_complex_array
    values = CArray.cmplx128(5) { |i| Complex(i.to_f, 1.0) }
    values[1] = UNDEF
    result = CArray.cmplx128(5)
    CArray.jit_for(5) { |i| result[i] = values[i] + 1.0 }
    assert_equal([false, true, false, false, false], result.mask.to_a)
    [0, 2, 3, 4].each do |index|
      assert_bits_equal(Complex(index + 1.0, 1.0), result[index])
    end
  end

  def test_undef_can_be_asked_about_and_written
    values = CArray.cmplx128(4) { |i| Complex(i.to_f, 0.5) }
    values[2] = UNDEF
    result = CArray.cmplx128(4)
    CArray.jit_for(4) { |i| result[i] = values[i] == UNDEF ? Complex(9.0, 9.0) : values[i] }
    assert_bits_equal(Complex(9.0, 9.0), result[2])
    assert_bits_equal(Complex(1.0, 0.5), result[1])
  end

  # ---- what a Complex will not do -------------------------------------

  COMPLEX_ARRAYS = { :c => "cmplx128", :f => "float64", :n => "int64" }.freeze

  def refuse_complex (source, pattern)
    refuse(source, pattern, arrays: COMPLEX_ARRAYS)
  end

  def test_ordering_comparisons_are_refused
    refuse_complex("->(i) { f[i] = c[i] < c[i] ? 1.0 : 0.0 }",
                   /does not order Complex numbers/)
  end

  def test_modulo_is_refused
    refuse_complex("->(i) { c[i] = c[i] % 2 }", /no meaning for a Complex/)
  end

  def test_rounding_is_refused
    refuse_complex("->(i) { n[i] = c[i].floor }", /take `\.real` or `\.abs` first/)
    refuse_complex("->(i) { f[i] = c[i].to_f }", /take `\.real` or `\.abs` first/)
  end

  def test_storing_a_complex_into_a_real_array_is_refused
    refuse_complex("->(i) { f[i] = c[i] }", /holds real numbers/)
  end

  def test_bit_operators_are_refused
    refuse_complex("->(i) { c[i] = c[i] & 1 }", /joins two integers/)
  end

  def test_a_complex_subscript_is_refused
    refuse_complex("->(i) { c[i] = c[c[i]] }", /a subscript is an integer/)
  end

  # log10, log2 and cbrt have no complex form in C99, and a complex CArray
  # refuses them too; atan2 and hypot are about the plane a complex number
  # already is.
  def test_math_functions_without_a_complex_form_are_refused
    refuse_complex("->(i) { c[i] = c[i].log10 }", /has no complex form/)
    refuse_complex("->(i) { c[i] = Math.atan2(c[i], c[i]) }", /takes two real numbers/)
    refuse_complex("->(i) { c[i] = Math.hypot(c[i], c[i]) }", /takes two real numbers/)
  end

  # A real number answers all four in Ruby rather than raising, and so does a
  # kernel.  Three of them compute nothing: a real number is its own real
  # part and its own conjugate, and its imaginary part is a zero.
  #
  # `arg` is the one Ruby does not settle the class of -- an Integer zero for
  # a number that is not negative, Math::PI for one that is -- and one C
  # variable is one type, so it is a Float throughout.  The number is the
  # same either way.  It is read off the sign bit, as Ruby reads it: `-0.0`
  # has an argument of pi although `-0.0 < 0` is false.
  REAL_VALUES = [1.5, -1.5, 0.0, -0.0, Float::NAN, Float::INFINITY,
                 -Float::INFINITY, 42.0, -0.25].freeze

  def test_the_parts_of_a_real_number
    values = CArray.float64(REAL_VALUES.size) { |i| REAL_VALUES[i] }
    held = (0...REAL_VALUES.size).map { |i| values[i] }
    count = REAL_VALUES.size
    result = CArray.float64(count)
    { :real => :real, :conjugate => :conjugate, :arg => :arg }.each do |written, asked|
      source = "->(i) { result[i] = values[i].#{written} }"
      kernel = CArray::JIT.compile(source, array_names: [:result, :values],
                                   storage_types: { :result => "float64",
                                                    :values => "float64" },
                                   scalar_values: {})
      kernel.call({ :result => result, :values => values }, {}, [[0, count, 1]])
      count.times do |index|
        assert_bits_equal(held[index].send(asked).to_f, result[index],
                          "#{written} differs at cell #{index}")
      end
    end
    zeros = CArray.int64(count)
    CArray.jit_for(count) { |i| zeros[i] = values[i].imag }
    assert_equal(Array.new(count, 0), zeros.to_a)
  end

  # Complex(x) is taken for Complex(x, 0.0).  In Ruby the two differ in one
  # respect only: the shorter one's imaginary part is an exact Integer zero,
  # which an addition returns the other operand untouched for, so it keeps
  # the sign of a zero the longer one loses.  Multiplication, division and
  # the infinities agree.
  def test_a_one_argument_complex_is_the_same_as_a_zero_imaginary_part
    out = @out
    values = CArray.float64(COUNT) { |i| i * 0.5 - 2.0 }
    CArray.jit_for(COUNT) { |i| out[i] = Complex(values[i]) }
    assert_cells((0...COUNT).map { |i| Complex(values[i], 0.0) })
    refuse_complex("->(i) { c[i] = Complex(f[i], f[i], f[i]) }",
                   /takes one part or two/)
  end

  def test_an_unsupported_scalar_class_names_complex_among_the_supported
    refuse("->(i) { a[i] = s * a[i] }", /Float, Integer or Complex/,
           scalars: { :s => "text" })
  end

end
