require_relative "test_helper"

# CArray builds an expression -- `CArray.fuse { a + b * c }` -- and asks
# whoever is registered to compute it.  Installing this gem registers one.
#
# The property under test is that installing it changes nothing but the
# speed: every answer here is compared against the one CArray arrives at on
# its own, to the last bit.
class TestExpression < Minitest::Test

  N = 20_000     # above the size at which CArray bothers to ask

  def setup
    unless defined?(CArray::JIT::Expression)
      skip "this CArray does not carry the expression front end " \
           "(needs the plan, the kernel bodies and the build flags)"
    end
    @a = CArray.float64(N) { |i| (i % 97) + 0.5 }
    @b = CArray.float64(N) { |i| (i % 13) + 1.0 }
    @c = CArray.float64(N) { |i| (i % 7) + 2.0 }
    @out = CArray.float64(N)
  end

  def registered
    assert_kind_of CArray::JIT::Expression, CArray.expression_evaluator
  end

  def without_it
    kept, CArray.expression_evaluator = CArray.expression_evaluator, nil
    yield
  ensure
    CArray.expression_evaluator = kept
  end

  # Whether the evaluator computed the expression itself, or handed it back
  # for CArray to walk.  Nothing downstream can tell: a decline is answered
  # by walking the same expression, which arrives at the same values.  So it
  # is asked directly, the way CArray asks it.
  def computed? (view)
    plan = CArray::Fusion.plan(view)
    out = CArray.new(plan.data_type, view.dim)
    out.mask = 0 if plan.masked
    CArray.expression_evaluator.call(plan, out)
  end

  # Computes the expression both ways and compares.  `walked` is the answer
  # CArray reaches by walking; `compiled` is the one this gem reaches.
  #
  # Floats are compared bit for bit -- agreeing to the last one is the
  # property under test, and a tolerance would hide the difference a
  # contraction flag makes.  A masked cell holds whatever the arithmetic
  # left there, which neither side promises anything about, so only the
  # mask itself is compared for those.
  def assert_same_answer (&expression)
    walked = without_it { expression.call.to_ca }
    compiled = expression.call.to_ca
    assert_equal walked.data_type, compiled.data_type
    assert_equal walked.dim, compiled.dim
    mask = walked.has_mask? ? walked.mask.to_a.flatten : Array.new(walked.elements, false)
    if walked.has_mask? || compiled.has_mask?
      assert compiled.has_mask?, "the compiled answer lost the mask"
      assert_equal mask, compiled.mask.to_a.flatten, "masks differ"
    end
    wanted, got = walked.to_a.flatten, compiled.to_a.flatten
    wanted.each_index do |cell|
      next if mask[cell]
      if wanted[cell].is_a?(Float)
        assert_bits_equal wanted[cell], got[cell], "cell #{cell} differs"
      else
        assert_equal wanted[cell], got[cell], "cell #{cell} differs"
      end
    end
  end

  def test_it_is_registered_by_requiring_the_gem
    registered
  end

  # -- the answer ---------------------------------------------------------

  def test_one_operation
    assert_same_answer { CArray.fuse { @a + @b } }
  end

  def test_several
    assert_same_answer { CArray.fuse { (@a + @b) * (@c - @a) + @b * @c - @a } }
  end

  def test_a_function
    assert_same_answer { CArray.fuse { @a.sqrt + @b.log } }
  end

  def test_a_constant_in_the_expression
    assert_same_answer { CArray.fuse { @a * 2.5 + 1.0 } }
  end

  def test_a_constant_that_is_not_an_ordinary_number
    assert_same_answer { CArray.fuse { @a * -0.0 } }
    assert_same_answer { CArray.fuse { @a + Float::NAN } }
    assert_same_answer { CArray.fuse { @a * -Float::INFINITY } }
    assert_same_answer { CArray.fuse { @a * 1e300 * 1e10 } }
    assert_equal true, computed?(CArray.fuse { @a + Float::NAN })
    assert_equal true, computed?(CArray.fuse { @a * -Float::INFINITY })
  end

  def test_an_array_named_twice
    assert_same_answer { CArray.fuse { @a * @a + @a } }
  end

  def test_integers
    x = CArray.int32(N) { |i| i - N / 2 }
    y = CArray.int32(N) { |i| (i % 5) + 1 }
    assert_same_answer { CArray.fuse { x * y + x } }
    assert_same_answer { CArray.fuse { x / y } }
    assert_same_answer { CArray.fuse { x % y } }
  end

  def test_a_comparison
    assert_same_answer { CArray.fuse { @a > @b } }
  end

  # An Integer power is its own node for a Float array (ipow) and the power
  # kernel for an integer one; both call CArray's op_powi_<type>, which
  # CArray hands over with the bodies.
  def test_integer_powers
    x = CArray.float64(N) { |i| (i - N / 2) * 0.0013 }
    k = CArray.int32(N) { |i| (i % 9) - 4 }
    u = CArray.uint8(N) { |i| i % 5 }
    [2, 3, 0, -2, -7, 2**31, -(2**63)].each do |p|
      assert_same_answer { x.lazy ** p }
      assert_same_answer { x.to_type(:float32).lazy ** p }
    end
    [2, 3, 7].each do |p|
      assert_same_answer { k.lazy ** p }
      assert_same_answer { u.lazy ** p }
    end
    assert_same_answer { (x.lazy * 1.5 + 0.25) ** 3 - x.lazy ** 2 }
    return unless CArray.respond_to?(:__kernel_helpers__)
    assert_equal true, computed?(x.lazy ** 3)
    assert_equal true, computed?(x.lazy ** -2)
    assert_equal true, computed?(k.lazy ** 3)
  end

  def test_every_comparison
    x = CArray.int32(N) { |i| (i % 11) - 5 }
    y = CArray.int32(N) { |i| (i % 7) - 3 }
    %i[eq ne lt gt le ge].each do |m|
      assert_same_answer { CArray.fuse { @a.send(m, @b) } }
      assert_same_answer { CArray.fuse { x.send(m, y) } }
      assert_same_answer { CArray.fuse { x.send(m, 2) } }
    end
  end

  def test_a_predicate
    z = @a / (@b - 3.0)          # some infinities and a NaN or two
    %i[is_nan is_inf is_finite signbit].each do |m|
      assert_same_answer { CArray.fuse { (z * 1.0).send(m) } }
    end
  end

  def test_a_comparison_inside_an_expression_is_compiled_with_it
    assert_same_answer { CArray.fuse { (@a + @b).gt(@c * 3.0) & @a.lt(50.0) } }
    assert_equal true, computed?(CArray.fuse { (@a + @b).gt(@c * 3.0) })
  end

  def test_a_masked_comparison
    masked = @a.copy
    masked[5] = UNDEF
    assert_same_answer { CArray.fuse { masked.gt(@b) | @c.eq(2.0) } }
  end

  # -- shifted reads ------------------------------------------------------

  ROWS, COLUMNS = 200, 150
  NEIGHBOURS = [[-1, -1], [-1, 0], [-1, 1], [0, -1], [0, 1], [1, -1], [1, 0], [1, 1]].freeze

  def grid (type = :float64)
    CArray.new(type, [ROWS, COLUMNS]) { |i, j| ((i * 7 + j * 3) % 5) }
  end

  def test_a_neighbour_sum
    %i[uint8 int32 float64].each do |type|
      g = grid(type)
      assert_same_answer { CArray.fuse { NEIGHBOURS.map { |di, dj| g.shift(di, dj, fill_value: 0) }.inject(:+) } }
    end
  end

  def test_the_game_of_life_rule
    cells = grid(:uint8).gt(2).uint8
    alive = cells.eq(1)
    assert_same_answer {
      CArray.fuse {
        n = NEIGHBOURS.map { |di, dj| cells.shift(di, dj, fill_value: 0) }.inject(:+)
        n.eq(3) | (alive & n.eq(2))
      }
    }
  end

  def test_a_shift_is_compiled_rather_than_handed_back
    g = grid
    assert_equal true, computed?(CArray.fuse { g.shift(1, 0, fill_value: 0) - g })
  end

  def test_a_fill_value
    g = grid
    assert_same_answer { CArray.fuse { g.shift(2, -3, fill_value: 9.5) + g } }
  end

  def test_a_fill_that_masks
    g = grid
    assert_same_answer { CArray.fuse { g.shift(1, 1, fill_value: UNDEF) * 2.0 } }
  end

  def test_a_boolean_fill
    g = CArray.boolean(100, 200) { |i, j| (i + j) % 3 == 0 }
    [0, 1, false, true].each do |fill|
      assert_same_answer { CArray.fuse { g.shift(1, -1, fill_value: fill).eq(g) } }
    end
  end

  def test_a_shift_of_a_masked_array
    g = grid
    g[3, 4] = UNDEF
    g[0, 0] = UNDEF
    assert_same_answer { CArray.fuse { g.shift(-1, 1, fill_value: 0) + g } }
  end

  def test_a_shift_further_than_the_array
    g = grid
    assert_same_answer { CArray.fuse { g.shift(ROWS + 5, 0, fill_value: 1.0) + g } }
    assert_same_answer { CArray.fuse { g.shift(0, -COLUMNS - 5, fill_value: 1.0) + g } }
  end

  def test_one_and_three_axes
    line = CArray.float64(N) { |i| (i % 9) * 1.0 }
    assert_same_answer { CArray.fuse { line.shift(1, fill_value: 0) - line.shift(-1, fill_value: 0) } }
    cube = CArray.float64(40, 30, 20) { |i, j, k| (i + 2 * j + 3 * k) % 11 }
    assert_same_answer {
      CArray.fuse { cube.shift(1, 0, 0) + cube.shift(0, -1, 0) + cube.shift(0, 0, 1) - cube * 3.0 }
    }
  end

  def test_a_shifted_read_of_the_array_it_writes_into
    # It would read cells it has already written, so it is handed back.
    walked = grid
    without_it { walked[] = CArray.fuse { walked.shift(1, 0, fill_value: 0) + walked } }
    compiled = grid
    compiled[] = CArray.fuse { compiled.shift(1, 0, fill_value: 0) + compiled }
    assert_arrays_bits_equal walked, compiled
  end

  # -- storing ------------------------------------------------------------

  def test_a_store_fills_the_array_it_was_given
    want = without_it { (CArray.fuse { @a + @b * @c }).to_ca }
    @out[] = CArray.fuse { @a + @b * @c }
    assert_arrays_bits_equal want, @out
  end

  def test_an_expression_over_the_array_it_writes_into
    walked = @a.copy
    without_it { walked[] = CArray.fuse { walked * 2.0 + 1.0 } }
    compiled = @a.copy
    compiled[] = CArray.fuse { compiled * 2.0 + 1.0 }
    assert_arrays_bits_equal walked, compiled
  end

  # -- masks --------------------------------------------------------------

  def test_a_mask_travels_the_same_way
    masked = @a.copy
    masked[3] = UNDEF
    masked[N - 1] = UNDEF
    assert_same_answer { CArray.fuse { masked + @b * @c } }
  end

  def test_boolean_and_or_stay_three_valued
    p1 = CArray.boolean(N) { |i| i.even? }
    p2 = CArray.boolean(N) { |i| i % 3 == 0 }
    p1[1] = UNDEF
    p2[2] = UNDEF
    assert_same_answer { CArray.fuse { p1 | p2 } }
    assert_same_answer { CArray.fuse { p1 & p2 } }
    assert_same_answer { CArray.fuse { p1 ^ p2 } }
  end

  def test_a_masked_zero_divisor_is_not_divided_by
    x = CArray.int32(N) { |i| i + 1 }
    z = CArray.int32(N) { |i| i % 3 }
    z[:eq, 0] = UNDEF
    assert_same_answer { CArray.fuse { x / z } }
    assert_same_answer { CArray.fuse { x % z } }
  end

  # A masked zero has to be stepped over by the kernel, not by the fallback:
  # declining would reach the same answer by walking, so the test above
  # cannot tell which one produced it.  This asks the evaluator.
  def test_the_kernel_is_what_steps_over_a_masked_zero_divisor
    x = CArray.int32(N) { |i| i + 1 }
    z = CArray.int32(N) { |i| i % 3 }
    z[:eq, 0] = UNDEF
    assert_equal true, computed?(CArray.fuse { x / z })
  end

  def test_an_unmasked_zero_divisor_still_raises
    x = CArray.int32(N) { |i| i + 1 }
    z = CArray.int32(N) { |i| i % 3 }
    assert_raises(ZeroDivisionError) { (CArray.fuse { x / z }).to_ca }
    # And the evaluator is still there afterwards.  CArray retires an
    # evaluator that raises, for the rest of the process and with a warning,
    # so a zero divisor reported out of the kernel would turn one expression
    # into every later one being walked.
    registered
  end

  # The kernel declines rather than reporting it, which is what keeps the
  # evaluator registered above.
  def test_an_unmasked_zero_divisor_is_handed_back
    x = CArray.int32(N) { |i| i + 1 }
    z = CArray.int32(N) { |i| i % 3 }
    assert_equal false, computed?(CArray.fuse { x / z })
  end

  # -- declining ----------------------------------------------------------

  def test_an_operand_not_laid_out_end_to_end_is_left_to_CArray
    grid = CArray.float64(N, 3) { |i, j| i + j * 0.5 }
    column = grid[nil, 1]
    assert_same_answer { CArray.fuse { column * 2.0 } }
  end

  def test_an_object_array_is_left_to_CArray
    # Its kernels call back into the interpreter, so CArray does not even
    # describe one in a plan.  Compared by what is handed over rather than
    # by the answer, because materialising an object expression this size
    # is broken in CArray itself (see the note in test_helper.rb).
    objects = CArray.object(N) { |i| Rational(i, 3) }
    assert_nil CArray::Fusion.plan(CArray.fuse { objects + 1 })
  end

  def test_a_small_expression_is_never_asked_about
    small = CArray.float64(4) { |i| i.to_f }
    assert_same_answer { CArray.fuse { small + small } }
  end

  # -- the flags ----------------------------------------------------------

  def test_it_builds_the_way_CArray_did
    # The answer is compared against the eager kernel, so it has to be built
    # the way the eager kernel was.  The Prism front end answers to a Ruby
    # loop instead, and wants the opposite on contraction.
    CArray::BUILD_FLAGS.split.each do |flag|
      assert_includes CArray::JIT::Expression::FLAGS, flag
    end
    refute_includes CArray::JIT::Expression::FLAGS, "-ffp-contract=off"
    assert_includes CArray::JIT::Compiler::FLAGS, "-ffp-contract=off"
  end

  def test_the_two_front_ends_do_not_share_a_cached_object
    one = CArray::JIT::Compiler.digest("int f(void) { return 1; }")
    two = CArray::JIT::Compiler.digest("int f(void) { return 1; }",
                                       CArray::JIT::Expression::FLAGS)
    refute_equal one, two
  end
end
