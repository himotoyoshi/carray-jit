require_relative "test_helper"

# The contraction convention: an index repeated in the term is summed.
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
    assert_match(/`i` is repeated on the right, so it is summed over/,
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

  # Three positions are not a pair to choose between: they are one index read
  # at three of them, and the sum runs along the cube's long diagonal.
  def test_an_index_appearing_more_than_twice
    size = 3
    cube = CArray.double(size, size, size).seq!(1)
    out = CArray.double(1)
    CArray.jit_contract { |i| out[0] = cube[i,i,i] }
    assert_equal((0...size).sum { |i| cube[i,i,i] }, out[0])
  end

  # The same index summed while another stays free, read at three positions
  # across two arrays.
  def test_an_index_repeated_across_arrays
    a = CArray.double(3, 3).seq!(1)
    result = CArray.jit_contract { |i, k| a[i,k] * a[k,k] }
    expected = (0...3).map { |i| (0...3).sum { |k| a[i,k] * a[k,k] } }
    assert_equal([3], result.dim)
    assert_equal(expected, result.to_a)
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

# The explicit form: the result's axes are named at the call site.
#
#   CArray.jit_contract(:p) { |k| x[p,k] * y[p,k] }
#
# That a repeated index is summed is the convention for *dimensions*,
# where two of them met is an inner product and there is no other reading.  An
# index that numbers things -- a point, a sample, a batch -- is not a
# dimension, and repeating it says "the same point" rather than "sum over
# points".  Naming the result's axes says which is meant, and then nothing is
# counted: a named index is free however often it appears, and every parameter
# left over is summed.
class TestContractNamedAxes < Minitest::Test

  # The index that numbers the points stays free, though it appears twice.
  def test_a_quantity_per_point
    np, nk = 4, 3
    x = CArray.double(np, nk).seq!(1)
    y = CArray.double(np, nk).seq!(0.5)
    result = CArray.jit_contract(:p) { |k| x[p,k] * y[p,k] }

    assert_equal([np], result.dim)
    expected = (0...np).map { |p| (0...nk).sum { |k| x[p,k] * y[p,k] } }
    assert_equal(expected, result.to_a)
  end

  # The same term is the trace under the convention and the diagonal when the
  # axis is named -- which is the split einsum makes between `ii` and `ii->i`.
  def test_the_diagonal_beside_the_trace
    square = CArray.double(4, 4).seq!(1)
    diagonal = CArray.jit_contract(:a) { square[a,a] }
    trace = CArray.jit_contract { |a| square[a,a] }

    assert_equal([4], diagonal.dim)
    assert_equal((0...4).map { |a| square[a,a] }, diagonal.to_a)
    assert_equal([1], trace.dim)
    assert_equal((0...4).sum { |a| square[a,a] }, trace[0])
  end

  # A batch of matrix products: `b` numbers the matrices and is not summed,
  # while `k` -- the block's one parameter -- is.
  def test_a_batch_of_products
    nb, ni, nk, nj = 2, 3, 4, 5
    left = CArray.double(nb, ni, nk).seq!(1)
    right = CArray.double(nb, nk, nj).seq!(0.5)
    result = CArray.jit_contract(:b, :i, :j) { |k| left[b,i,k] * right[b,k,j] }

    assert_equal([nb, ni, nj], result.dim)
    expected = (0...nb).map { |b|
      (0...ni).map { |i|
        (0...nj).map { |j| (0...nk).sum { |k| left[b,i,k] * right[b,k,j] } } } }
    assert_equal(expected, result.to_a)
  end

  # The argument list is the axis order, as the parameter list is under the
  # convention -- so naming the axes where the convention would have found
  # them anyway is how the result comes out in another order.
  def test_the_argument_order_gives_the_axis_order
    a = CArray.double(3, 4).seq!(1)
    b = CArray.double(4, 2).seq!(1)
    convention = CArray.jit_contract { |i, j, k| a[i,k] * b[k,j] }
    named = CArray.jit_contract(:i, :j) { |k| a[i,k] * b[k,j] }
    swapped = CArray.jit_contract(:j, :i) { |k| a[i,k] * b[k,j] }

    assert_equal(convention.to_a, named.to_a)
    assert_equal([2, 3], swapped.dim)
    assert_equal(convention.transpose.to_a, swapped.to_a)
  end

  # With every index named there is nothing left to sum, and the block takes
  # no parameters at all.
  def test_every_index_named_sums_nothing
    x = CArray.double(2, 3).seq!(1)
    result = CArray.jit_contract(:p, :k) { x[p,k] * x[p,k] }
    assert_equal([2, 3], result.dim)
    assert_equal(x.to_a.map { |row| row.map { |v| v * v } }, result.to_a)
  end

  # Assigning into an array of your own says where the result goes, as it
  # does under the convention.
  def test_the_assigned_form
    nb, ni, nk, nj = 2, 3, 4, 2
    left = CArray.double(nb, ni, nk).seq!(1)
    right = CArray.double(nb, nk, nj).seq!(0.5)
    out = CArray.double(nb, ni, nj)
    CArray.jit_contract(:b, :i, :j) { |k| out[b,i,j] = left[b,i,k] * right[b,k,j] }

    expected = CArray.jit_contract(:b, :i, :j) { |k| left[b,i,k] * right[b,k,j] }
    assert_equal(expected.to_a, out.to_a)
  end

  def test_the_named_form_keeps_integers_integral
    square = CArray.int64(3, 3).seq!(1)
    diagonal = CArray.jit_contract(:a) { square[a,a] }
    assert_equal("int64", diagonal.data_type_name)
    assert_equal([1, 5, 9], diagonal.to_a)
  end

  # A missing cell is missing in whatever the sum over it reaches.
  def test_a_masked_cell
    x = CArray.double(2, 3).seq!(1)
    x[0,1] = UNDEF
    result = CArray.jit_contract(:p) { |k| x[p,k] * x[p,k] }
    assert_equal(UNDEF, result[0])
    assert_equal((0...3).sum { |k| x[1,k] * x[1,k] }, result[1])
  end

  # The naming is not part of the block's source, so it has to be part of what
  # the cache keeps kernels apart by.
  def test_the_same_block_under_two_namings
    x = CArray.double(2, 3).seq!(1)
    2.times do
      assert_equal([2], CArray.jit_contract(:p) { |k| x[p,k] * x[p,k] }.dim)
      assert_equal([2, 3], CArray.jit_contract(:p, :k) { x[p,k] * x[p,k] }.dim)
      assert_equal([1], CArray.jit_contract { |p, k| x[p,k] * x[p,k] }.dim)
    end
  end

  # An index is one thing or the other: an axis of the result, or summed.
  def test_an_index_named_and_also_a_parameter
    x = CArray.double(2, 3).seq!(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract(:p) { |p, k| x[p,k] * x[p,k] }
    end
    assert_match(/`p` is named as an axis of the result and again as a block parameter/,
                 error.message)
  end

  def test_a_named_axis_that_names_no_axis
    a = CArray.double(3, 4).seq!(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract(:q, :i) { |k| a[i,k] }
    end
    assert_match(/`q` names no axis here/, error.message)
  end

  def test_the_extents_still_come_from_the_axes
    a = CArray.double(3, 4).seq!(1)
    b = CArray.double(2, 4).seq!(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract(:p) { |k| a[p,k] * b[p,k] }
    end
    assert_match(/`p` addresses axes of different extents: /, error.message)
  end

  def test_the_arguments_are_symbols
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract("p") { |k| k }
    end
    assert_match(/named as symbols/, error.message)
  end

  def test_an_axis_named_twice
    x = CArray.double(2, 3).seq!(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract(:p, :p) { |k| x[p,k] * x[p,k] }
    end
    assert_match(/`p` names more than one axis of the result/, error.message)
  end

  # The convention refuses a sum along an axis because there is nothing in
  # `a[i,k]` standing in for a sigma.  Naming the result's axes is that
  # statement, so the same term is accepted -- `sum(axis:)` is still the
  # faster way to say it.
  def test_a_sum_along_an_axis_once_the_axes_are_named
    a = CArray.double(3, 4).seq!(1)
    assert_equal(a.sum(axis: 1).to_a,
                 CArray.jit_contract(:i) { |k| a[i,k] }.to_a)
  end

  # Where the convention refuses, it says what naming the axis would do.
  def test_the_conventions_refusal_points_here
    a = CArray.double(3, 4).seq!(1)
    b = CArray.double(3, 4).seq!(2)
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, k| out[i] = a[i,k] * b[i,k] }
    end
    assert_match(/`i` is repeated on the right, so it is summed over/,
                 error.message)
    assert_match(/CArray\.jit_contract\(:i\)/, error.message)
  end

  # The hint names the whole left-hand side, which is what the result's axes
  # are -- not only the index the convention tripped over.
  def test_the_refusal_names_every_axis_of_the_result
    a = CArray.double(3, 4).seq!(1)
    b = CArray.double(3, 4).seq!(2)
    v = CArray.double(2).seq!(1)
    out = CArray.double(3, 2)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, j, k| out[i,j] = a[i,k] * b[i,k] * v[j] }
    end
    assert_match(/CArray\.jit_contract\(:i, :j\)/, error.message)
  end

end
