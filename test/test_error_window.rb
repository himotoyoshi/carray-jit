require_relative "test_helper"
require "fiddle"

# Handing the address out.
#
# `#call` is one call and answers for it. A library given `#pointer` calls as
# often as it likes, and the failure it may run into belongs to the whole of
# that -- so the window is what the flag is put down for, and what it is read
# for. These pin the shape of that window: that a failure survives a caller
# who does not stop, that the body stops answering once it has failed, and
# that nothing done inside a window quietly disarms it.
class TestErrorWindow < Minitest::Test

  # Reached the way a library reaches it: the address, and nothing else.
  def foreign (function)
    Fiddle::Function.new(function.pointer, function.argument_types,
                         function.return_type.fiddle)
  end

  def always_raising
    CArray.jit_function("double always(double x)") { |x|
      raise "always"
      x * 2.0
    }
  end

  def raising_below_zero
    CArray.jit_function("double below(double x)") { |x|
      raise "x is negative" if x < 0.0
      x * 2.0
    }
  end

  # ---------- the window itself ----------

  def test_error_survives_a_foreign_caller
    f = always_raising
    raw = foreign(f)
    f.clear_error
    5.times { raw.call(1.0) }
    error = assert_raises(RuntimeError) { f.report_error }
    assert_equal("always", error.message)
  end

  def test_report_is_quiet_when_nothing_failed
    f = raising_below_zero
    raw = foreign(f)
    f.clear_error
    assert_equal(4.0, raw.call(2.0))
    assert_nil(f.report_error)
  end

  def test_report_does_not_put_the_flag_down
    f = always_raising
    f.clear_error
    foreign(f).call(1.0)
    assert_raises(RuntimeError) { f.report_error }
    assert_raises(RuntimeError) { f.report_error }
  end

  def test_the_flag_does_not_leak_between_windows
    f = raising_below_zero
    raw = foreign(f)
    f.clear_error
    raw.call(-1.0)
    assert_raises(RuntimeError) { f.report_error }

    f.clear_error
    assert_equal(4.0, raw.call(2.0))
    assert_nil(f.report_error)
  end

  # ---------- the body does no more work ----------

  def test_a_failed_body_does_no_more_work
    f = raising_below_zero
    raw = foreign(f)
    f.clear_error
    assert_equal(4.0, raw.call(2.0))
    assert_equal(0.0, raw.call(-1.0))
    # Without the gate the body would skip the report it has already made and
    # answer 6.0 here -- the value an adaptive routine converges on.
    assert_equal(0.0, raw.call(3.0))
    assert_equal(0.0, raw.call(5.0))
    assert_raises(RuntimeError) { f.report_error }
  end

  def test_the_gate_stands_in_the_file_and_not_in_the_definition
    f = raising_below_zero
    assert_match(/if \( carray_jit_error \) return 0;/, f.c_source)
    refute_match(/if \( carray_jit_error \)/, f.definition)
  end

  def test_a_failed_void_body_writes_nothing
    f = CArray.jit_function("void store(double out[], double x)") { |out, x|
      raise "x is negative" if x < 0.0
      out[0] = x * 2.0
    }
    raw = foreign(f)
    box = CArray.double(1)
    box[0] = 99.0

    f.clear_error
    CArray::JIT::Access.open([box], [true], [nil], [nil]) do |bases|
      address = Fiddle::Pointer.new(bases[0][:pointer])
      raw.call(address, -1.0)
      assert_equal(99.0, box[0])
      raw.call(address, 3.0)
      # The out-parameter is left alone rather than filled with a value the
      # window is no longer entitled to.
      assert_equal(99.0, box[0])
    end
    assert_raises(RuntimeError) { f.report_error }
  end

  def test_a_void_body_is_gated_without_returning_a_value
    f = CArray.jit_function("void store(double out[], double x)") { |out, x|
      raise "no" if x < 0.0
      out[0] = x
    }
    assert_match(/if \( carray_jit_error \) return;/, f.c_source)
    refute_match(/return 0;/, f.c_source)
  end

  # ---------- #call borrows the flag and puts it back ----------

  def test_a_call_inside_a_window_leaves_the_window_armed
    f = raising_below_zero
    raw = foreign(f)
    error = assert_raises(RuntimeError) do
      f.watching do
        raw.call(-1.0)
        # The natural way to write a driver: check a value from Ruby, then
        # let the library have the address.  The call borrows the flag, so it
        # gets past the gate and does its own work -- and puts the window's
        # failure back where it found it.
        assert_equal(4.0, f.call(2.0))
      end
    end
    assert_equal("x is negative", error.message)
  end

  def test_a_call_answers_only_for_itself
    f = raising_below_zero
    assert_raises(RuntimeError) do
      f.watching do
        assert_equal(4.0, f.call(2.0))
        assert_raises(RuntimeError) { f.call(-1.0) }
        # The window has seen a failure; this call has not.
        assert_equal(6.0, f.call(3.0))
        raise "reached the end"
      end
    end
  end

  def test_a_call_leaves_a_clean_window_clean
    f = raising_below_zero
    f.watching do
      assert_raises(RuntimeError) { f.call(-1.0) }
    end
  end

  def test_a_rejected_call_does_not_disturb_the_window
    f = raising_below_zero
    raw = foreign(f)
    error = assert_raises(RuntimeError) do
      f.watching do
        raw.call(-1.0)
        assert_raises(ArgumentError) { f.call(1.0, 2.0) }
      end
    end
    assert_equal("x is negative", error.message)
  end

  def test_a_kernel_run_inside_a_window_leaves_it_armed
    f = raising_below_zero
    raw = foreign(f)
    a = CArray.double(4).seq!
    out = CArray.double(4)
    error = assert_raises(RuntimeError) do
      f.watching do
        raw.call(-1.0)
        CArray.jit_for(4) { |i| out[i] = a[i] * 2.0 }
      end
    end
    assert_equal("x is negative", error.message)
  end

  def test_another_function_does_not_share_the_window
    f = raising_below_zero
    g = CArray.jit_function("double twice(double x)") { |x|
      raise "g refuses" if x > 100.0
      x + x
    }
    raw = foreign(f)
    error = assert_raises(RuntimeError) do
      f.watching do
        raw.call(-1.0)
        assert_equal(6.0, g.call(3.0))
      end
    end
    assert_equal("x is negative", error.message)
  end

  # ---------- windows nest ----------

  def test_windows_nest
    f = raising_below_zero
    raw = foreign(f)
    error = assert_raises(RuntimeError) do
      f.watching do
        raw.call(-1.0)
        # The inner window borrows too, so the address works inside it.
        f.watching { assert_equal(4.0, raw.call(2.0)) }
      end
    end
    assert_equal("x is negative", error.message)
  end

  def test_an_inner_window_answers_for_its_own_block
    f = raising_below_zero
    raw = foreign(f)
    f.watching do
      error = assert_raises(RuntimeError) do
        f.watching { raw.call(-1.0) }
      end
      assert_equal("x is negative", error.message)
    end
  end

  # ---------- what a window promises when the block does not return ----------

  def test_a_window_is_restored_when_the_block_raises
    f = raising_below_zero
    raw = foreign(f)
    assert_raises(ArgumentError) { f.watching { raise ArgumentError, "mine" } }
    # Nothing stands, so the function is still usable.
    f.clear_error
    assert_equal(4.0, raw.call(2.0))
    assert_nil(f.report_error)
  end

  def test_the_body_failure_outranks_the_outer_exception
    f = raising_below_zero
    raw = foreign(f)
    # What a library does when the body hands it a stand-in: complain about
    # the consequence.  The cause is the flag.
    error = assert_raises(RuntimeError) do
      f.watching do
        raw.call(-1.0)
        raise ArgumentError, "the endpoints do not straddle"
      end
    end
    assert_equal("x is negative", error.message)
  end

  def test_the_outer_exception_stands_where_nothing_failed
    f = raising_below_zero
    error = assert_raises(ArgumentError) do
      f.watching { raise ArgumentError, "the endpoints do not straddle" }
    end
    assert_equal("the endpoints do not straddle", error.message)
  end

  def test_a_window_answers_with_the_value_of_its_block
    f = raising_below_zero
    assert_equal(42, f.watching { 42 })
  end

  # ---------- a body with nothing to report ----------

  def test_a_body_that_cannot_fail_has_a_quiet_window
    f = CArray.jit_function("double plain(double x)") { |x| x * 2.0 }
    assert_nil(f.report_error)
    assert_equal(7, f.watching { 7 })
  end

  # ---------- one flag per compiled object ----------

  def test_two_compiled_functions_do_not_share_the_flag
    # Two bodies written differently: `jit_function` hands the same object
    # back for the same block text, so the same source twice would be one
    # function and would share a flag for a reason that is not this one.
    f = CArray.jit_function("double one(double x)") { |x|
      raise "f refuses" if x < 0.0
      x * 2.0
    }
    g = CArray.jit_function("double two(double y)") { |y|
      raise "g refuses" if y < -1.0
      y + y + 0.0
    }
    refute_equal(f.name, g.name)

    f.clear_error
    g.clear_error
    foreign(f).call(-1.0)
    assert_raises(RuntimeError) { f.report_error }
    assert_nil(g.report_error)
    assert_equal(6.0, foreign(g).call(3.0))
  end

end
