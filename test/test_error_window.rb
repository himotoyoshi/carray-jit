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

  # ---------- a hook for the one who holds the address ----------

  # What a library would be told to stop with, counted.  A compiled
  # function is as good a `void (*)(void *)` as any: the ABI is the same.
  def counting_hook
    CArray.jit_function("void (*)(int32_t *count)") { |c| c[0] = c[0] + 1 }
  end

  def counter
    Fiddle::Pointer.malloc(4).tap { |data| data[0, 4] = [0].pack("l") }
  end

  def count_of (data)
    data[0, 4].unpack1("l")
  end

  def test_the_hook_is_called_once_by_the_failing_call
    f = raising_below_zero
    data = counter
    f.on_error(counting_hook.pointer, data)
    raw = foreign(f)
    error = assert_raises(RuntimeError) do
      f.watching { [1.0, -1.0, -2.0, 3.0].each { |x| raw.call(x) } }
    end
    assert_equal("x is negative", error.message)
    assert_equal(1, count_of(data))
  ensure
    f&.on_error(nil)
  end

  def test_the_hook_is_called_again_once_the_flag_was_put_down
    f = raising_below_zero
    data = counter
    f.on_error(counting_hook.pointer, data)
    raw = foreign(f)
    2.times do
      assert_raises(RuntimeError) { f.watching { raw.call(-1.0) } }
    end
    assert_equal(2, count_of(data))
  ensure
    f&.on_error(nil)
  end

  def test_a_call_from_ruby_answers_by_raising_and_not_through_the_hook
    f = raising_below_zero
    data = counter
    f.on_error(counting_hook.pointer, data)
    assert_raises(RuntimeError) { f.call(-1.0) }
    assert_equal(0, count_of(data))
    assert_raises(RuntimeError) { f.watching { foreign(f).call(-1.0) } }
    assert_equal(1, count_of(data))
  ensure
    f&.on_error(nil)
  end

  def test_no_hook_is_called_once_it_is_taken_away
    f = raising_below_zero
    data = counter
    f.on_error(counting_hook.pointer, data)
    f.on_error(nil)
    assert_raises(RuntimeError) { f.watching { foreign(f).call(-1.0) } }
    assert_equal(0, count_of(data))
  end

  def test_a_body_that_cannot_fail_accepts_a_hook_and_never_calls_it
    f = CArray.jit_function("double (*)(double x)") { |x| x * 3.0 }
    data = counter
    assert_same(f, f.on_error(counting_hook.pointer, data))
    assert_equal(6.0, foreign(f).call(2.0))
    assert_equal(0, count_of(data))
  end

  # The hook is outside the body, so a recursive body reaches itself
  # directly and the one call Ruby or a library made is the one that asks.
  def test_a_recursive_body_calls_itself_and_not_the_entry_point
    f = CArray.jit_function("double down(double n)") { |n|
      raise "reached the bottom" if n < 0.0
      n + down.call(n - 1.0)
    }
    data = counter
    f.on_error(counting_hook.pointer, data)
    assert_raises(RuntimeError) { f.watching { foreign(f).call(3.0) } }
    assert_equal(1, count_of(data))
    assert_match(/_body\(n - 1\.0\)/, f.c_source)
  ensure
    f&.on_error(nil)
  end


  # ---------- a window is the thread's ----------

  # The flag and the hook are `_Thread_local`, because the compiled object is
  # shared whether or not anybody meant to share it: two blocks with the same
  # text are one function, so a program that never mentions threads can still
  # have two windows open on one body.

  def test_the_flag_is_declared_per_thread
    f = raising_below_zero
    assert_match(/_Thread_local int32_t carray_jit_error = 0;/, f.c_source)
    assert_match(/_Thread_local void \(\*carray_jit_on_error\)/, f.c_source)
  end

  def test_a_window_does_not_see_another_thread_s_failure
    f = raising_below_zero
    raw = foreign(f)
    opened = Queue.new
    closing = Queue.new
    other = Thread.new do
      f.watching do
        opened << :open
        closing.pop
        # Nothing this thread called ever went below zero.
        assert_equal(4.0, raw.call(2.0))
      end
      :no_failure
    rescue RuntimeError => error
      error.message
    end
    opened.pop
    # A second window on the same body, in this thread, failing.
    error = assert_raises(RuntimeError) { f.watching { raw.call(-1.0) } }
    assert_equal("x is negative", error.message)
    closing << :close
    assert_equal(:no_failure, other.value)
  end

  def test_a_flag_raised_in_one_thread_is_not_read_in_another
    f = always_raising
    f.clear_error
    Thread.new do
      f.clear_error
      foreign(f).call(1.0)
      assert_raises(RuntimeError) { f.report_error }
    end.join
    assert_nil(f.report_error)
  end

  def test_a_hook_belongs_to_the_thread_that_set_it
    f = raising_below_zero
    data = counter
    f.on_error(counting_hook.pointer, data)
    Thread.new do
      assert_raises(RuntimeError) { f.watching { foreign(f).call(-1.0) } }
    end.join
    assert_equal(0, count_of(data))
    assert_raises(RuntimeError) { f.watching { foreign(f).call(-1.0) } }
    assert_equal(1, count_of(data))
  ensure
    f&.on_error(nil)
  end

  # ---------- one window over several functions ----------

  def refusing_above_nine
    CArray.jit_function("double above_nine(double y)") { |y|
      raise "y is too large" if y > 9.0
      y + y + 1.0
    }
  end

  def test_several_functions_are_watched_at_once
    f = raising_below_zero
    g = refusing_above_nine
    error = assert_raises(RuntimeError) do
      CArray::JIT.watching(f, g) { foreign(g).call(99.0) }
    end
    assert_equal("y is too large", error.message)
  end

  def test_the_first_failure_in_the_list_is_the_one_raised
    f = raising_below_zero
    g = refusing_above_nine
    both = lambda {
      foreign(f).call(-1.0)
      foreign(g).call(99.0)
    }
    error = assert_raises(RuntimeError) { CArray::JIT.watching(f, g, &both) }
    assert_equal("x is negative", error.message)
    error = assert_raises(RuntimeError) { CArray::JIT.watching(g, f, &both) }
    assert_equal("y is too large", error.message)
  end

  def test_every_flag_is_read_even_where_an_earlier_one_failed
    f = raising_below_zero
    g = refusing_above_nine
    # An earlier window in this thread may have left a flag up; the window
    # below puts back what it found, so what it found is said here.
    f.clear_error
    g.clear_error
    assert_raises(RuntimeError) do
      CArray::JIT.watching(f, g) do
        foreign(f).call(-1.0)
        foreign(g).call(99.0)
      end
    end
    # g's failure was read rather than left standing, so it does not surface
    # on the next window somebody opens on it.
    assert_nil(g.report_error)
    assert_nil(f.report_error)
  end

  def test_a_body_failure_outranks_the_block_s_own_exception
    f = raising_below_zero
    g = refusing_above_nine
    error = assert_raises(RuntimeError) do
      CArray::JIT.watching(f, g) do
        foreign(g).call(99.0)
        raise ArgumentError, "did not converge"
      end
    end
    assert_equal("y is too large", error.message)
    # The library's complaint is the consequence, and is kept as such.
    assert_kind_of(ArgumentError, error.cause)
    assert_equal("did not converge", error.cause.message)
  end

  def test_the_block_s_exception_stands_where_nothing_failed
    f = raising_below_zero
    g = refusing_above_nine
    error = assert_raises(ArgumentError) do
      CArray::JIT.watching(f, g) { raise ArgumentError, "did not converge" }
    end
    assert_equal("did not converge", error.message)
  end

  def test_the_window_answers_with_the_value_of_its_block
    f = raising_below_zero
    assert_equal(42, CArray::JIT.watching(f, refusing_above_nine) { 42 })
    assert_equal(7, CArray::JIT.watching { 7 })
  end

  def test_nil_is_skipped_and_a_function_named_twice_is_watched_once
    f = raising_below_zero
    f.clear_error
    assert_equal(7, CArray::JIT.watching(f, nil, f) { 7 })
    error = assert_raises(RuntimeError) do
      CArray::JIT.watching(f, nil, f) { foreign(f).call(-1.0) }
    end
    assert_equal("x is negative", error.message)
    assert_nil(f.report_error)
  end

  def test_a_body_that_cannot_fail_passes_through
    plain = CArray.jit_function("double steady(double x)") { |x| x * 2.0 }
    assert_equal(7, CArray::JIT.watching(plain) { 7 })
  end

  def test_a_window_over_several_nests_inside_one_of_its_own_functions
    f = raising_below_zero
    g = refusing_above_nine
    error = assert_raises(RuntimeError) do
      f.watching do
        foreign(f).call(-1.0)
        # The inner window borrows both flags and puts them back.
        assert_equal(4.0, CArray::JIT.watching(f, g) { foreign(f).call(2.0) })
      end
    end
    assert_equal("x is negative", error.message)
  end

  def test_what_is_watched_has_to_be_a_compiled_function
    error = assert_raises(TypeError) do
      CArray::JIT.watching(raising_below_zero, 3) { 1 }
    end
    assert_match(/Integer is not one/, error.message)
  end

  # ---------- the hook a window brings with it ----------

  def test_the_window_s_hook_is_called_and_the_owner_s_put_back
    f = raising_below_zero
    owners = counter
    windows = counter
    f.on_error(counting_hook.pointer, owners)
    assert_raises(RuntimeError) do
      CArray::JIT.watching(f, on_error: [counting_hook.pointer, windows]) do
        foreign(f).call(-1.0)
      end
    end
    assert_equal(1, count_of(windows))
    assert_equal(0, count_of(owners))
    # The owner's hook is where it was, rather than gone.
    assert_raises(RuntimeError) { f.watching { foreign(f).call(-1.0) } }
    assert_equal(1, count_of(owners))
  ensure
    f&.on_error(nil)
  end

  def test_the_window_s_hook_is_taken_off_where_there_was_none_before
    f = raising_below_zero
    windows = counter
    assert_raises(RuntimeError) do
      CArray::JIT.watching(f, on_error: [counting_hook.pointer, windows]) do
        foreign(f).call(-1.0)
      end
    end
    assert_equal(1, count_of(windows))
    assert_raises(RuntimeError) { f.watching { foreign(f).call(-1.0) } }
    assert_equal(1, count_of(windows))
  end

  def test_the_same_hook_is_set_on_every_function_watched
    f = raising_below_zero
    g = refusing_above_nine
    data = counter
    assert_raises(RuntimeError) do
      CArray::JIT.watching(f, g, on_error: [counting_hook.pointer, data]) do
        foreign(g).call(99.0)
      end
    end
    assert_equal(1, count_of(data))
  end

  def test_the_hook_is_given_as_the_pair_on_error_takes
    f = raising_below_zero
    error = assert_raises(ArgumentError) do
      CArray::JIT.watching(f, on_error: counting_hook.pointer) { 1 }
    end
    assert_match(/takes the hook and the one pointer/, error.message)
  end

  # ---------- what a failed call answers C with ----------

  # The flag is the contract, and for a body returning `double` the value is
  # a courtesy nobody reads.  For one returning `int` it is a status: GSL's
  # callbacks return `int`, and 0 there is GSL_SUCCESS -- so a failed body
  # answering 0 tells GSL the step went well.  Which number is right belongs
  # to the window, because the body does not know what it was handed to.

  def reporting_int
    CArray.jit_function("int step(double x)") { |x|
      raise "past the edge" if x > 0.5
      1
    }
  end

  def calling_int (function)
    Fiddle::Function.new(function.pointer, [Fiddle::TYPE_DOUBLE],
                         Fiddle::TYPE_INT)
  end

  def test_a_failed_call_answers_zero_unless_a_window_says_otherwise
    f = reporting_int
    raw = calling_int(f)
    seen = nil
    assert_raises(RuntimeError) do
      CArray::JIT.watching(f) { seen = [raw.call(0.1), raw.call(0.9), raw.call(0.2)] }
    end
    assert_equal([1, 0, 0], seen)
  end

  def test_a_window_says_what_a_failed_call_answers_with
    f = reporting_int
    raw = calling_int(f)
    seen = nil
    assert_raises(RuntimeError) do
      CArray::JIT.watching(f, stand_in: 9) do
        # The failing call and every one turned away after it: a library
        # that stops on a non-zero status has to be told on each of them.
        seen = [raw.call(0.1), raw.call(0.9), raw.call(0.2)]
      end
    end
    assert_equal([1, 9, 9], seen)
  end

  def test_the_stand_in_is_put_back_when_the_window_closes
    f = reporting_int
    raw = calling_int(f)
    assert_raises(RuntimeError) do
      CArray::JIT.watching(f, stand_in: 9) { raw.call(0.9) }
    end
    seen = nil
    assert_raises(RuntimeError) do
      CArray::JIT.watching(f) { seen = raw.call(0.9) }
    end
    assert_equal(0, seen)
  end

  def test_an_inner_window_puts_back_the_outer_window_s_stand_in
    f = reporting_int
    raw = calling_int(f)
    outer = nil
    assert_raises(RuntimeError) do
      CArray::JIT.watching(f, stand_in: 9) do
        assert_raises(RuntimeError) do
          CArray::JIT.watching(f, stand_in: 4) { assert_equal(4, raw.call(0.9)) }
        end
        outer = raw.call(0.9)
      end
    end
    assert_equal(9, outer)
  end

  def test_a_single_function_s_window_takes_one_too
    f = reporting_int
    raw = calling_int(f)
    seen = nil
    assert_raises(RuntimeError) do
      f.watching(stand_in: 7) { seen = [raw.call(0.9), raw.call(0.1)] }
    end
    assert_equal([7, 7], seen)
  end

  # Every way a body can fail answers the same, which is the whole point of a
  # status: a `raise` leaves early, while a division that had no divisor runs
  # on to the end and used to hand back whatever the helper's zero added up
  # to -- two different answers for one failure.
  def test_a_division_answers_as_a_raise_does
    f = CArray.jit_function("int share(int64_t a, int64_t b)") { |a, b|
      100 + a / b
    }
    raw = Fiddle::Function.new(f.pointer,
                               [Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_LONG_LONG],
                               Fiddle::TYPE_INT)
    seen = nil
    assert_raises(ZeroDivisionError) do
      CArray::JIT.watching(f, stand_in: -1) do
        seen = [raw.call(10, 2), raw.call(10, 0), raw.call(10, 5)]
      end
    end
    assert_equal([105, -1, -1], seen)
  end

  def test_the_stand_in_is_cast_to_what_the_body_returns
    f = CArray.jit_function("double half(double x)") { |x|
      raise "x is negative" if x < 0.0
      x / 2.0
    }
    raw = foreign(f)
    seen = nil
    assert_raises(RuntimeError) do
      CArray::JIT.watching(f, stand_in: -1) do
        seen = [raw.call(4.0), raw.call(-1.0), raw.call(6.0)]
      end
    end
    assert_equal([2.0, -1.0, -1.0], seen)
    assert_match(/return \(double\) carray_jit_standin;/, f.c_source)
  end

  def test_a_body_that_cannot_fail_takes_one_and_answers_as_it_always_did
    f = CArray.jit_function("int steady(double x)") { |x| 3 }
    assert_equal(3, CArray::JIT.watching(f, stand_in: 9) { calling_int(f).call(1.0) })
  end

  def test_the_stand_in_is_a_number_that_fits_one_word
    f = reporting_int
    error = assert_raises(TypeError) do
      CArray::JIT.watching(f, stand_in: 1.5) { 1 }
    end
    assert_match(/Float is not one/, error.message)
    assert_raises(RangeError) do
      CArray::JIT.watching(f, stand_in: 2**70) { 1 }
    end
  end

  def test_the_stand_in_stands_beside_the_flag_and_the_hook
    f = raising_below_zero
    assert_match(/_Thread_local int64_t carray_jit_standin = 0;/, f.c_source)
    assert_match(/out\[3\] = \(void \*\) &carray_jit_standin;/, f.c_source)
  end

end
