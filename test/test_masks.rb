require_relative "test_helper"

# A masked cell means "no value here", and the bytes underneath it are out of
# contract -- a kernel may compute anything into them so long as the mask ends
# up right.  That is what lets the loop stay branchless: every cell is
# computed, and only the mask is reconciled.
#
# The reference here is CArray's own operators, not a Ruby loop.  A Ruby loop
# cannot be the reference for a masked array: `src[i]` hands back UNDEF, and
# `UNDEF * 2.0` does not run at all.
class TestMasks < Minitest::Test

  def test_element_wise_matches_the_carray_operator
    source = CArray.double(6).seq!
    source[2] = UNDEF
    result = CArray.double(6)
    CArray.jit_for(6) { |i| result[i] = source[i] * 2.0 }
    assert_equal((source * 2.0).to_a, result.to_a)
  end

  def test_any_masked_input_masks_the_output
    left = CArray.double(5).seq!
    right = CArray.double(5).seq!(10)
    left[1] = UNDEF
    right[3] = UNDEF
    result = CArray.double(5)
    CArray.jit_for(5) { |i| result[i] = left[i] + right[i] }
    assert_equal((left + right).to_a, result.to_a)
    assert_equal([false, true, false, true, false], result.is_masked.to_a)
  end

  # Masking follows the offsets, because the mask of a cell is the mask of the
  # cells that fed it.
  def test_a_masked_cell_masks_its_readers
    values = CArray.double(7).seq!
    values[3] = UNDEF
    result = CArray.double(7)
    CArray.jit_for(1...6) { |i| result[i] = values[i-1] + values[i+1] }
    assert_equal([false, false, true, false, true, false, false],
                 result.is_masked.to_a)
  end

  # Two outputs in one kernel take their masks from their own inputs, not from
  # the body's.
  def test_each_output_is_masked_by_its_own_inputs
    left = CArray.double(4).seq!
    right = CArray.double(4).seq!(10)
    left[1] = UNDEF
    right[2] = UNDEF
    first = CArray.double(4)
    second = CArray.double(4)
    CArray.jit_for(4) { |i|
      first[i] = left[i] * 2.0
      second[i] = right[i] * 2.0
    }
    assert_equal([false, true, false, false], first.is_masked.to_a)
    assert_equal([false, false, true, false], second.is_masked.to_a)
  end

  def test_a_write_with_no_reads_clears_the_mask
    values = CArray.double(4).seq!
    values[1] = UNDEF
    CArray.jit_for(4) { |i| values[i] = 7.0 }
    assert_equal([7.0] * 4, values.to_a)
    refute(values.is_masked.to_a.any?)
  end

  def test_the_mask_propagates_through_a_recurrence
    values = CArray.double(6)
    values[0] = 1.0
    values[1] = UNDEF
    CArray.jit_for(2...6) { |i| values[i] = values[i-1] * 2.0 }
    assert_equal([false, true, true, true, true, true], values.is_masked.to_a)
  end

  # A plain CArray has no mask at all; one is created only once a cell is
  # marked.  A kernel over unmasked arrays must not bring one into being.
  def test_unmasked_arrays_stay_unmasked
    source = CArray.double(4).seq!
    result = CArray.double(4)
    CArray.jit_for(4) { |i| result[i] = source[i] * 3.0 }
    refute(source.has_mask?)
    refute(result.has_mask?)
  end

  # An array with a mask propagates the mask's existence even when nothing is
  # actually masked, which is what CArray's own operators do.
  def test_an_all_present_mask_still_propagates
    source = CArray.double(4).seq!
    source.mask = 0
    result = CArray.double(4)
    CArray.jit_for(4) { |i| result[i] = source[i] }
    assert(result.has_mask?)
    refute(result.is_masked.to_a.any?)
  end

  def test_masks_work_through_a_strided_view
    matrix = CArray.double(6, 3).seq!
    column = matrix[nil, 1]
    column[2] = UNDEF
    result = CArray.double(6)
    CArray.jit_for(6) { |i| result[i] = column[i] * 2.0 }
    assert_equal((column * 2.0).to_a, result.to_a)
    assert_equal([false, false, true, false, false, false], result.is_masked.to_a)
  end

  # CArray's kernels skip masked cells, so a zero that only ever feeds a
  # masked cell never reaches its divide-by-zero check.  A branchless kernel
  # divides anyway, so the report is gated on the mask instead.
  def test_a_masked_zero_divisor_is_not_a_division_by_zero
    values = CArray.int64(4)
    values[0] = 100
    values[1] = 0
    values[2] = 50
    values[3] = 20
    values[1] = UNDEF
    result = CArray.int64(4)
    CArray.jit_for(4) { |i| result[i] = 1000 / values[i] }
    assert_equal((1000 / values).to_a, result.to_a)
  end

  def test_an_unmasked_zero_divisor_still_raises
    values = CArray.int64(3)
    values[0] = 5
    values[1] = 0
    values[2] = 2
    values.mask = 0
    result = CArray.int64(3)
    assert_raises(ZeroDivisionError) do
      CArray.jit_for(3) { |i| result[i] = 100 / values[i] }
    end
  end

  # A view that reinterprets the element size gets a mask of its own shape,
  # but one of its mask cells covers a fraction of a parent cell, so writing
  # one marks its neighbour.  A per-cell kernel cannot express that.
  def test_a_size_changing_refer_with_a_mask_is_refused
    values = CArray.double(4).seq!
    values.mask = 0
    reinterpreted = values.refer(CA_INT32, [8])
    error = assert_raises(ArgumentError) do
      CArray::JIT::Access.open([reinterpreted], [true]) { }
    end
    assert_match(/reinterprets the element size/, error.message)
  end

  def test_the_same_kernel_compiles_separately_with_and_without_masks
    plain = CArray.double(4).seq!
    plain_out = CArray.double(4)
    first = CArray.jit_for(4) { |i| plain_out[i] = plain[i] * 5.0 }
    refute(first.masked)

    plain[1] = UNDEF
    second = CArray.jit_for(4) { |i| plain_out[i] = plain[i] * 5.0 }
    assert(second.masked)
    refute_same(first, second)
  end

  # In an element kernel the name is already the cell, so the mask is asked
  # about and marked by the same name -- not by `a[i]`, which is the other
  # spelling's way of saying the same thing.
  def test_an_element_kernel_asks_about_the_mask
    values = CArray.double(4).seq!
    values[1] = UNDEF
    assert_equal([0.0, -1.0, 20.0, 30.0],
                 CArray.jit_map { values == UNDEF ? -1.0 : values * 10 }.to_a)
    assert_equal([0.0, -1.0, 20.0, 30.0],
                 CArray.jit_map { values != UNDEF ? values * 10 : -1.0 }.to_a)
    assert_equal([0.0, -1.0, 20.0, 30.0],
                 CArray.jit_map { UNDEF == values ? -1.0 : values * 10 }.to_a)
  end

  def test_an_element_kernel_marks_a_cell_missing
    values = CArray.double(4).seq!
    result = CArray.double(4)
    CArray.jit_each { if values < 2 then result = values * 10 else result = UNDEF end }
    assert_equal([0.0, 10.0], result[0..1].to_a)
    assert_equal(2, result.count_masked)
  end

  # Only a cell can be asked, and in this spelling a name that is not an
  # array is not one.
  def test_asking_a_scalar_about_the_mask_is_refused
    values = CArray.double(4).seq!
    limit = 2.0
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_map { limit == UNDEF ? 0.0 : values }
    end
    assert_match(/only a cell can be compared with UNDEF/, error.message)
  end

end
