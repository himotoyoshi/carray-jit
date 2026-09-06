require_relative "test_helper"

# A CScalar is the one-cell CArray it subclasses, minus the index: `s[]` is
# the value, and CArray's own operators read that one cell for every cell of
# everything else.  A kernel addresses what it is handed, so the two spellings
# reach it by two routes -- the whole-array ones stretch it as they stretch a
# one-cell CArray, and the indexed ones read it where it lies.
class TestCScalar < Minitest::Test

  def test_a_cscalar_reaches_an_expression
    s = CScalar.double() { 2.0 }
    values = CArray.double(3).seq!(1.0)
    out = CArray.double(3)
    CArray.jit_each { out = values * s }
    assert_equal([2.0, 4.0, 6.0], out.to_a)
    assert_equal((values * s).to_a, out.to_a, "what CArray's own operators give")
  end

  def test_a_cscalar_among_the_named_elements
    s = CScalar.double() { 2.0 }
    values = CArray.double(3).seq!(1.0)
    assert_equal([3.0, 4.0, 5.0], CArray.jit_map { values + s }.to_a)
  end

  # The example a CScalar exists for.
  def test_a_cscalar_updated_in_place
    s = CScalar.int() { 2 }
    CArray.jit_each { s = s + 2 }
    assert_equal(4, s[0])
  end

  # CArray refuses to write three cells into one; so does this, and says the
  # same thing about shapes.
  def test_a_cscalar_cannot_take_a_wider_expression
    s = CScalar.int() { 2 }
    values = CArray.int(3).seq!(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { s = values + 1 }
    end
    assert_match(/has shape \[1\], but the expression covers \[3\]/, error.message)
  end

  # In an indexed kernel there is no index to write for it, which is the
  # whole of what makes it a CScalar rather than a CArray of one cell.
  def test_a_cscalar_in_an_indexed_kernel
    s = CScalar.int() { 7 }
    out = CArray.int(3)
    CArray.jit_for(3) { |i| out[i] = s[] + 1 }
    assert_equal([8, 8, 8], out.to_a)
  end

  def test_a_cscalar_named_bare_in_an_indexed_kernel
    s = CScalar.int() { 7 }
    out = CArray.int(3)
    CArray.jit_for(3) { |i| out[i] = s + 1 }
    assert_equal([8, 8, 8], out.to_a)
  end

  # It is still the one-cell array it is, so the index spelling keeps working
  # and means the same thing.
  def test_the_index_spelling_agrees
    s = CScalar.int() { 7 }
    bare = CArray.int(3)
    indexed = CArray.int(3)
    CArray.jit_for(3) { |i| bare[i] = s[] + 1 }
    CArray.jit_for(3) { |i| indexed[i] = s[0] + 1 }
    assert_equal(indexed.to_a, bare.to_a)
  end

  # Every iteration writes the one cell it has, and what is left is what the
  # same Ruby loop leaves -- which here makes it an accumulator.
  def test_a_cscalar_written_by_every_iteration
    s = CScalar.int() { 0 }
    values = CArray.int(4).seq!(1)
    CArray.jit_for(4) { |i| s[] = s[] + values[i] }
    assert_equal(1 + 2 + 3 + 4, s[0])
  end

  def test_a_cscalar_holds_a_reduction
    values = CArray.double(5).seq!(1.0)
    box = CScalar.double() { 0.0 }
    CArray.jit_for(1) { |_|
      accumulator = 0.0
      5.times { |j| accumulator = accumulator + values[j] }
      box[] = accumulator
    }
    assert_equal(15.0, box[0])
  end

  def test_a_cscalar_in_a_contraction
    left = CArray.double(3).seq!(1.0)
    right = CArray.double(3).seq!(1.0)
    weight = CScalar.double() { 2.0 }
    assert_equal([28.0], CArray.jit_contract { |k| left[k] * right[k] * weight[] }.to_a)
  end

  def test_a_masked_cell_survives_a_cscalar_operand
    s = CScalar.double() { 2.0 }
    values = CArray.double(3).seq!(1.0)
    values[1] = UNDEF
    out = CArray.double(3)
    CArray.jit_each { out = values * s }
    assert_equal([false, true, false], out.is_masked.to_a)
    assert_equal([2.0, 6.0], [out[0], out[2]])
  end

  # A CScalar has no shape of its own, so it takes the rank of what it stands
  # beside.  `CArray.broadcast` stretches a size-1 axis but does not invent a
  # missing one, so referring it as `[1]` made it a one-axis array that a 2D
  # operand could not be lined up with -- an ndim mismatch, from inside
  # CArray, for an expression CArray's own operators compute.
  def test_a_cscalar_against_a_two_dimensional_array
    s = CScalar.double() { 2.0 }
    values = CArray.double(2, 3).seq!(1.0)
    out = CArray.double(2, 3)
    CArray.jit_each { out = values * s }
    assert_equal([[2.0, 4.0, 6.0], [8.0, 10.0, 12.0]], out.to_a)
    assert_equal((values * s).to_a, out.to_a, "what CArray's own operators give")
  end

  def test_a_cscalar_against_a_three_dimensional_array
    s = CScalar.double() { 2.0 }
    values = CArray.double(2, 2, 2).seq!(1.0)
    assert_equal((values + s).to_a, CArray.jit_map { values + s }.to_a)
  end

  def test_a_masked_cell_survives_a_cscalar_operand_in_two_dimensions
    s = CScalar.double() { 2.0 }
    values = CArray.double(2, 2).seq!(1.0)
    values[0, 1] = UNDEF
    out = CArray.double(2, 2)
    CArray.jit_each { out = values * s }
    assert_equal([[false, true], [false, false]], out.is_masked.to_a)
  end

  # The same source over a CScalar and over a one-cell CArray are two
  # kernels: one reads a cell that does not move, the other walks an axis.
  def test_the_cache_keeps_the_two_apart
    scalar = CScalar.int() { 7 }
    single = CArray.int(1) { 7 }
    from_scalar = CArray.int(3)
    from_single = CArray.int(3)
    CArray.jit_each { from_scalar = scalar + 1 }
    CArray.jit_each { from_single = single + 1 }
    assert_equal([8, 8, 8], from_scalar.to_a)
    assert_equal([8, 8, 8], from_single.to_a)
  end

end
