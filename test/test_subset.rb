require_relative "test_helper"

# Everything outside the recognized subset must come back as Unsupported --
# named and located.  There is no fallback: the method is called to make a
# per-cell computation fast, so answering slowly is not answering.
class TestSubset < Minitest::Test

  # `while` is in the subset now; what is still refused is the one loop that
  # can be read off the page as never ending.
  def test_while_true_with_no_way_out
    refuse("->(i) { while true; end; a[i] = 1.0 }",
           /holds no `break` and no `raise`, so it cannot end/)
  end

  def test_string_literal_in_an_expression
    refuse('->(i) { a[i] = a[i] + "text" }', /unsupported expression String/)
  end

  def test_array_literal
    refuse("->(i) { a[i] = [1, 2] }", /unsupported expression Array/)
  end

  # An inner loop runs over a range, which is what makes its extent knowable
  # before the kernel runs.
  def test_each_over_something_other_than_a_range
    refuse("->(i) { [1].each { |v| a[i] = v }; a[i] = 1.0 }",
           /an inner loop runs over a range/)
  end

  def test_unknown_method
    refuse("->(i) { a[i] = a[i].to_r }", /unsupported method `to_r`/)
  end

  def test_a_math_function_ruby_does_not_compute_the_c_way
    refuse("->(i) { a[i] = Math.frexp(a[i]) }",
           /Math.frexp is not compiled: Ruby's answer is a pair/)
  end

  # An inner index addresses a write as an outer one does: its loop states
  # its extent, so the cell it reaches is known and is bounds-checked with
  # the rest.  Every outer iteration lands on the same four cells here, which
  # is what the same Ruby loop does.
  def test_writing_through_an_inner_index
    values = CArray.double(4)
    CArray.jit_for(3) { |i| 4.times { |j| values[j] = j + 1.0 } }
    assert_equal([1.0, 2.0, 3.0, 4.0], values.to_a)
  end

  # A write is still addressed by an index or a value, not by a mixture of a
  # displaced one and a scatter -- there is no single reach to check that in
  # advance.
  def test_writing_at_a_displaced_index_and_a_computed_one
    work = CArray.double(3, 4)
    where = CArray.int32(3) { |i| i }
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| work[i+1, where[i]] = 1.0 }
    end
    assert_match(/`work\[\.\.\.\]` on the left of `=` is addressed by/, error.message)
  end

  # A displaced write is a write like any other -- `out[i + 1]` reaches a
  # distinct cell for each i, and the extent it needs is checked before the
  # first one.
  def test_a_displaced_write
    source = CArray.double(4).seq!(1)
    out = CArray.double(5)
    CArray.jit_for(4) { |i| out[i+1] = source[i] }
    assert_equal([0.0, 1.0, 2.0, 3.0, 4.0], out.to_a)
  end

  def test_a_displaced_write_is_bounds_checked_in_advance
    source = CArray.double(4).seq!(1)
    out = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| out[i+1] = source[i] }
    end
    assert_match(/`out` is indexed at `out\[i \+ 1\]`/, error.message)
    assert_equal([0.0] * 4, out.to_a, "nothing ran")
  end

  # A recurrence written forwards: the cell iteration i writes is the one
  # iteration i+1 reads, which is what the same Ruby loop does.
  def test_a_recurrence_through_a_displaced_write
    values = CArray.double(5)
    values[0] = 1.0
    CArray.jit_for(4) { |i| values[i+1] = values[i] + 1.0 }
    assert_equal([1.0, 2.0, 3.0, 4.0, 5.0], values.to_a)
  end

  def test_a_pinned_axis_may_be_written
    source = CArray.double(3, 4).seq!(1)
    out = CArray.double(3, 4)
    CArray.jit_for(3) { |i| out[i, 0] = source[i, 0] * 10.0 }
    assert_equal([[10.0, 0, 0, 0], [50.0, 0, 0, 0], [90.0, 0, 0, 0]], out.to_a)
  end

  # Every axis pinned means every iteration writes one cell, and the value
  # left behind is the last iteration's -- which is what the Ruby loop the
  # kernel stands for leaves behind too.
  def test_a_wholly_pinned_write_keeps_the_last_iteration
    values = CArray.double(5).seq!(1)
    box = CArray.double(1)
    CArray.jit_for(5) { |i| box[0] = values[i] }
    assert_equal(5.0, box[0])
  end

  # Which is how a reduction reaches a scalar without an outer loop to hang
  # the answer on.
  def test_a_reduction_into_a_pinned_cell
    values = CArray.double(5).seq!(1)
    box = CArray.double(1)
    CArray.jit_for(1) { |i|
      accumulator = 0.0
      5.times { |j| accumulator = accumulator + values[j] }
      box[0] = accumulator
    }
    assert_equal(15.0, box[0])
  end

  def test_a_captured_integer_may_pin_a_written_axis
    values = CArray.double(5).seq!(1)
    where = 2
    box = CArray.double(4)
    CArray.jit_for(5) { |i| box[where] = values[i] }
    assert_equal([0.0, 0.0, 5.0, 0.0], box.to_a)
  end

  # A pinned write is checked where a pinned read is: before the first cell,
  # so reaching outside is a message rather than a store past the end.
  def test_a_pinned_write_is_bounds_checked_in_advance
    values = CArray.double(5).seq!(1)
    box = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(5) { |i| box[7] = values[i] }
    end
    assert_match(/indexed at position 7 on axis 0, which has an extent of 3/,
                 error.message)
    assert_equal([0.0, 0.0, 0.0], box.to_a, "nothing ran")
  end

  def test_a_negative_pinned_write_is_refused
    values = CArray.double(5).seq!(1)
    box = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(5) { |i| box[-1] = values[i] }
    end
    assert_match(/indexed at position -1/, error.message)
  end

  # The same write laundered through a block-local was already accepted, as a
  # scatter.  Now the two spellings agree, and the pinned one is the cheaper:
  # its check happens once, not at every cell.
  def test_a_pinned_write_and_the_local_it_was_written_around_agree
    source = CArray.double(3, 4).seq!(1)
    pinned = CArray.double(3, 4)
    CArray.jit_for(3) { |i| pinned[i, 0] = source[i, 0] * 10.0 }
    scattered = CArray.double(3, 4)
    CArray.jit_for(3) { |i| z = 0; scattered[i, z] = source[i, 0] * 10.0 }
    assert_equal(scattered.to_a, pinned.to_a)
  end

  # Reading behind and ahead of the cell being written, in one kernel: cells
  # already passed hold new values and cells not yet reached hold old ones.
  # The extent states which is which, so this means what the Ruby loop it
  # stands for means, and there is nothing here to refuse.
  def test_offsets_on_both_sides_of_the_written_cell
    values = CArray.double(8).seq!
    CArray.jit_for(1...7) { |i| values[i] = values[i-1] + values[i+1] }

    expected = (0...8).map(&:to_f)
    (1...7).each { |i| expected[i] = expected[i-1] + expected[i+1] }
    assert_equal(expected, values.to_a)
  end

  # A subscript that walks with the loop is `i` or `i ± c`; one that does not
  # pins the axis, and is built from integer literals and captured integers.
  # A cell may be a subscript now -- that is a gather -- but only if it holds
  # an integer.  A float does not index an array in Ruby either.
  def test_a_subscript_built_from_a_float_cell
    refuse("->(i) { a[i] = a[a[i]] }", /a subscript is an integer/)
  end

  def test_a_subscript_built_from_a_float
    refuse("->(i) { a[i] = a[weight] }", /a subscript is an integer/,
           scalars: { :weight => 1.0 })
  end

  # As an expression `if` still needs an `else`; as a statement it does not,
  # because a cell nothing writes keeps what it had.
  def test_if_without_else_as_an_expression
    refuse("->(i) { a[i] = if a[i] > 0.0 then 1.0 end }",
           /has no value for every cell/)
  end

  def test_bare_array_name
    refuse("->(i) { a[i] = a + 1.0 }", /`a` is an array; index it/)
  end

  # `a[i, i]` is no longer a shape the write rule refuses: two axes, each
  # walked by an index at no offset, land on distinct cells -- it writes a
  # diagonal.  What is wrong with it below is the arity, and that is answered
  # against the array itself, where the rank is known.
  def test_wrong_number_of_indices
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| values[i, i] = 1.0 }
    end
    assert_match(/`values` has rank 1, but is indexed with 2 indices/,
                 error.message)
  end

  def test_a_diagonal_may_be_written
    out = CArray.double(3, 3)
    CArray.jit_for(3) { |i| out[i, i] = 1.0 }
    assert_equal([[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]], out.to_a)
  end

  def test_a_diagonal_write_is_bounds_checked_on_both_axes
    out = CArray.double(3, 2)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| out[i, i] = 1.0 }
    end
    assert_match(/cannot end at 3 for an extent of 2/, error.message)
  end

  def test_block_without_parameters
    refuse("->() { a[0] = 1.0 }", /takes the loop indices as its parameters/)
  end

  def test_not_a_block_literal
    refuse("1 + 1", /expected a block literal/)
  end

  def test_local_read_before_assignment
    refuse("->(i) { w = w + 1.0; a[i] = w }", /read before it is assigned/)
  end

  def test_kernel_that_writes_nothing
    refuse("->(i) { w = a[i] * 2.0 }", /writes to no array/)
  end

  def test_indexing_something_that_is_not_an_array
    refuse("->(i) { a[i] = s[i] }", /only a captured CArray may be indexed/,
           scalars: { :s => 1.0 })
  end

  # CArray::CoreExtensions puts postfix math on Float and Integer so that one
  # formula reads the same for a scalar and for a whole array.  A per-cell
  # kernel works on scalars pulled out of arrays, so a formula written that
  # way compiles as it stands.
  def test_postfix_math_is_accepted
    kernel = compile_kernel("->(i) { a[i] = (0.5 * a[i]).tanh }")
    assert_includes(kernel.c_source, "tanh(")
  end

  def test_postfix_math_covers_the_refinement_names
    %w[sqrt exp log log10 sin cos tan sinh cosh tanh
       asin acos atan asinh acosh atanh].each do |name|
      kernel = compile_kernel("->(i) { a[i] = a[i].#{name} }")
      assert_includes(kernel.c_source, "#{name}(", "postfix .#{name}")
    end
  end

  # C has functions by these names, and they exist precisely because
  # `exp(x) - 1` and `log(1 + x)` lose precision for small x -- which is what
  # the Ruby side computes.  Lowering them would change the numbers.
  def test_hand_rolled_refinement_methods_are_refused
    refuse("->(i) { a[i] = a[i].expm1 }", /not what C's expm1 computes/)
    refuse("->(i) { a[i] = a[i].log1p }", /not what C's log1p computes/)
  end

  def test_refinement_methods_without_a_c_counterpart_are_refused
    refuse("->(i) { a[i] = a[i].square }", /write x \* x/)
    refuse("->(i) { a[i] = a[i].rsqrt }", /1.0 \/ Math.sqrt/)
    refuse("->(i) { a[i] = a[i].rad }", /write the multiplication out/)
    refuse("->(i) { a[i] = a[i].signbit }", /write x < 0/)
    refuse("->(i) { a[i] = a[i].deg_360 }", /no math.h counterpart/)
  end

  def test_error_reports_location
    error = refuse("->(i) {\n  a[i] = a[i].to_r\n}", /unsupported method/)
    assert_match(/line 2/, error.message)
  end

  def test_proc_literal_is_accepted
    kernel = compile_kernel("proc { |i| a[i] = a[i-1] * 2.0 }")
    assert_includes(kernel.c_source, "a_s0")
  end

  # The message has to say what to do instead, because there is no fallback.
  def test_a_rejected_block_raises_from_jit_for
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(0...4) { |i| values[i] = values[i].to_r }
    end
    assert_match(/unsupported method `to_r`/, error.message)
  end

  # `rand` is Kernel's, so "not defined where the block was written" would be
  # a lie; and the reason it is not here says what to do instead.
  def test_a_draw_is_refused_by_name
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| values[i] = rand }
    end
    assert_match(/draws from a generator/, error.message)
    assert_match(/CArray#random!/, error.message)
  end

  def test_a_captured_generator_is_refused_by_name
    values = CArray.double(4)
    generator = Random.new(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| values[i] = generator.rand }
    end
    assert_match(/a generator draws in an order a kernel does not fix/,
                 error.message)
  end

  # `a = b * 2.0` reads the whole right-hand side and then assigns.  A kernel
  # walks cell by cell, which is the same thing until a cell it reads is one
  # it has written: two views of one array that share cells read the output
  # back as input.  A gather is copied before the loop and keeps the meaning;
  # a strided view is addressed in place, which is what left these wrong.
  def test_overlapping_views_read_the_values_the_pass_started_with
    values = CArray.double(8).seq!(0.0)
    low = values[0..6]
    high = values[1..7]
    reference = CArray.double(8).seq!(0.0)
    reference[1..7] = reference[0..6] * 2.0
    CArray.jit_each { high = low * 2.0 }
    assert_equal(reference.to_a, values.to_a)
  end

  def test_a_transpose_written_over_itself
    square = CArray.double(3, 3).seq!(1.0)
    transposed = square.transpose
    reference = CArray.double(3, 3).seq!(1.0)
    reference[] = reference.transpose * 1.0
    CArray.jit_each { square = transposed * 1.0 }
    assert_equal(reference.to_a, square.to_a)
  end

  # A cell read that is the cell written is Ruby's own reading, and is not
  # copied: `a = a + 1.0` means what it says.
  def test_an_array_read_and_written_as_itself_is_not_copied
    values = CArray.double(5).seq!(1.0)
    reference = CArray.double(5).seq!(1.0)
    reference[] = reference + 1.0
    CArray.jit_each { values = values + 1.0 }
    assert_equal(reference.to_a, values.to_a)
  end

  # And two views that share a root without sharing a cell still walk in
  # place: what is copied is decided by the root, and what is right is
  # decided by the answer.
  def test_disjoint_views_of_one_array
    grid = CArray.double(8, 8).seq!(0.0)
    first = grid[nil, 0]
    second = grid[nil, 1]
    reference = CArray.double(8, 8).seq!(0.0)
    reference[nil, 0] = reference[nil, 1] + 1.0
    CArray.jit_each { first = second + 1.0 }
    assert_equal(reference.to_a, grid.to_a)
  end

  # An array a kernel cannot walk is copied before the loop and copied back
  # after it.  For an expression over whole arrays that is the meaning; for
  # an indexed kernel the meaning is the loop, which reads a cell when it
  # reaches it -- so where the copy is of an array the loop also writes, the
  # copy is a photograph of cells that go on changing.
  def test_a_gather_of_an_array_the_loop_writes_is_refused
    values = CArray.double(8).seq!(1.0)
    reversed = values[CArray.int32(8) { |i| 7 - i }]
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(8) { |i| values[i] = reversed[i] + 1.0 }
    end
    assert_match(/would work on a copy of it taken before the loop/, error.message)
    assert_match(/`a\[order\[i\]\]`/, error.message)
    assert_equal((1..8).map(&:to_f), values.to_a, "nothing ran")
  end

  def test_a_gather_written_beside_its_own_root_is_refused
    values = CArray.double(6) { |i| i.to_f }
    gathered = values[CArray.int(6) { |i| i }]
    where = CArray.int(2) { |i| i }
    assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i| gathered[where[i]] = 100.0; values[4] = 7.0 }
    end
  end

  # A gather alone on its storage is not that case: what it scatters back at
  # the end, nothing in the loop was reading.
  def test_a_gather_written_alone_still_runs
    values = CArray.double(6).seq!(1.0)
    gathered = values[CArray.int32(6) { |i| 5 - i }]
    CArray.jit_for(6) { |i| gathered[i] = i * 1.0 }
    assert_equal([5.0, 4.0, 3.0, 2.0, 1.0, 0.0], values.to_a)
  end

  # And a gather of another array reads as it always did.
  def test_a_gather_of_another_array_still_runs
    source = CArray.double(6).seq!(1.0)
    gathered = source[CArray.int32(6) { |i| 5 - i }]
    out = CArray.double(6)
    CArray.jit_for(6) { |i| out[i] = gathered[i] + 1.0 }
    assert_equal([7.0, 6.0, 5.0, 4.0, 3.0, 2.0], out.to_a)
  end

end
