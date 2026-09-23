require_relative "test_helper"
require "tmpdir"

# A `size_t` parameter computes as a uint64, and the loop it bounds counts in
# int64.  Those are the same width and differ only in sign, so the rank the
# widening cast consults puts uint64 *above* int64 and the step down went
# uncast -- on the reasoning that C would do it anyway.
#
# C does not.  In `i < n` with `i` an `int64_t` and `n` a `size_t`, the
# conversion C performs is on the other operand: `i` becomes unsigned.  A
# loop counting down past zero then runs against a bound of 2**64 - 1, and
# the compiler says so as `-Wsign-compare` -- which every generated loop over
# a `size_t` extent carried.
class TestUnsignedBounds < Minitest::Test

  def scale
    CArray.jit_function(
      "void scale(double *out, const double *in, size_t n, double k)") { |out, inp, n, k|
      n.times { |i| out[i] = inp[i] * k }
    }
  end

  def test_the_bound_is_cast_where_the_counter_meets_it
    assert_match(/for \(int64_t i = INT64_C\(0\); i < \(int64_t\)n;/, scale.c_source)
  end

  # The warning is the visible half; this is what it was warning about.
  def test_the_generated_c_compiles_clean
    skip "no compiler on PATH" unless system("command -v cc > /dev/null 2>&1")
    Dir.mktmpdir do |directory|
      source = File.join(directory, "scale.c")
      File.write(source, scale.c_source)
      output = `cc -c -Wall -Wextra -o #{File.join(directory, "scale.o")} #{source} 2>&1`
      assert $?.success?, "the generated C did not compile:\n#{output}"
      assert_empty output.strip, "the generated C warned:\n#{output}"
    end
  end

  def test_it_still_answers_what_ruby_answers
    values = CArray.double(8).seq!(1.0)
    out = CArray.double(8)
    scale.call(out, values, 8, 3.0)
    assert_equal (1..8).map { |x| x * 3.0 }, out.to_a
  end

  # Where the missing cast was not only noise.  A counter that starts below
  # zero, compared against an unsigned bound, is converted to unsigned by C
  # itself: -3 becomes 2**64 - 3, which is not less than 4, and the loop runs
  # no passes at all.  Ruby's `(-3...4).each` runs seven.
  #
  # This answered 0 before the cast was written, and said nothing about it.
  def test_a_counter_starting_below_zero_runs_the_passes_ruby_runs
    below = CArray.jit_function("int64_t below(size_t n)") { |n|
      total = 0
      (-3...n).each { |i| total = total + 1 }
      total
    }
    assert_equal (-3...4).count, below.call(4)
    assert_equal 7, below.call(4)
  end

  # int64 reaching a uint64 context was already cast; this is the other
  # direction, and now both are written down.
  def test_the_cast_is_written_in_both_directions
    widened = CArray.jit_function("uint64_t widen(int64_t v)") { |v| v }
    assert_match(/\(uint64_t\)/, widened.c_source)
    narrowed = CArray.jit_function("int64_t narrow(uint64_t v)") { |v| v }
    assert_match(/\(int64_t\)/, narrowed.c_source)
  end

end
