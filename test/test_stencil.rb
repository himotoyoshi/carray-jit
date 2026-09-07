require_relative "test_helper"

# jit_stencil: every cell from the ones around it, with the loop implied.
#
# The block's parameters are windows onto the arrays it was given, so `a[0, 0]`
# is the cell and `a[-1, 1]` its neighbour. Naming a window rather than an
# index is what lets the edge be said at the call: where the window falls off
# the array there is no cell to read, and `border:` answers for those rather
# than the extents doing it silently.
#
# The reference throughout is the same stencil written with jit_for over the
# interior, compared bitwise -- the two spell the same loop, and the point of
# the window is that they compile to it.
class TestStencil < Minitest::Test

  def five_point (source, out)
    rows, columns = source.dim
    CArray.jit_for(1...(rows-1), 1...(columns-1)) { |i, j|
      out[i, j] = 0.25 * (source[i-1, j] + source[i+1, j] +
                          source[i, j-1] + source[i, j+1])
    }
    out
  end

  def test_it_computes_what_the_written_out_loop_computes
    source = CArray.double(6, 8) { |i, j| Math.sin(i * 0.3) * Math.cos(j * 0.2) }
    written = five_point(source, CArray.double(6, 8))
    result = CArray.jit_stencil(source, border: :skip,
                                into: CArray.double(6, 8)) { |a|
      0.25 * (a[-1, 0] + a[1, 0] + a[0, -1] + a[0, 1])
    }
    assert_arrays_bits_equal(written, result)
  end

  def test_the_result_has_the_shape_of_the_arrays
    source = CArray.double(4, 7).seq!(1.0)
    assert_equal([4, 7], CArray.jit_stencil(source) { |a| a[0, 0] }.dim)
  end

  # ---------- the border ----------

  # The default says what happened rather than leaving a number that cannot
  # be told from a computed one: the cells the window could not sit on come
  # back missing.
  def test_the_border_is_missing_by_default
    source = CArray.double(5, 6).seq!(1.0)
    result = CArray.jit_stencil(source) { |a|
      0.25 * (a[-1, 0] + a[1, 0] + a[0, -1] + a[0, 1])
    }
    assert_equal([true] * 6, result.is_masked[0, nil].to_a)
    assert_equal([true] * 6, result.is_masked[-1, nil].to_a)
    assert_equal([true] * 5, result.is_masked[nil, 0].to_a)
    assert_equal([true] * 5, result.is_masked[nil, -1].to_a)
    assert_equal(18, result.count_masked)
    refute(result.is_masked[2, 2], "the interior was computed")
    assert_in_delta(15.0, result[2, 2], 0.0)
  end

  # `:skip` is the older spelling's behaviour -- the extents wrote the
  # interior and said nothing about the rest -- and is what to ask for when
  # the border is yours to fill.
  def test_skip_leaves_the_border_as_it_was_found
    source = CArray.double(5, 6).seq!(1.0)
    into = CArray.double(5, 6).seq!(-1.0, 0.0)
    CArray.jit_stencil(source, border: :skip, into: into) { |a|
      0.25 * (a[-1, 0] + a[1, 0] + a[0, -1] + a[0, 1])
    }
    assert_equal([-1.0] * 6, into[0, nil].to_a)
    refute_predicate(into, :has_mask?)
    assert_in_delta(15.0, into[2, 2], 0.0)
  end

  # The frame is where the window would not fit, so an offset reaching two
  # cells one way and none the other takes two cells off that side alone.
  def test_the_frame_is_what_the_window_reaches
    source = CArray.double(5, 6).seq!(1.0)
    result = CArray.jit_stencil(source) { |a| a[0, 0] + a[0, 2] }
    assert_equal([false, false, false, false, true, true],
                 result.is_masked[2, nil].to_a)
    assert_equal([false] * 5, result.is_masked[nil, 0].to_a)
  end

  # ---------- the borders that are computed ----------

  # The other three say what a read outside the array gives, so the frame is
  # computed rather than marked. The reference is the same stencil in Ruby
  # over every cell, with the rule written out -- the frame is where the two
  # could differ, and it is the whole point.
  def bordered (rule)
    rows, columns = 5, 6
    source = CArray.double(rows, columns) { |i, j| (i * 10 + j).to_f }
    read = lambda { |i, j|
      case rule
      when :clamp then source[i.clamp(0, rows - 1), j.clamp(0, columns - 1)]
      when :wrap  then source[i % rows, j % columns]
      when :zero
        i.between?(0, rows - 1) && j.between?(0, columns - 1) ? source[i, j] : 0.0
      end
    }
    reference = CArray.double(rows, columns) { |i, j|
      0.25 * (read.call(i-1, j) + read.call(i+1, j) +
              read.call(i, j-1) + read.call(i, j+1))
    }
    result = CArray.jit_stencil(source, border: rule) { |a|
      0.25 * (a[-1, 0] + a[1, 0] + a[0, -1] + a[0, 1])
    }
    [reference, result]
  end

  def test_clamp_reads_the_nearest_cell_it_has
    assert_arrays_bits_equal(*bordered(:clamp))
  end

  def test_wrap_comes_back_on_the_other_side
    assert_arrays_bits_equal(*bordered(:wrap))
  end

  def test_zero_reads_nothing_rather_than_somewhere_else
    assert_arrays_bits_equal(*bordered(:zero))
  end

  # A computed border computes every cell, so nothing is left missing.
  def test_a_computed_border_leaves_no_cell_missing
    source = CArray.double(5, 6).seq!(1.0)
    result = CArray.jit_stencil(source, border: :clamp) { |a| a[-1, 0] + a[0, 1] }
    assert_equal(0, result.count_masked)
  end

  # A window two cells wide on one axis and none on the other: the frame it
  # leaves is two rows at one end, and the rule reaches over both.
  def test_a_wider_window_reaches_as_far_as_it_says
    rows, columns = 5, 4
    source = CArray.double(rows, columns) { |i, j| (i * 10 + j).to_f }
    result = CArray.jit_stencil(source, border: :wrap) { |a| a[-2, 0] + a[0, 3] }
    reference = CArray.double(rows, columns) { |i, j|
      source[(i - 2) % rows, j] + source[i, (j + 3) % columns]
    }
    assert_arrays_bits_equal(reference, result)
  end

  def test_one_dimension_with_a_rule
    series = CArray.double(6).seq!(1.0)
    result = CArray.jit_stencil(series, border: :clamp) { |a|
      (a[-1] + a[0] + a[1]) / 3.0
    }
    assert_in_delta((1.0 + 1.0 + 2.0) / 3.0, result[0], 0.0)
    assert_in_delta((5.0 + 6.0 + 6.0) / 3.0, result[-1], 0.0)
    assert_in_delta(3.0, result[2], 0.0)
  end

  # The frame is walked as boxes, and a cell in two of them would be computed
  # twice -- which is invisible in the answer and not invisible in what it
  # costs, so it is checked here rather than inferred from one.
  def test_the_frame_is_cut_into_boxes_that_do_not_overlap
    shape = [5, 6]
    bounds = [[1, 4, 1], [1, 5, 1]]
    covered = []
    CArray::JIT.send(:frame_boxes, bounds, shape).each do |box|
      (box[0][0]...box[0][1]).each do |i|
        (box[1][0]...box[1][1]).each { |j| covered << [i, j] }
      end
    end
    frame = (0...shape[0]).to_a.product((0...shape[1]).to_a).reject { |i, j|
      i.between?(1, 3) && j.between?(1, 4)
    }
    assert_equal(frame.sort, covered.sort)
    assert_equal(covered.size, covered.uniq.size, "a cell is in two boxes")
  end

  # ---------- what the block may reach ----------

  def test_one_dimension
    series = CArray.double(6).seq!(1.0)
    result = CArray.jit_stencil(series) { |a| (a[-1] + a[0] + a[1]) / 3.0 }
    assert_equal([UNDEF, 2.0, 3.0, 4.0, 5.0, UNDEF], result.to_a)
  end

  # The windows are the block's parameters in the order the arrays were given,
  # and they shadow whatever those names hold outside.
  def test_two_arrays_are_two_windows
    u = CArray.double(4, 4).seq!(1.0)
    k = CArray.double(4, 4).seq!(0.5, 0.5)
    result = CArray.jit_stencil(u, k) { |u, k| u[0, 0] + k[-1, 0] }
    assert_in_delta(u[2, 2] + k[1, 2], result[2, 2], 0.0)
  end

  # An array the block closed over rather than was given has no window, so it
  # is read at the cell the loop is on -- what a bare name means wherever the
  # loop is this compiler's.
  def test_a_captured_array_is_read_at_the_cell
    source = CArray.double(4, 5).seq!(1.0)
    weight = CArray.double(4, 5).seq!(100.0)
    result = CArray.jit_stencil(source) { |a| a[0, 0] + weight }
    assert_in_delta(source[2, 2] + weight[2, 2], result[2, 2], 0.0)
  end

  def test_a_captured_scalar
    source = CArray.double(4, 5).seq!(1.0)
    scale = 3.0
    result = CArray.jit_stencil(source) { |a| a[0, 0] * scale }
    assert_in_delta(source[2, 2] * 3.0, result[2, 2], 0.0)
  end

  # ---------- the array that comes back ----------

  def test_the_type_is_the_values_unless_it_is_asked_for
    source = CArray.int32(4, 4).seq!(1)
    assert_equal("int64", CArray.jit_stencil(source) { |a| a[0, 0] * 2 }.data_type_name)
    assert_equal("float32",
                 CArray.jit_stencil(source, type: :float32) { |a| a[0, 0] * 2 }
                   .data_type_name)
  end

  def test_into_writes_an_array_of_your_own
    source = CArray.double(4, 4).seq!(1.0)
    into = CArray.int32(4, 4)
    returned = CArray.jit_stencil(source, into: into, border: :skip) { |a| a[0, 0] }
    assert_same(into, returned)
    assert_equal(source[2, 2].to_i, into[2, 2])
  end

  # Writing into the array the window reads is not a pass over it: the cell
  # written is a neighbour a later cell reaches, so what comes back depends on
  # the order the cells were taken in.  The answer was wrong and said nothing.
  def test_into_may_not_be_the_array_the_window_reads
    source = CArray.double(6) { |i| (i + 1.0) ** 2 }
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(source, into: source) { |a| (a[-1] + a[0] + a[1]) / 3 }
    end
    assert_match(/a cell written there is one a later cell reads/, error.message)

    view = source[nil]
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(source, into: view) { |a| (a[-1] + a[0] + a[1]) / 3 }
    end
    assert_match(/a stencil writes into an array of its own/, error.message)
  end

  # The question is about the window onto the array being written, not about
  # the widest window in the kernel: one array may be read at its centre while
  # another is reached into, and then writing the first in place is safe.
  def test_into_may_be_a_window_that_reaches_nowhere_beside_one_that_does
    reached = CArray.double(6, 8) { |i, j| i + j }
    centred = CArray.double(6, 8) { |i, j| i * j }
    expected = CArray.double(6, 8) { |i, j|
      i.zero? || i == 5 ? centred[i,j] : 0.25 * (reached[i-1,j] + reached[i+1,j]) + centred[i,j]
    }
    returned = CArray.jit_stencil(reached, centred, border: :skip, into: centred) { |r, c|
      0.25 * (r[-1, 0] + r[1, 0]) + c[0, 0]
    }
    assert_same(centred, returned)
    assert_equal(expected.to_a, centred.to_a)
  end

  # A window that reaches nowhere reads only the cell it is on, so there is no
  # later cell to disturb and writing in place says what it means.
  def test_into_may_be_the_array_when_the_window_reaches_nowhere
    source = CArray.double(4).seq!(1.0)
    returned = CArray.jit_stencil(source, into: source) { |a| a[0] * 2 }
    assert_same(source, returned)
    assert_equal([2.0, 4.0, 6.0, 8.0], source.to_a)
  end

  # A missing cell reaches as far as the window does, and no further: the
  # cell itself is computed from cells that are all there.
  def test_a_missing_cell_propagates_through_the_window
    source = CArray.double(5, 5).seq!(1.0)
    source[2, 2] = UNDEF
    result = CArray.jit_stencil(source) { |a|
      0.25 * (a[-1, 0] + a[1, 0] + a[0, -1] + a[0, 1])
    }
    [[1, 2], [3, 2], [2, 1], [2, 3]].each do |i, j|
      assert(result.is_masked[i, j], "the missing cell did not reach [#{i}, #{j}]")
    end
    refute(result.is_masked[2, 2], "the cell itself reads no missing neighbour")
  end

  # ---------- what is refused ----------

  def test_an_offset_is_written_out
    source = CArray.double(4, 4).seq!(1.0)
    step = 1
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(source) { |a| a[step, 0] }
    end
    assert_match(/offsets are written out/, error.message)
    assert_match(/jit_for/, error.message)
  end

  # Arithmetic over literals is a literal: the number is known here, and
  # writing it as the formula it came from says more than the number does.
  # What it is not is a value -- nothing that has to be read to be known.
  def test_an_offset_may_be_arithmetic_over_literals
    source = CArray.double(9).seq!(1.0)
    assert_in_delta(3.0,
                    CArray.jit_stencil(source, border: :clamp) { |w| w[-1-1] }[4],
                    0.0)
    assert_in_delta(7.0,
                    CArray.jit_stencil(source, border: :clamp) { |w| w[-(1+1)*-1] }[4],
                    0.0)
    # And the reach is the folded number, so the frame is the one a written
    # out `-2` would have left.
    folded = CArray.jit_stencil(source) { |w| w[-1-1] + w[1+1] }
    assert_equal(4, folded.count_masked)
  end

  def test_an_offset_is_not_a_value_however_constant_it_looks
    source = CArray.double(9).seq!(1.0)
    radius = 2
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(source) { |w| w[-radius] }
    end
    assert_match(/written out/, error.message)
  end

  def test_a_window_takes_one_offset_per_axis
    source = CArray.double(4, 4).seq!(1.0)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(source) { |a| a[0] }
    end
    assert_match(/rank-2 array, so it takes 2 offsets/, error.message)
  end

  def test_the_arrays_have_the_same_shape
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(CArray.double(5, 6), CArray.double(4, 4)) { |u, v|
        u[0, 0] + v[0, 0]
      }
    end
    assert_match(/\[5, 6\].*\[4, 4\]/, error.message)
    assert_match(/same shape/, error.message)
  end

  def test_a_window_wider_than_the_array
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(CArray.double(2, 2)) { |a| a[-2, 0] + a[2, 0] }
    end
    assert_match(/no cell where the window is inside the array/, error.message)
  end

  def test_a_border_that_is_not_one
    source = CArray.double(4, 4).seq!(1.0)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(source, border: :nonsense) { |a| a[0, 0] }
    end
    assert_match(/`border:` is/, error.message)
    assert_match(/:mask, :skip, :zero, :clamp, :wrap/, error.message)
  end

  def test_a_type_and_an_array_to_write_into_are_one_too_many
    source = CArray.double(4, 4).seq!(1.0)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(source, type: :float32, into: CArray.double(4, 4)) { |a|
        a[0, 0]
      }
    end
    assert_match(/one or the other/, error.message)
  end

  def test_the_block_names_a_window_for_each_array
    source = CArray.double(4, 4).seq!(1.0)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(source) { |a, b| a[0, 0] + b[0, 0] }
    end
    assert_match(/2 windows, and 1 array was given/, error.message)
  end

  def test_it_needs_an_array
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil { |a| a[0, 0] }
    end
    assert_match(/takes the arrays its block has windows onto/, error.message)
  end

  # ---------- what the interior pays for ----------

  # The loops leave as soon as a cell has reported, and the test that does it
  # belongs to kernels that can report. A windowed kernel carries every extent
  # of its arrays so the border rule can be applied against them, which says
  # nothing about whether a cell can fail -- and for a while it was what the
  # guard was keyed on, so a stencil's interior tested a flag nothing in it
  # could set.
  def compile_window (body, border:, type: "int32")
    CArray::JIT.compile("proc { |w| #{body} }",
                        array_names: [:w, :__map_result],
                        storage_types: { :w => type, :__map_result => type },
                        scalar_values: {},
                        rank: 2, windows: [:w], border: border,
                        map: true, result: :__map_result)
  end

  def test_a_bordered_interior_does_not_test_a_flag_it_cannot_set
    kernel = compile_window("w[-1, 0] + w[1, 0]", border: :wrap)
    refute_match(/if \( \*error \) break;/, kernel.c_source)
  end

  def test_a_bordered_kernel_that_can_report_still_leaves_when_it_has
    # Integer division is the reportable one: a zero divisor stops the loop,
    # as it stops the Ruby loop it stands for.
    kernel = compile_window("w[-1, 0] / w[1, 0]", border: :wrap)
    assert_match(/if \( \*error \) break;/, kernel.c_source)
  end
end
