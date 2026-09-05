require_relative "test_helper"

# jit_each and jit_map: one fused expression over whole arrays, written the
# way CArray already spells "all of it".  Naming an index is what lets a
# kernel reach a neighbouring cell, and reaching one is what makes an extent
# and a direction matter -- so a computation that reaches none names no
# index, takes no extent, and is a method of its own rather than a shape
# jit_for falls into.  Which of the two is which: jit_map hands the value
# back, jit_each leaves it in the arrays the block wrote.
class TestWholeArrays < Minitest::Test

  # `a + b * c` is what the expression already means in CArray, so that is how
  # it is written; the kernel computes it at the cell it is on, in one pass
  # instead of three.  `a[]` says the same thing and is still accepted.
  def test_a_bare_array_name_is_the_array
    a = CArray.double(2, 3).seq!
    b = CArray.double(2, 3).seq!(10)
    c = CArray.double(2, 3).seq!(100)
    out = CArray.double(2, 3)
    CArray.jit_each { out = a + b * c }
    assert_equal((a + b * c).to_a, out.to_a)
  end

  def test_the_two_spellings_agree
    a = CArray.double(4).seq!
    b = CArray.double(4).seq!(10)
    bare = CArray.double(4)
    braced = CArray.double(4)
    CArray.jit_each { bare = a + b * 2.0 }
    CArray.jit_each { braced = a[] + b[] * 2.0 }
    assert_equal(braced.to_a, bare.to_a)
  end

  def test_a_bare_array_name_needs_an_index_where_there_are_indices
    values = CArray.double(4)
    other = CArray.double(4).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| values[i] = other }
    end
    assert_match(/`other` is an array; index it, as in `other\[i\]`/, error.message)
  end

  def test_matches_the_carray_expression
    a = CArray.double(2, 3).seq!
    b = CArray.double(2, 3).seq!(10)
    c = CArray.double(2, 3).seq!(100)
    out = CArray.double(2, 3)
    CArray.jit_each { out = a[] + b[] * c[] }
    assert_equal((a + b * c).to_a, out.to_a)
  end

  # No intermediate array for `b[] * c[]`: the whole expression is one loop.
  def test_the_expression_is_one_loop
    a = CArray.double(4).seq!
    b = CArray.double(4).seq!(10)
    c = CArray.double(4).seq!(100)
    out = CArray.double(4)
    kernel = CArray.jit_each { out = a[] + b[] * c[] }
    assert_equal(1, kernel.c_source.scan(/for \(int64_t/).size / 2,
                 "one loop per emitted body, and there are two bodies")
  end

  # A stretched axis is a stride of zero, and the kernel addresses by stride,
  # so broadcasting costs nothing and copies nothing.
  def test_shapes_are_broadcast
    row = CArray.double(1, 4).seq!
    column = CArray.double(3, 1).seq!(10)
    out = CArray.double(3, 4)
    CArray.jit_each { out = row[] + column[] }
    assert_equal((row + column).to_a, out.to_a)
  end

  def test_scalars_and_math
    values = CArray.double(5).seq!(1)
    result = CArray.double(5)
    gain = 2.5
    CArray.jit_each { result = Math.sqrt(values[]) * gain + 1.0 }
    5.times { |i|
      assert_bits_equal(Math.sqrt(values[i]) * gain + 1.0, result[i], "cell #{i}") }
  end

  # The rank is a property of the arrays, not of the block, so one expression
  # serves whatever shape it is given.
  def test_the_same_expression_serves_any_rank
    source = CArray.double(6).seq!
    result = CArray.double(6)
    CArray.jit_each { result = source[] * 2.0 }
    assert_equal([0.0, 2.0, 4.0, 6.0, 8.0, 10.0], result.to_a)

    source = CArray.double(2, 3, 4).seq!
    result = CArray.double(2, 3, 4)
    cubic = CArray.jit_each { result = source[] * 2.0 }
    assert_equal(46.0, result[1, 2, 3])
    assert_equal([2, 3, 4], result.dim, "the shape is the arrays', not the loop's")
  end

  # How many axes the loop has is a property of who drives it, not of the
  # expression: where CArray's sweep can run the pass it is compiled flat, and
  # where a stretched operand keeps it here the axes come back.  Either way
  # the arrays are untouched and the answer is the same.
  def test_the_rank_of_the_loop_follows_the_driver
    source = CArray.double(2, 3).seq!
    result = CArray.double(2, 3)
    swept = CArray.jit_each { result = source * 2.0 }
    assert_equal(CArray::JIT::Sweep.available? ? 1 : 2, swept.rank)

    row = CArray.double(1, 3).seq!(10.0)
    stretched = CArray.double(2, 3)
    kernel = CArray.jit_each { stretched = source * row }
    assert_equal(2, kernel.rank, "a stretched operand needs the axes back")
    assert_equal((source * row).to_a, stretched.to_a)
  end

  def test_a_stretched_array_cannot_be_written_to
    small = CArray.double(1, 4)
    large = CArray.double(3, 4).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { small = large[] * 2.0 }
    end
    assert_match(/stretched array cannot be written to/, error.message)
  end

  def test_masks_propagate
    values = CArray.double(4).seq!
    values[1] = UNDEF
    result = CArray.double(4)
    CArray.jit_each { result = values[] * 3.0 }
    assert_equal((values * 3.0).to_a, result.to_a)
  end

  def test_views_are_written_in_place
    matrix = CArray.double(4, 3)
    column = matrix[nil, 1]
    source = CArray.double(4).seq!(1)
    CArray.jit_each { column = source[] * 10.0 }
    assert_equal([10.0, 20.0, 30.0, 40.0], matrix[nil, 1].to_a)
    assert_equal([0.0] * 4, matrix[nil, 0].to_a)
  end

  # In a block with no indices, an indexed array is a different kernel shape
  # and has to be said so.
  def test_an_indexed_array_is_refused
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { values = values[0] }
    end
    assert_match(/no indices, so an array is spelled `a\[\]`/, error.message)
  end

  def test_a_block_reaching_no_array_is_refused
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { 1 + 1 }
    end
    assert_match(/reaches no array|writes to no array/, error.message)
  end

  # Each method says in its name what its block does, so a block written for
  # one of them is turned away by the other rather than quietly reinterpreted.
  def test_jit_for_refuses_a_block_that_names_no_index
    values = CArray.double(4)
    source = CArray.double(4).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for { values = source }
    end
    assert_match(/element-wise and belongs to jit_each/, error.message)
  end

  # An index belongs to jit_for, so a block written with one is turned away
  # rather than read as though the name meant a cell of some array.
  def test_jit_each_refuses_a_block_that_names_an_index
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { |i| values[i] = 1.0 }
    end
    assert_match(/takes no parameters/, error.message)
    assert_match(/`jit_for`/, error.message)
  end

  def test_an_index_without_an_extent_is_refused
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for { |i| values[i] = 1.0 }
    end
    assert_match(/names an index, so it needs an extent/, error.message)
  end

  # ---------- the value-naming spelling ----------
  #
  # One parameter per array, bound by position at the call site, each holding
  # the cell's value rather than a position.  The block's value is what every
  # cell of the result gets, so there is no output array to name and the
  # result is returned.
  #
  # The same shape of block that CArray.jit_function takes -- and not the same
  # thing, because here the loop is this compiler's and the body is inlined
  # into it.  What that buys shows up below: a captured value, and no call.

  def test_the_block_names_the_cells_of_the_arrays_given
    a = CArray.double(4).seq!(1.0)
    b = CArray.double(4).seq!(0.5, 0.5)
    result = CArray.jit_map { a + b * 2.0 }
    assert_equal([2.0, 4.0, 6.0, 8.0], result.to_a)
    assert_equal("float64", result.data_type_name)
  end

  # A c_function may close over nothing -- its parameters are its whole surface,
  # because the loop belongs to whoever calls it.  This body is inlined into
  # a loop of our own, so it may reach what any other kernel body may.
  def test_it_may_close_over_a_value
    a = CArray.double(3).seq!(1.0)
    scale = 10.0
    assert_equal([10.0, 20.0, 30.0], CArray.jit_map { a * scale }.to_a)
  end

  def test_it_may_call_a_c_function
    j0 = CArray.jit_extern("double j0(double)")
    a = CArray.double(3).seq!(1.0)
    result = CArray.jit_map { j0.call(a) }
    assert_arrays_bits_equal(a.convert { |v| j0.call(v) }, result)
  end

  def test_branches_and_math_reach_it_too
    a = CArray.double(4).seq!(1.0)
    result = CArray.jit_map { a > 2.0 ? Math.sqrt(a) : 0.0 }
    a.elements.times do |i|
      expected = a[i] > 2.0 ? Math.sqrt(a[i]) : 0.0
      assert_bits_equal(expected, result[i])
    end
  end

  # The result is typed from the block's value, not from the arrays given.
  def test_the_result_takes_the_type_of_the_value
    integers = CArray.int32(3).seq!(1)
    assert_equal("int64", CArray.jit_map { integers * 2 }.data_type_name)
    assert_equal("float64",
                 CArray.jit_map { integers * 0.5 }.data_type_name)
  end

  # A float32 expression computes in float32, so what collects it is a float32
  # array.  Collected into anything narrower the value is not what the kernel
  # computed, and `jit_each` into a float32 array of your own has always given
  # this answer -- the two spellings compute the same thing and now say so.
  def test_a_float32_value_is_collected_into_a_float32_array
    singles = CArray.float32(4) { |i| i + 0.5 }
    result = CArray.jit_map { singles * 2.0 }
    assert_equal("float32", result.data_type_name)
    assert_equal((singles * 2.0).to_a, result.to_a)
  end

  # uint64 computes in a type of its own precisely because int64 cannot carry
  # what it holds; collecting it as int64 wrapped the values it exists to keep.
  def test_a_uint64_value_is_collected_into_a_uint64_array
    large = CArray.uint64(3) { |i| 2**63 + i }
    result = CArray.jit_map { large + 1 }
    assert_equal("uint64", result.data_type_name)
    assert_equal((large + 1).to_a, result.to_a)
    assert(result.to_a.all? { |value| value > 2**63 }, "the values wrapped")
  end

  def test_shapes_are_broadcast_and_the_rank_comes_from_them
    matrix = CArray.double(2, 3).seq!
    row = CArray.double(1, 3).seq!(10.0, 10.0)
    result = CArray.jit_map { matrix * row }
    assert_equal([2, 3], result.dim)
    assert_equal((matrix * row).to_a, result.to_a)
  end

  def test_masks_propagate_as_they_do_everywhere_else
    a = CArray.double(4).seq!(1.0)
    a[2] = UNDEF
    b = CArray.double(4).seq!(0.5, 0.5)
    result = CArray.jit_map { a + b }
    assert_equal([false, false, true, false], result.is_masked.to_a)
    assert_equal((a + b).to_a, result.to_a)
  end

  # ---------- assigning to an array outside ----------

  # A name the block assigns is not free in it, so it is looked up where the
  # block was written: an array there is written, anything else is a local.
  def test_a_local_that_is_not_an_array_outside_stays_local
    a = CArray.double(3).seq!(1.0)
    out = CArray.double(3)
    CArray.jit_each { t = a * 2.0 ; out = t + 1.0 }
    assert_equal([3.0, 5.0, 7.0], out.to_a)
  end

  def test_more_than_one_array_is_written
    a = CArray.double(3).seq!(1.0)
    b = CArray.double(3).seq!(10.0)
    sum = CArray.double(3)
    difference = CArray.double(3)
    CArray.jit_each { sum = a + b ; difference = b - a }
    assert_equal((a + b).to_a, sum.to_a)
    assert_equal((b - a).to_a, difference.to_a)
  end

  # An array the block wrote is read back at the cell it just wrote, which is
  # the value the same Ruby statement would have left in it.
  def test_an_array_written_then_read
    a = CArray.double(3).seq!(1.0)
    first = CArray.double(3)
    second = CArray.double(3)
    CArray.jit_each { first = a * 2.0 ; second = first + 1.0 }
    assert_equal([2.0, 4.0, 6.0], first.to_a)
    assert_equal([3.0, 5.0, 7.0], second.to_a)
  end

  def test_a_written_array_of_the_wrong_shape
    a = CArray.double(3).seq!(1.0)
    single = CArray.double(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { single = a * 2.0 }
    end
    assert_match(/a stretched array cannot be written to/, error.message)
  end

  def test_a_written_array_gets_a_mask_when_the_pass_carries_one
    a = CArray.double(3).seq!(1.0)
    a[1] = UNDEF
    out = CArray.double(3)
    refute_predicate(out, :has_mask?)
    CArray.jit_each { out = a * 2.0 }
    assert_equal([false, true, false], out.is_masked.to_a)
  end

  # ---------- what comes back ----------

  def test_jit_each_returns_the_kernel_and_jit_map_the_result
    a = CArray.double(3).seq!(1.0)
    out = CArray.double(3)
    assert_kind_of(CArray::JIT::CompiledKernel, CArray.jit_each { out = a * 2.0 })
    assert_kind_of(CArray, CArray.jit_map { a * 2.0 })
  end

  # In Ruby an assignment has the value it assigned, so a block may write an
  # array of yours and hand the same value back.
  def test_jit_map_ending_in_an_assignment
    a = CArray.double(3).seq!(1.0)
    b = CArray.double(3).seq!(10.0)
    kept = CArray.double(3)
    returned = CArray.jit_map { kept = a + b }
    assert_equal((a + b).to_a, kept.to_a)
    assert_equal(kept.to_a, returned.to_a)
    refute_same(kept, returned, "the result is its own array")
  end

  def test_jit_map_may_write_along_the_way
    a = CArray.double(3).seq!(1.0)
    halves = CArray.double(3)
    doubled = CArray.jit_map { halves = a * 0.5 ; a * 2.0 }
    assert_equal([0.5, 1.0, 1.5], halves.to_a)
    assert_equal([2.0, 4.0, 6.0], doubled.to_a)
  end

  # jit_for is a different spelling and untouched by this one: there a name
  # the block assigns is a local, because the block says which cell it means.
  def test_jit_for_keeps_an_assignment_local
    a = CArray.double(3).seq!(1.0)
    out = CArray.double(3)
    other = CArray.double(3)
    CArray.jit_for(3) { |i| other = a[i] * 2.0 ; out[i] = other + 1.0 }
    assert_equal([3.0, 5.0, 7.0], out.to_a)
    assert_equal([0.0, 0.0, 0.0], other.to_a, "the array outside is untouched")
  end

  # ---------- what they refuse ----------

  # The positional value form is gone: it wrote each array twice and the
  # block is read anyway, so naming the arrays in the block says the same
  # thing once.
  def test_arrays_given_at_the_call_site
    a = CArray.double(3).seq!
    assert_raises(ArgumentError) { CArray.jit_map(a) { |x| x * 2.0 } }
    assert_raises(ArgumentError) { CArray.jit_each(a) { |x| x * 2.0 } }
  end

  def test_a_block_with_parameters
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { |x| x * 2.0 }
    end
    assert_match(/takes no parameters/, error.message)
    assert_match(/`jit_for`/, error.message, "says where indices belong")
  end

  # `out[] =` was how a block that had to run as Ruby said "the whole array".
  # The block is read instead, and every name in it is a cell, so the
  # assignment is Ruby's own.
  def test_the_bracket_spelling_points_at_the_assignment
    a = CArray.double(3).seq!
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { out[] = a * 2.0 }
    end
    assert_match(/`out\[\] = \.\.\.` writes the cell the loop is on/, error.message)
    assert_match(/`out = \.\.\.` says/, error.message)
  end

  # jit_each is for writing; a block that computes and writes nothing has
  # done nothing anyone can see, and jit_map is what asks for the value.
  def test_a_block_that_puts_its_value_nowhere
    a = CArray.double(3).seq!
    b = CArray.double(3).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { a + b }
    end
    assert_match(/puts it nowhere/, error.message)
    assert_match(/CArray\.jit_map/, error.message)
  end

end
