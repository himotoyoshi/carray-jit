require_relative "test_helper"

# The contraction taken apart: `contraction_of` reads a block and says what
# product it is, `contract_terms` runs a product somebody assembled.
#
# Between them they are `jit_contract` with the block removed from the middle,
# which is what a caller needs when the contraction it wants to run was
# decided rather than written -- two terms at a time, in an order it chose.
class TestContractTerms < Minitest::Test

  # The analyzer reads what the block closed over, so these are locals rather
  # than instance variables -- an instance variable is not something a kernel
  # can reach.
  def operands
    [CArray.double(3, 4).seq!(1), CArray.double(4, 2).seq!(1)]
  end

  def square
    CArray.double(3, 3).seq!(1)
  end

  # ---------- contract_terms ----------

  def test_a_matrix_product
    a, b = operands
    result = CArray::JIT.contract_terms([[a, [:i, :k]], [b, [:k, :j]]],
                                        free: [:i, :j])
    assert_equal([3, 2], result.dim)
    assert_equal(CArray.jit_contract { |i, j, k| a[i,k] * b[k,j] }.to_a,
                 result.to_a)
  end

  # `free:` is the axis order, as the parameter list is for a block.
  def test_the_free_list_gives_the_axis_order
    a, b = operands
    straight = CArray::JIT.contract_terms([[a, [:i, :k]], [b, [:k, :j]]],
                                          free: [:i, :j])
    swapped = CArray::JIT.contract_terms([[a, [:i, :k]], [b, [:k, :j]]],
                                         free: [:j, :i])
    assert_equal([2, 3], swapped.dim)
    assert_equal(straight.transpose.to_a, swapped.to_a)
  end

  # A named index is free however often it appears, and one that repeats is
  # summed: the rules are the block form's, because it is the same compiler.
  def test_the_diagonal_beside_the_trace
    q = square
    diagonal = CArray::JIT.contract_terms([[q, [:d, :d]]], free: [:d])
    trace = CArray::JIT.contract_terms([[q, [:d, :d]]], free: [])
    assert_equal((0...3).map { |d| q[d,d] }, diagonal.to_a)
    assert_equal([1], trace.dim)
    assert_equal((0...3).sum { |d| q[d,d] }, trace[0])
  end

  def test_writing_into_an_array_of_your_own
    a, b = operands
    into = CArray.double(3, 2)
    returned = CArray::JIT.contract_terms([[a, [:i, :k]], [b, [:k, :j]]],
                                          free: [:i, :j], into: into)
    assert_same(into, returned)
    assert_equal(CArray.jit_contract { |i, j, k| a[i,k] * b[k,j] }.to_a,
                 into.to_a)
  end

  # With every index summed the result is one number, and it goes to the one
  # cell -- as `box[0] = ...` does in a block.
  def test_writing_a_single_number_into_an_array_of_your_own
    q = square
    box = CArray.double(1)
    CArray::JIT.contract_terms([[q, [:d, :d]]], free: [], into: box)
    assert_equal((0...3).sum { |d| q[d,d] }, box[0])
  end

  def test_the_same_array_in_two_terms
    a, b = operands
    result = CArray::JIT.contract_terms([[a, [:i, :k]], [a, [:j, :k]]],
                                        free: [:i, :j])
    expected = (0...3).map { |i|
      (0...3).map { |j| (0...4).sum { |k| a[i,k] * a[j,k] } } }
    assert_equal(expected, result.to_a)
  end

  def test_a_missing_cell_is_missing_in_what_reaches_it
    a, b = operands
    masked = a.copy
    masked[0, 0] = UNDEF
    result = CArray::JIT.contract_terms([[masked, [:i, :k]], [b, [:k, :j]]],
                                        free: [:i, :j])
    assert_equal(UNDEF, result[0, 0])
    assert_equal(CArray.jit_contract { |i, j, k| masked[i,k] * b[k,j] }.to_a,
                 result.to_a)
  end

  def test_the_type_is_the_summands
    integers = CArray.int64(2, 2).seq!(1)
    result = CArray::JIT.contract_terms([[integers, [:i, :k]], [integers, [:k, :j]]],
                                        free: [:i, :j])
    assert_equal("int64", result.data_type_name)
  end

  # ---------- what contract_terms refuses ----------

  def refusal
    error = assert_raises(CArray::JIT::Unsupported) { yield }
    error.message
  end

  def test_the_terms_have_to_be_terms
    a, b = operands
    assert_match(/takes the terms of a product/,
                 refusal { CArray::JIT.contract_terms([], free: []) })
    assert_match(/the indices of a term are symbols/,
                 refusal { CArray::JIT.contract_terms([[a, :i]], free: []) })
    assert_match(/one index per axis/,
                 refusal { CArray::JIT.contract_terms([[a, [:i]]], free: [:i]) })
  end

  def test_a_free_index_that_names_no_axis
    a, b = operands
    assert_match(/`z` names no axis here/,
                 refusal {
                   CArray::JIT.contract_terms([[a, [:i, :k]], [b, [:k, :j]]],
                                              free: [:i, :z])
                 })
  end

  # The source this writes names the terms, so an index cannot have one of
  # those names as well.
  def test_an_index_that_collides_with_a_term_name
    a, b = operands
    assert_match(/`term0` names a term here/,
                 refusal {
                   CArray::JIT.contract_terms([[a, [:term0, :k]], [b, [:k, :j]]],
                                              free: [:term0, :j])
                 })
  end

  # The block form's rules apply, since it is the same compiler: an index that
  # is neither named nor repeated is free, and there is nowhere to put it.
  def test_an_index_at_one_position_that_was_not_named
    a, b = operands
    assert_match(/`k` appears once, so it is free rather than summed/,
                 refusal { CArray::JIT.contract_terms([[a, [:i, :k]]], free: [:i]) })
  end

  def test_the_extents_come_from_the_axes
    a, b = operands
    wrong = CArray.double(5, 2).seq!(1)
    assert_match(/`k` addresses axes of different extents/,
                 refusal {
                   CArray::JIT.contract_terms([[a, [:i, :k]], [wrong, [:k, :j]]],
                                              free: [:i, :j])
                 })
  end

  def test_into_has_to_have_the_result_s_axes
    a, b = operands
    assert_match(/`into:` has rank 1/,
                 refusal {
                   CArray::JIT.contract_terms([[a, [:i, :k]], [b, [:k, :j]]],
                                              free: [:i, :j], into: CArray.double(3))
                 })
  end

  # ---------- contraction_of ----------

  def test_what_a_block_is_a_product_of
    a, b = operands
    structure = CArray::JIT.contraction_of(proc { |i, j, k| a[i,k] * b[k,j] })
    assert_equal([:i, :j], structure[:free])
    assert_equal([:k], structure[:summed])
    assert_equal([[a, [:i, :k]], [b, [:k, :j]]], structure[:terms])
  end

  def test_the_axes_may_be_named_here_too
    q = square
    structure = CArray::JIT.contraction_of(proc { q[d,d] }, :d)
    assert_equal([:d], structure[:free])
    assert_equal([], structure[:summed])
    assert_equal([[q, [:d, :d]]], structure[:terms])
  end

  # Nil is "there is nothing here to take apart", not "this is wrong": every
  # block below is one `jit_contract` compiles.
  def test_what_is_not_a_product_of_cells
    a, b = operands
    factor = 2.0
    into = CArray.double(3, 2)
    assert_nil(CArray::JIT.contraction_of(proc { |i, j, k| Math.exp(a[i,k]) * b[k,j] }))
    assert_nil(CArray::JIT.contraction_of(proc { |i, k| a[i,k] / b[k,0] }))
    assert_nil(CArray::JIT.contraction_of(proc { |i, j, k| a[i,k] * b[k,j] * factor }))
    assert_nil(CArray::JIT.contraction_of(proc { |i, j, k| into[i,j] = a[i,k] * b[k,j] }))
    assert_nil(CArray::JIT.contraction_of(proc { |i, j, k| t = a[i,k]; t * b[k,j] }))
  end

  # ---------- the two together ----------

  def test_a_block_taken_apart_and_put_back
    a, b = operands
    [proc { |i, j, k| a[i,k] * b[k,j] },
     proc { |i, k| a[i,k] * a[i,k] },
     proc { |i, j| a[i,0] * b[0,j] }].each do |block|
      structure = CArray::JIT.contraction_of(block)
      next unless structure
      rebuilt = CArray::JIT.contract_terms(structure[:terms], free: structure[:free])
      assert_equal(CArray.jit_contract(&block).to_a, rebuilt.to_a)
    end
  end

  # What the whole seam exists for: a product of three, contracted two at a
  # time in an order chosen outside, agrees with the one nest that does it in
  # a single sweep.  The two do not agree bitwise and are not meant to -- the
  # additions are grouped differently -- so this is the tolerance a
  # rearrangement earns.
  def test_a_chain_contracted_two_at_a_time
    size = 8
    a = CArray.double(size, size).seq!(1) / (size * size)
    b = CArray.double(size, size).seq!(0.5) / (size * size)
    c = CArray.double(size, size).seq!(0.25) / (size * size)

    whole = CArray.jit_contract { |i, l, j, k| a[i,k] * b[k,j] * c[j,l] }
    structure = CArray::JIT.contraction_of(proc { |i, l, j, k| a[i,k] * b[k,j] * c[j,l] })
    assert_equal([:i, :l], structure[:free])
    assert_equal([:k, :j], structure[:summed])

    first, second, third = structure[:terms]
    step = CArray::JIT.contract_terms([first, second], free: [:i, :j])
    rebuilt = CArray::JIT.contract_terms([[step, [:i, :j]], third], free: [:i, :l])

    assert_equal(whole.dim, rebuilt.dim)
    assert_operator((whole - rebuilt).abs.max, :<, 1e-12)
  end

end
