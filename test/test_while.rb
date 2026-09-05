require_relative "test_helper"

# `while`, which is the loop whose end is not written down.
#
# Everything here is checked against the same loop run in Ruby wherever the
# answer is a number, because that is the claim the rest of the compiler makes
# and a new kind of loop does not get an exemption from it.
class TestWhile < Minitest::Test

  include KernelCompilation

  def test_it_runs_until_the_condition_goes_false
    values = CArray.double(8).seq!(1.0)
    out = CArray.int64(8)
    CArray.jit_for(8) { |i|
      v = values[i]
      c = 0
      while v > 1.0
        v = v / 2.0
        c = c + 1
      end
      out[i] = c
    }
    expected = (1..8).map { |k|
      v = k.to_f
      c = 0
      while v > 1.0
        v = v / 2.0
        c = c + 1
      end
      c
    }
    assert_equal(expected, out.to_a)
  end

  # Newton's method: the loop nobody can put a bound on without solving the
  # problem first, which is the case `while` is for.
  def test_a_convergence_loop_agrees_with_ruby
    values = CArray.double(6).seq!(1.0)
    roots = CArray.double(6)
    CArray.jit_for(6) { |i|
      guess = values[i]
      while (guess * guess - values[i]).abs > 1e-12
        guess = 0.5 * (guess + values[i] / guess)
      end
      roots[i] = guess
    }
    expected = (1..6).map { |k|
      value = k.to_f
      guess = value
      while (guess * guess - value).abs > 1e-12
        guess = 0.5 * (guess + value / guess)
      end
      guess
    }
    assert_equal(expected, roots.to_a, "bit for bit, not merely close")
  end

  def test_a_body_that_never_runs
    out = CArray.int64(3)
    CArray.jit_for(3) { |i|
      c = 0
      while c > 10
        c = c + 1
      end
      out[i] = c
    }
    assert_equal([0, 0, 0], out.to_a)
  end

  def test_the_modifier_form
    out = CArray.int64(3)
    CArray.jit_for(3) { |i|
      c = 0
      c = c + 1 while c < 5
      out[i] = c
    }
    assert_equal([5, 5, 5], out.to_a)
  end

  # `break` needed an inner loop before this, because an inner loop was the
  # only loop there was.  A `while` is one too.
  def test_break_leaves_the_while
    out = CArray.int64(3)
    CArray.jit_for(3) { |i|
      c = 0
      while c < 100
        c = c + 1
        break if c > 3
      end
      out[i] = c
    }
    assert_equal([4, 4, 4], out.to_a)
  end

  def test_next_skips_the_rest_of_the_pass
    out = CArray.int64(3)
    CArray.jit_for(3) { |i|
      c = 0
      seen = 0
      while c < 6
        c = c + 1
        next if c == 2
        seen = seen + 1
      end
      out[i] = seen
    }
    assert_equal([5, 5, 5], out.to_a)
  end

  def test_while_true_with_a_break_is_allowed
    out = CArray.int64(2)
    CArray.jit_for(2) { |i|
      c = 0
      while true
        c = c + 1
        break if c > 2
      end
      out[i] = c
    }
    assert_equal([3, 3], out.to_a)
  end

  # The one non-termination that can be read off the page rather than guessed
  # at.  Nothing here tries to answer the general question.
  def test_while_true_with_no_way_out_is_refused
    refuse("->(i) { while true; end; a[i] = 1.0 }",
           /holds no `break` and no `raise`, so it cannot end/)
  end

  def test_while_true_whose_only_way_out_is_a_raise_is_allowed
    compile_kernel("->(i) { while true; raise 'stop'; end; a[i] = 1.0 }")
  end

  # A `break` nested one loop deeper leaves that loop, not this one, so it is
  # no way out of the `while true` around it.
  def test_a_break_in_a_nested_loop_is_not_a_way_out
    refuse("->(i) { while true; 3.times { |j| break }; end; a[i] = 1.0 }",
           /holds no `break` and no `raise`, so it cannot end/)
  end

  def test_a_raise_inside_a_while_stops_the_kernel
    out = CArray.double(4)
    error = assert_raises(RuntimeError) do
      CArray.jit_for(4) { |i|
        c = 0
        while c < 100
          c = c + 1
          raise "ran away" if c > 3
        end
        out[i] = c
      }
    end
    assert_equal("ran away", error.message)
  end

  # Ruby's is the one loop in the language that tests after the body, and a
  # reader who missed the `begin` would read the first pass as conditional.
  def test_begin_end_while_is_refused
    refuse("->(i) { c = 0; begin; c = c + 1; end while c < 3; a[i] = c }",
           /runs its body before the condition is ever read/)
  end

  def test_the_condition_must_be_a_comparison
    refuse("->(i) { c = 0; while 1; c = c + 1; end; a[i] = c }",
           /a condition must be a comparison/)
  end

  # The condition is walked before the body, so a name the body would
  # introduce is not in scope where the condition reads it -- which is what
  # keeps the first pass from reading whatever C left in the variable.
  def test_a_local_the_body_introduces_is_not_in_scope_in_the_condition
    refuse("->(i) { while v < 3.0; v = 1.0; end; a[i] = 1.0 }",
           /`v` is read before it is assigned/)
  end

  def test_a_value_that_changes_type_round_the_loop_is_refused
    refuse("->(i) { v = 0; while v < 3; v = v + 1.5; end; a[i] = v }",
           /enters this loop as an Integer and comes back round as a Float/)
  end

  # The whole-array spelling has statements in it too.
  def test_it_works_in_the_whole_array_spelling
    limit = CArray.double(5).seq!(1.0)
    out = CArray.double(5)
    CArray.jit_each {
      c = 0.0
      while c < limit
        c = c + 1.0
      end
      out = c
    }
    assert_equal([1.0, 2.0, 3.0, 4.0, 5.0], out.to_a)
  end

  # A loop entered on a value read from a missing cell was decided by bytes
  # that mean nothing, which is the position a branch taken on one is in --
  # so what it writes is masked, by the same rule and the same machinery.
  def test_a_masked_condition_masks_what_the_body_writes
    values = CArray.double(4).seq!(1.0)
    values[2] = UNDEF
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      c = 0.0
      while c < values[i]
        c = c + 1.0
        out[i] = c
      end
    }
    assert_equal([false, false, true, false], out.is_masked.to_a)
    assert_equal([1.0, 2.0, 4.0], out.to_a.values_at(0, 1, 3))
  end

  def test_a_while_inside_an_inner_loop
    out = CArray.int64(2)
    CArray.jit_for(2) { |i|
      total = 0
      3.times { |j|
        c = 0
        while c < j
          c = c + 1
        end
        total = total + c
      }
      out[i] = total
    }
    assert_equal([3, 3], out.to_a)
  end

end
