require_relative "test_helper"

# Letting CArray drive the loop.
#
# `ca_call_cslab_N` acquires the operands, broadcasts them, ORs the inputs'
# masks and propagates the result, and hands a callback one chunk at a time --
# re-gathering an operand it cannot walk in place 32KB at a time rather than
# copying it whole.  The tiers here move the whole box the kernel touches
# instead, and for an element-wise pass that box is the whole array.
#
# The compiled body is the same one either way: the sweep entry point is a
# wrapper that calls the kernel with the chunk as its bounds, so what is under
# test is who acquires the operands, not what they compute.
class TestSweep < Minitest::Test

  def setup
    skip "this CArray has no ca_call_cslab" unless CArray::JIT::Sweep.available?
  end

  # The property everything else rests on: two drivers, one answer.
  def test_the_two_drivers_agree
    a = CArray.double(6).seq!(1.0)
    b = CArray.double(6).seq!(0.5, 0.5)
    out = CArray.double(6)
    kernel = CArray.jit_each { out = a + b * 2.0 }
    by_sweep = out.to_a

    out.fill(0.0)
    kernel.call({ :a => a, :b => b, :out => out }, {}, [[0, 6, 1]], {})
    assert_equal(out.to_a, by_sweep)
  end

  # Which driver ran is visible in the kernel: a swept pass is compiled flat,
  # so its loop has one axis however many the arrays have.
  def test_a_swept_pass_is_compiled_flat
    m = CArray.double(3, 4).seq!
    out = CArray.double(3, 4)
    kernel = CArray.jit_each { out = m * 2.0 }
    assert_equal(1, kernel.rank, "a swept pass is one flat run of cells")
    assert_equal((m * 2.0).to_a, out.to_a)
  end

  # And the arrays are not flattened to make that work.  CArray's acquire
  # reads an operand's element count and element size and never looks at its
  # shape, so a chunk is already flat without anything being reshaped.
  def test_the_arrays_are_not_reshaped
    m = CArray.double(2, 3, 4).seq!
    out = CArray.double(2, 3, 4)
    CArray.jit_each { out = m + 1.0 }
    assert_equal([2, 3, 4], out.dim)
    assert_equal((m + 1.0).to_a, out.to_a)
  end

  # One kernel then serves every rank, because the rank has left the loop --
  # the same block text, given a run of cells and then a cube of them.
  def doubled (source, out)
    CArray.jit_each { out = source * 2.0 }
  end

  def test_one_flat_kernel_serves_any_rank
    flat_in = CArray.double(6).seq!
    flat_out = CArray.double(6)
    cubic_in = CArray.double(2, 3, 4).seq!
    cubic_out = CArray.double(2, 3, 4)

    flat = doubled(flat_in, flat_out)
    cubic = doubled(cubic_in, cubic_out)
    assert(flat.equal?(cubic),
           "one flat kernel should serve both, and two were compiled")
    assert_equal((flat_in * 2.0).to_a, flat_out.to_a)
    assert_equal((cubic_in * 2.0).to_a, cubic_out.to_a)
  end

  # A gather view is the operand the sweep is *for*: neither driver can walk
  # it in place, and the sweep re-gathers it 32KB at a time where the tiers
  # here would move the whole thing.
  def test_a_gather_view_agrees_too
    n = 1000
    src = CArray.double(n).seq!
    gather = src[CArray.int32(n).seq.reverse]
    b = CArray.double(n).seq!(0.5, 0.5)
    out = CArray.double(n)
    kernel = CArray.jit_each { out = gather + b * 2.0 }
    assert_equal(1, kernel.rank, "a gather view is what the sweep is for")
    assert_equal((gather.to_ca + b * 2.0).to_a, out.to_a)
  end

  def test_the_value_spelling_sweeps_as_well
    a = CArray.double(5).seq!(1.0)
    b = CArray.double(5).seq!(0.5, 0.5)
    result = CArray.jit_map { a + b * 2.0 }
    assert_equal((a + b * 2.0).to_a, result.to_a)
  end

  def test_captured_values_and_c_functions_travel_with_it
    j0 = CArray.jit_extern("double j0(double)")
    a = CArray.double(5).seq!(1.0)
    scale = 3.0
    result = CArray.jit_map { j0.call(a) * scale }
    a.elements.times { |i| assert_bits_equal(j0.call(a[i]) * scale, result[i]) }
  end

  # A captured Complex travels as two `reals` slots rather than one, and the
  # sweep once packed the reals alone -- so the kernel read slots nothing had
  # written and every cell came back zero.  Both drivers pack the slots the
  # same way now, which is what this asks.
  def test_a_captured_complex_travels_with_it
    z = Complex(3.0, 4.0)
    a = CArray.cmplx128(4).seq!(1.0)
    out = CArray.cmplx128(4)
    CArray.jit_each { out = a * z }
    assert_equal(a.to_a.map { |value| value * z }, out.to_a)
  end

  # ---------- what the sweep is not asked to do ----------

  # The one thing that cannot be flattened.  Broadcasting arrives as a stride
  # of zero on an axis, and a flat run has no axes -- cell k of the output
  # would stop lining up with cell k of the stretched operand.  So a stretched
  # operand keeps the nested loop and the driver here.
  def test_a_stretched_operand_stays_with_the_driver
    matrix = CArray.double(3, 4).seq!
    row = CArray.double(1, 4).seq!(10.0)
    out = CArray.double(3, 4)
    kernel = CArray.jit_each { out = matrix * row }
    assert_equal(2, kernel.rank, "a stretched operand needs the axes back")
    assert_equal((matrix * row).to_a, out.to_a)
  end

  # CArray ORs and propagates the masks, but the chunk it hands over carries
  # no per-cell mask the generated code could test -- and `a[i] == UNDEF` is
  # exactly that test.  So a body that asks about a mask keeps the driver.
  def test_a_masked_operand_stays_with_the_driver
    a = CArray.double(5).seq!(1.0)
    a[2] = UNDEF
    out = CArray.double(5)
    kernel = CArray.jit_each { out = a * 2.0 }
    refute_predicate(kernel, :sweepable?)
    assert_equal([false, false, true, false, false], out.is_masked.to_a)
    assert_equal((a * 2.0).to_a, out.to_a)
  end

  # The test is on the shape rather than on the count of cells, which is
  # stricter and has to be: six cells in one axis and six in two agree on
  # their count and are not the same pass.
  def test_the_decision_is_on_the_shape
    six = CArray.double(6)
    assert(CArray::JIT.send(:sweepable_pass?, { :a => six }, [6], false))
    refute(CArray::JIT.send(:sweepable_pass?,
                            { :a => CArray.double(2, 3) }, [6], false))
    refute(CArray::JIT.send(:sweepable_pass?, { :a => six }, [6], true),
           "a masked pass cannot sweep")
  end

  # A strided view -- a column, a transpose, every other cell -- is addressed
  # in place by the tiers here and re-gathered by the sweep, which buys
  # nothing: there was no whole-array copy to avoid.  So the operands settle
  # what the shape leaves open, and this one keeps the driver here.
  def test_a_strided_view_keeps_the_driver
    m = CArray.double(8, 8).seq!
    other = CArray.double(8, 8).fill(2.0)
    out = CArray.double(8, 8)
    every_other = m[nil, (0...8).step(2)]
    doubled = other[nil, (0...8).step(2)]
    into = out[nil, (0...8).step(2)]

    kernel = CArray.jit_each { into = every_other + doubled }
    assert_equal(2, kernel.rank, "a strided view is walked in place here")
    assert_equal((every_other.to_ca + doubled.to_ca).to_a, into.to_a)
  end

  # The same decision, asked of the predicate rather than read off a kernel.
  def test_the_decision_is_on_the_tier_as_well
    n = 8
    entity = CArray.double(n).seq!
    strided = CArray.double(2 * n).seq![(0...(2 * n)).step(2)]
    gathered = entity[CArray.int32(n).seq.reverse]

    assert(CArray::JIT.send(:sweepable_pass?, { :a => entity }, [n], false),
           "an entity is walked the same way either side")
    refute(CArray::JIT.send(:sweepable_pass?, { :a => strided }, [n], false),
           "a strided view is re-gathered by the sweep for nothing")
    assert(CArray::JIT.send(:sweepable_pass?, { :a => gathered }, [n], false),
           "a gather view is what the re-gather is for")
    assert(CArray::JIT.send(:sweepable_pass?,
                            { :a => strided, :b => gathered }, [n], false),
           "one operand that has to be moved is what decides it")
  end

  # An old CArray simply does not have the family, and everything falls back
  # without the caller hearing about it.
  def test_it_is_asked_for_rather_than_assumed
    assert_includes([true, false], CArray::JIT::Sweep.available?)
  end

end
