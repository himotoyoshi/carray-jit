require_relative "test_helper"

# The contraction convention: an index that appears twice in the term is summed.
#
#   CArray.jit_contract { |i, j, k| c[i,j] = a[i,k] * b[k,j] }
#
# The repetition is the notation -- it is what stands in for the sigma -- so
# the assignment does not decide what is summed and cannot make an index
# disappear.  The left-hand side says where the result goes and in what order
# its axes lie, and must name exactly the free indices.
#
# No extent is given, because each index's extent is fixed by the axes it
# addresses; an index whose axes disagree is the shape error a contraction
# exists to catch.
class TestContract < Minitest::Test

  # With nothing to assign into, the result is allocated and returned, its
  # axes being the free indices in the order the block named them.
  def test_the_returned_form
    ni, nk, nj = 3, 4, 2
    a = CArray.double(ni, nk).seq!(1)
    b = CArray.double(nk, nj).seq!(1)
    c = CArray.jit_contract { |i, j, k| a[i,k] * b[k,j] }

    assert_instance_of(CArray, c)
    assert_equal([ni, nj], c.dim)
    assert_equal("float64", c.data_type_name)
    expected = (0...ni).map { |i|
      (0...nj).map { |j| (0...nk).sum { |k| a[i,k] * b[k,j] } } }
    assert_equal(expected, c.to_a)
  end

  # The parameter order is where the result's axis order is stated.
  def test_the_parameter_order_gives_the_axis_order
    a = CArray.double(3, 4).seq!(1)
    b = CArray.double(4, 2).seq!(1)
    straight = CArray.jit_contract { |i, j, k| a[i,k] * b[k,j] }
    swapped = CArray.jit_contract { |j, i, k| a[i,k] * b[k,j] }
    assert_equal([3, 2], straight.dim)
    assert_equal([2, 3], swapped.dim)
    assert_equal(straight.transpose.to_a, swapped.to_a)
  end

  # Every index summed leaves no free axis, so the result is a number in a
  # one-cell array.
  def test_the_returned_form_with_nothing_free
    a = CArray.double(3, 4).seq!(1)
    b = CArray.double(3, 4).seq!(2)
    result = CArray.jit_contract { |i, k| a[i,k] * b[i,k] }
    assert_equal([1], result.dim)
    assert_equal((0...3).sum { |i| (0...4).sum { |k| a[i,k] * b[i,k] } }, result[0])
  end

  def test_the_returned_form_keeps_integers_integral
    a = CArray.int64(2, 3).seq!(1)
    b = CArray.int64(3, 2).seq!(1)
    c = CArray.jit_contract { |i, j, k| a[i,k] * b[k,j] }
    assert_equal("int64", c.data_type_name)
    assert_equal([[22, 28], [49, 64]], c.to_a)
  end

  def test_the_returned_and_assigned_forms_agree
    a = CArray.double(3, 4).seq!(1)
    b = CArray.double(4, 2).seq!(1)
    returned = CArray.jit_contract { |i, j, k| a[i,k] * b[k,j] }
    box = CArray.double(3, 2)
    CArray.jit_contract { |i, j, k| box[i,j] = a[i,k] * b[k,j] }
    assert_equal(returned.to_a, box.to_a)
  end

  def test_matrix_multiply
    ni, nk, nj = 3, 4, 2
    a = CArray.double(ni, nk).seq!(1)
    b = CArray.double(nk, nj).seq!(1)
    c = CArray.double(ni, nj)
    CArray.jit_contract { |i, j, k| c[i,j] = a[i,k] * b[k,j] }
    expected = (0...ni).map { |i|
      (0...nj).map { |j| (0...nk).sum { |k| a[i,k] * b[k,j] } } }
    assert_equal(expected, c.to_a)
  end

  def test_matrix_times_vector
    ni, nk = 3, 4
    a = CArray.double(ni, nk).seq!(1)
    v = CArray.double(nk).seq!(1)
    result = CArray.double(ni)
    CArray.jit_contract { |i, k| result[i] = a[i,k] * v[k] }
    assert_equal((0...ni).map { |i| (0...nk).sum { |k| a[i,k] * v[k] } },
                 result.to_a)
  end

  # Every index summed over, into a one-cell box.
  def test_a_full_contraction
    ni, nk = 3, 4
    a = CArray.double(ni, nk).seq!(1)
    b = CArray.double(ni, nk).seq!(2)
    box = CArray.double(1)
    CArray.jit_contract { |i, k| box[0] = a[i,k] * b[i,k] }
    assert_equal((0...ni).sum { |i| (0...nk).sum { |k| a[i,k] * b[i,k] } }, box[0])
  end

  # One index on two axes of one array.
  def test_a_trace
    size = 4
    square = CArray.double(size, size).seq!(1)
    box = CArray.double(1)
    CArray.jit_contract { |i| box[0] = square[i,i] }
    assert_equal((0...size).sum { |i| square[i,i] }, box[0])
  end

  # `total[i] = a[i,k]` has nothing standing in for a sigma -- `k` appears
  # once -- so summing over it would be the assignment quietly meaning
  # something it does not say.  That is not the convention, and it is not
  # accepted.
  def test_a_sum_along_an_axis_is_not_a_contraction
    ni, nk = 3, 4
    a = CArray.double(ni, nk).seq!(1)
    total = CArray.double(ni)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, k| total[i] = a[i,k] }
    end
    assert_match(/`k` appears once, so it is free and must be on the left/,
                 error.message)
    assert_match(/jit_for/, error.message)
  end

  def test_an_index_summed_over_cannot_also_be_free
    ni, nk = 3, 4
    a = CArray.double(ni, nk).seq!(1)
    b = CArray.double(ni, nk).seq!(2)
    out = CArray.double(ni)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, k| out[i] = a[i,k] * b[i,k] }
    end
    assert_match(/`i` appears twice on the right, so it is summed over/,
                 error.message)
  end

  def test_an_index_that_names_no_axis
    a = CArray.double(3, 4).seq!(1)
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, k, z| out[i] = a[i,k] * a[i,k] }
    end
    assert_match(/`z` names no axis here/, error.message)
  end

  def test_an_index_appearing_more_than_twice
    a = CArray.double(3, 3, 3).seq!(1)
    out = CArray.double(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i| out[0] = a[i,i,i] }
    end
    assert_match(/appears more than twice/, error.message)
  end

  def test_a_double_contraction
    ni, nk, nl, nj = 3, 4, 3, 2
    left = CArray.double(ni, nk, nl).seq!(1)
    right = CArray.double(nl, nk, nj).seq!(1)
    result = CArray.double(ni, nj)
    CArray.jit_contract { |i, j, k, l| result[i,j] = left[i,k,l] * right[l,k,j] }
    expected = (0...ni).map { |i|
      (0...nj).map { |j|
        (0...nk).sum { |k| (0...nl).sum { |l| left[i,k,l] * right[l,k,j] } } } }
    assert_equal(expected, result.to_a)
  end

  # Nothing is summed over here; the convention covers that too.
  def test_an_outer_product
    ni, nj = 3, 2
    left = CArray.double(ni).seq!(1)
    right = CArray.double(nj).seq!(1)
    result = CArray.double(ni, nj)
    CArray.jit_contract { |i, j| result[i,j] = left[i] * right[j] }
    assert_equal((0...ni).map { |i| (0...nj).map { |j| left[i] * right[j] } },
                 result.to_a)
  end

  def test_the_sum_starts_from_a_zero_of_the_summand_type
    left = CArray.int64(2, 3).seq!(1)
    right = CArray.int64(3, 2).seq!(1)
    result = CArray.int64(2, 2)
    CArray.jit_contract { |i, j, k| result[i,j] = left[i,k] * right[k,j] }
    expected = (0...2).map { |i|
      (0...2).map { |j| (0...3).sum { |k| left[i,k] * right[k,j] } } }
    assert_equal(expected, result.to_a)
  end

  # ---- what it refuses ----

  def test_axes_of_different_extents
    a = CArray.double(3, 4).seq!(1)
    b = CArray.double(5, 2)
    c = CArray.double(3, 2)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, j, k| c[i,j] = a[i,k] * b[k,j] }
    end
    assert_match(/`k` addresses axes of different extents/, error.message)
    assert_match(/`a` axis 1 is 4/, error.message)
    assert_match(/axis 0 is 5/, error.message)
  end

  def test_an_array_that_is_both_written_and_read
    values = CArray.double(4).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, k| values[i] = values[k] * 2.0 }
    end
    assert_match(/recurrence rather than a contraction/, error.message)
  end

  def test_more_than_one_assignment
    a = CArray.double(3, 4).seq!(1)
    first = CArray.double(3)
    second = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, k| first[i] = a[i,k]; second[i] = a[i,k] }
    end
    assert_match(/a contraction is one expression/, error.message)
  end

  def test_an_offset_on_the_left
    a = CArray.double(4).seq!(1)
    out = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i| out[i+1] = a[i] }
    end
    assert_match(/writes the cell it is on, with no offset/, error.message)
  end

  def test_a_repeated_index_on_the_left
    a = CArray.double(4, 4).seq!(1)
    b = CArray.double(4, 4).seq!(2)
    out = CArray.double(4, 4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, j| out[i,i] = a[i,j] * b[j,i] }
    end
    assert_match(/an index can walk one of its axes only/, error.message)
  end

  # A captured integer pins an axis, so a contraction can be taken row by row
  # from an ordinary Ruby loop.  Its value is an argument, not part of the
  # kernel, so one compiled kernel serves every row.
  def test_a_contraction_per_row
    rows, columns = 5, 4
    a = CArray.double(rows, columns).seq!(1)
    b = CArray.double(rows, columns).seq!(2)
    out = CArray.double(rows)

    CArray::JIT.clear_registry
    rows.times { |i| out[i] = CArray.jit_contract { |k| a[i, k] * b[i, k] }[0] }

    assert_equal((0...rows).map { |i| (0...columns).sum { |k| a[i,k] * b[i,k] } },
                 out.to_a)
    assert_equal(1, CArray::JIT.registry.size,
                 "the pinned position is an argument, not part of the kernel")
  end

  def test_a_pinned_subscript_may_be_an_expression
    a = CArray.double(4, 3).seq!(1)
    b = CArray.double(4, 3).seq!(2)
    row = 1
    result = CArray.jit_contract { |k| a[row + 1, k] * b[row + 1, k] }
    assert_equal((0...3).sum { |k| a[2,k] * b[2,k] }, result[0])
  end

  def test_a_pinned_position_outside_the_array
    a = CArray.double(3, 4).seq!(1)
    b = CArray.double(3, 4).seq!(2)
    row = 99
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |k| a[row, k] * b[row, k] }
    end
    assert_match(/indexed at position 99 on axis 0, which has an extent of 3/,
                 error.message)
  end

  # An axis read at two independent positions -- `c[p,a] * c[p,b]` -- is how a
  # covariance is written, and for a while it was refused for no better reason
  # than that the analysis kept one index per axis.
  def test_an_axis_may_be_walked_by_two_indices
    c = CArray.double(5, 3).seq!(1)
    gram = CArray.jit_contract { |a, b, p| c[p,a] * c[p,b] }
    assert_equal([3, 3], gram.dim)
    expected = (0...3).map { |a| (0...3).map { |b| (0...5).sum { |p| c[p,a] * c[p,b] } } }
    assert_equal(expected, gram.to_a)
  end

  def test_the_two_indices_may_be_summed_rather_than_free
    c = CArray.double(4, 3).seq!(1)
    m = CArray.double(3, 3).seq!(2)
    # a and b both appear twice, so both are summed: c' M c, summed over rows.
    result = CArray.jit_contract { |p, a, b| c[p,a] * m[a,b] * c[p,b] }
    expected = (0...4).sum { |p|
      (0...3).sum { |a| (0...3).sum { |b| c[p,a] * m[a,b] * c[p,b] } } }
    assert_in_delta(expected, result[0], 1e-9)
  end

  def test_the_extents_of_both_indices_come_from_the_axis
    c = CArray.double(5, 3).seq!(1)
    weight = CArray.double(3, 4).seq!(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |a, b, p| c[p,a] * c[p,b] * weight[a,b] }
    end
    assert_match(/`b` addresses axes of different extents: /, error.message)
  end

  def test_a_block_is_required
    error = assert_raises(CArray::JIT::Unsupported) { CArray.jit_contract }
    assert_match(/needs a block/, error.message)
  end

end
