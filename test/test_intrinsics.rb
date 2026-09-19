require_relative "test_helper"

# `sum(w)`, `min(w)`, `max(w)` and `sort(w)` over a local array.
#
# The names are the compiler's own -- bare calls, the way `random(rng: r)` is
# -- rather than methods on the array, so nothing here promises CArray's
# method semantics.  What each one means is therefore settled by test: the
# reference is the same loop written out in Ruby, and for `sort` it is
# `CArray#sort`, whose answer for a NaN and for a signed zero is the answer
# this follows.
#
# float32 cannot be checked against a Ruby loop -- Ruby would widen every
# operation to a double -- so its reference is the same algorithm over a
# captured array of workspace, which is a kernel this suite already holds to
# CArray's own operators.
class TestIntrinsics < Minitest::Test

  # ---------- sum ----------

  { "int32" => :int32, "int64" => :int64, "float64" => :float64,
    "cmplx128" => :cmplx128 }.each do |name, type|
    define_method("test_sum_over_a_local_#{name}_array_matches_the_same_loop") do
      source = CArray.new(type, [4, 7])
      source.seq!(1, 3)
      out = CArray.new(type, [4])
      kernel = compile_kernel(<<~RUBY, arrays: { :source => name, :out => name })
        proc { |i|
          w = CArray.new(:#{name}, [7])
          (0...7).each { |k| w[k] = source[i, k] }
          out[i] = sum(w)
        }
      RUBY
      kernel.call({ :source => source, :out => out }, {}, [[0, 4, 1]], {})
      reference = CArray.new(type, [4])
      (0...4).each { |i|
        total = source[i, 0] - source[i, 0]
        (0...7).each { |k| total = total + source[i, k] }
        reference[i] = total
      }
      assert_equal(reference.to_a, out.to_a)
    end
  end

  def test_sum_over_a_local_float32_array_matches_a_row_of_captured_workspace
    a = CArray.float32(6, 5)
    a.seq!(1.0, 0.25)
    mine = CArray.float32(6)
    CArray.jit_for(6) { |i|
      w = CArray.float32(5)
      (0...5).each { |k| w[k] = a[i, k] * a[i, k] }
      mine[i] = sum(w)
    }
    work = CArray.float32(6, 5)
    theirs = CArray.float32(6)
    CArray.jit_for(6) { |i|
      (0...5).each { |k| work[i, k] = a[i, k] * a[i, k] }
      total = 0.0
      (0...5).each { |k| total = total + work[i, k] }
      theirs[i] = total
    }
    assert_arrays_bits_equal(theirs, mine)
  end

  def test_sum_is_taken_in_index_order
    # A sum that is not sequential gives a different last bit here: the terms
    # were chosen so that adding the small ones first keeps them.
    a = CArray.double(1, 4)
    a[0, 0] = 1.0e16
    a[0, 1] = 1.0
    a[0, 2] = 1.0
    a[0, 3] = -1.0e16
    out = CArray.double(1)
    CArray.jit_for(1) { |i|
      w = CArray.double(4)
      (0...4).each { |k| w[k] = a[i, k] }
      out[i] = sum(w)
    }
    sequential = 0.0
    (0...4).each { |k| sequential = sequential + a[0, k] }
    assert_bits_equal(sequential, out[0])
  end

  def test_sum_of_an_integer_array_wraps_where_the_width_wraps
    out = CArray.int64(1)
    CArray.jit_for(1) { |i|
      w = CArray.int64(2)
      w[0] = 9223372036854775807
      w[1] = 1
      out[i] = sum(w)
    }
    assert_equal(-9223372036854775808, out[0])
  end

  def test_sum_of_one_cell_is_that_cell
    out = CArray.double(1)
    CArray.jit_for(1) { |i|
      w = CArray.double(1)
      w[0] = 7.5
      out[i] = sum(w)
    }
    assert_equal(7.5, out[0])
  end

  # ---------- min and max ----------

  # The answers here are CArray's, measured: a NaN is skipped wherever it
  # stands, and an array of nothing but NaN answers with the limit the
  # accumulator started from.
  NAN = Float::NAN

  { "a NaN in the middle" => [3.0, NAN, 2.0],
    "a NaN first"         => [NAN, 1.0, 2.0],
    "a NaN last"          => [3.0, 1.0, NAN],
    "no NaN"              => [3.0, 1.0, 2.0] }.each do |label, values|
    slug = label.tr(" ", "_")
    define_method("test_min_and_max_with_#{slug}_answer_what_carray_answers") do
      # Three cells in every case, written out: a length interpolated from a
      # Ruby variable would be a name the block closed over.
      assert_equal(3, values.size)
      source = CArray.double(1, 3) { [values] }
      low = CArray.double(1)
      high = CArray.double(1)
      CArray.jit_for(1) { |i|
        w = CArray.double(3)
        (0...3).each { |k| w[k] = source[i, k] }
        low[i] = min(w)
        high[i] = max(w)
      }
      reference = CArray.double(3) { values }
      assert_bits_equal(reference.min, low[0], "min")
      assert_bits_equal(reference.max, high[0], "max")
    end
  end

  def test_min_and_max_of_all_nan_answer_nan_as_carray_does
    low = CArray.double(1)
    high = CArray.double(1)
    CArray.jit_for(1) { |i|
      w = CArray.double(3)
      (0...3).each { |k| w[k] = 0.0 / 0.0 }
      low[i] = min(w)
      high[i] = max(w)
    }
    # With no number left to win, there is no minimum to name.  CArray
    # answers NaN here, and used to answer the accumulator it started from.
    reference = CArray.double(3) { [NAN, NAN, NAN] }
    assert(reference.min.nan?, "carray's own answer")
    assert(reference.max.nan?, "carray's own answer")
    assert(low[0].nan?)
    assert(high[0].nan?)
  end

  # 0.0 and -0.0 compare equal, and CArray keeps whichever came first.  So
  # does the fold: a cell takes the accumulator only by beating it.
  def test_of_two_zeros_min_and_max_keep_the_first_as_carray_does
    [[0.0, -0.0], [-0.0, 0.0]].each do |first, second|
      pair = CArray.double(2)
      pair[0] = first
      pair[1] = second
      low = CArray.double(1)
      high = CArray.double(1)
      CArray.jit_for(1) { |i|
        w = CArray.double(2)
        w[0] = pair[0]
        w[1] = pair[1]
        low[i] = min(w)
        high[i] = max(w)
      }
      assert_equal(pair.min.to_s, low[0].to_s, "min of #{[first, second]}")
      assert_equal(pair.max.to_s, high[0].to_s, "max of #{[first, second]}")
      assert_equal(first.to_s, low[0].to_s)
    end
  end

  # A number beats a NaN however many NaNs it is among, which is what keeps
  # the answer above from swallowing an array that holds one.
  def test_a_single_number_among_nan_is_the_answer
    low = CArray.double(1)
    high = CArray.double(1)
    CArray.jit_for(1) { |i|
      w = CArray.double(3)
      w[0] = 0.0 / 0.0
      w[1] = 2.0
      w[2] = 0.0 / 0.0
      low[i] = min(w)
      high[i] = max(w)
    }
    assert_equal(2.0, low[0])
    assert_equal(2.0, high[0])
  end

  def test_min_and_max_over_a_signed_zero
    low = CArray.double(1)
    high = CArray.double(1)
    CArray.jit_for(1) { |i|
      w = CArray.double(2)
      w[0] = 0.0
      w[1] = -0.0
      low[i] = min(w)
      high[i] = max(w)
    }
    # fmin and fmax may answer either operand when the two compare equal, and
    # 0.0 and -0.0 do.  The value is zero either way, which is what is asked
    # here; the sign is not part of the answer.
    assert_equal(0.0, low[0])
    assert_equal(0.0, high[0])
  end

  { "int32" => :int32, "int64" => :int64, "uint8" => :uint8 }.each do |name, type|
    define_method("test_min_and_max_over_a_local_#{name}_array") do
      source = CArray.new(type, [1, 5])
      source[0, 0] = 7
      source[0, 1] = 2
      source[0, 2] = 9
      source[0, 3] = 4
      source[0, 4] = 5
      low = CArray.new(type, [1])
      high = CArray.new(type, [1])
      types = { :source => name, :low => name, :high => name }
      kernel = compile_kernel(<<~RUBY, arrays: types)
        proc { |i|
          w = CArray.new(:#{name}, [5])
          (0...5).each { |k| w[k] = source[i, k] }
          low[i] = min(w)
          high[i] = max(w)
        }
      RUBY
      kernel.call({ :source => source, :low => low, :high => high }, {},
                  [[0, 1, 1]], {})
      assert_equal(2, low[0])
      assert_equal(9, high[0])
    end
  end

  def test_min_and_max_of_one_cell
    low = CArray.double(1)
    high = CArray.double(1)
    CArray.jit_for(1) { |i|
      w = CArray.double(1)
      w[0] = -4.5
      low[i] = min(w)
      high[i] = max(w)
    }
    assert_equal(-4.5, low[0])
    assert_equal(-4.5, high[0])
  end

  def test_a_spread_is_max_minus_min
    a = CArray.double(3, 5)
    a.seq!(2.0, 3.0)
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      w = CArray.double(5)
      (0...5).each { |k| w[k] = a[i, k] }
      out[i] = max(w) - min(w)
    }
    reference = (0...3).map { |i|
      row = (0...5).map { |k| a[i, k] }
      row.max - row.min
    }
    assert_arrays_bits_equal(CArray.double(3) { reference }, out)
  end

  # ---------- sort ----------

  LENGTHS = [1, 2, 9, 16, 17, 64, 512]

  LENGTHS.each do |n|
    define_method("test_sort_of_#{n}_cells_matches_carrays_own_sort") do
      values = (0...n).map { |k| ((k * 37 + 11) % 101) * 1.0 }
      source = CArray.double(1, n) { [values] }
      out = CArray.double(1, n)
      types = { :source => "float64", :out => "float64" }
      kernel = compile_kernel(<<~RUBY, arrays: types)
        proc { |i|
          w = CArray.double(#{n})
          (0...#{n}).each { |k| w[k] = source[i, k] }
          sort(w)
          (0...#{n}).each { |k| out[i, k] = w[k] }
        }
      RUBY
      kernel.call({ :source => source, :out => out }, {}, [[0, 1, 1]], {})
      reference = CArray.double(n) { values }.sort
      assert_equal(reference.to_a, (0...n).map { |k| out[0, k] })
    end
  end

  { "already sorted"   => [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0],
    "reversed"         => [9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0],
    "all one value"    => [4.0] * 9,
    "a NaN first"      => [NAN, 3.0, 1.0, 2.0, 5.0, 4.0, 8.0, 6.0, 7.0],
    "a NaN in the middle" => [3.0, 1.0, 2.0, 5.0, NAN, 4.0, 8.0, 6.0, 7.0],
    "a NaN last"       => [3.0, 1.0, 2.0, 5.0, 4.0, 8.0, 6.0, 7.0, NAN],
    "two NaN"          => [NAN, 1.0, 2.0, 5.0, NAN, 4.0, 8.0, 6.0, 7.0],
    "all NaN"          => [NAN] * 9 }.each do |label, values|
    slug = label.tr(" ", "_")
    define_method("test_sort_with_#{slug}_matches_carrays_own_sort") do
      source = CArray.double(1, 9) { [values] }
      out = CArray.double(1, 9)
      CArray.jit_for(1) { |i|
        w = CArray.double(9)
        (0...9).each { |k| w[k] = source[i, k] }
        sort(w)
        (0...9).each { |k| out[i, k] = w[k] }
      }
      expected = CArray.double(9) { values }.sort
      9.times do |k|
        if expected[k].nan?
          assert_predicate(out[0, k], :nan?, "cell #{k} should be a NaN")
        else
          assert_equal(expected[k], out[0, k], "cell #{k}")
        end
      end
    end
  end

  def test_sort_puts_every_nan_after_every_number
    values = [NAN, 3.0, NAN, 1.0, 2.0, NAN]
    source = CArray.double(1, 6) { [values] }
    out = CArray.double(1, 6)
    CArray.jit_for(1) { |i|
      w = CArray.double(6)
      (0...6).each { |k| w[k] = source[i, k] }
      sort(w)
      (0...6).each { |k| out[i, k] = w[k] }
    }
    answer = (0...6).map { |k| out[0, k] }
    assert_equal([1.0, 2.0, 3.0], answer.reject(&:nan?))
    assert_equal(3, answer.count(&:nan?))
    assert(answer.each_cons(2).none? { |a, b| a.nan? && !b.nan? },
           "a number stands after a NaN in #{answer.inspect}")
  end

  # §3.3: the order of -0.0 against 0.0 is not promised, so the comparison is
  # by value.  That is the one place in this suite where a float is not
  # compared bitwise, and it is the same licence CArray's own sort takes.
  def test_sort_orders_a_signed_zero_by_value
    values = [1.0, 0.0, -0.0, -1.0]
    source = CArray.double(1, 4) { [values] }
    out = CArray.double(1, 4)
    CArray.jit_for(1) { |i|
      w = CArray.double(4)
      (0...4).each { |k| w[k] = source[i, k] }
      sort(w)
      (0...4).each { |k| out[i, k] = w[k] }
    }
    assert_equal([-1.0, 0.0, 0.0, 1.0], (0...4).map { |k| out[0, k] })
  end

  def test_sort_over_an_integer_array
    values = [7, 2, 9, 2, 5, 1, 8]
    source = CArray.int32(1, 7) { [values] }
    out = CArray.int32(1, 7)
    types = { :source => "int32", :out => "int32" }
    kernel = compile_kernel(<<~RUBY, arrays: types)
      proc { |i|
        w = CArray.new(:int32, [7])
        (0...7).each { |k| w[k] = source[i, k] }
        sort(w)
        (0...7).each { |k| out[i, k] = w[k] }
      }
    RUBY
    kernel.call({ :source => source, :out => out }, {}, [[0, 1, 1]], {})
    assert_equal(values.sort, (0...7).map { |k| out[0, k] })
  end

  def test_sort_of_a_float32_array_matches_carrays_own_sort
    values = (0...9).map { |k| ((k * 37 + 11) % 101) * 0.5 }
    source = CArray.float32(1, 9) { [values] }
    out = CArray.float32(1, 9)
    CArray.jit_for(1) { |i|
      w = CArray.float32(9)
      (0...9).each { |k| w[k] = source[i, k] }
      sort(w)
      (0...9).each { |k| out[i, k] = w[k] }
    }
    reference = CArray.float32(9) { values }.sort
    assert_equal(reference.to_a, (0...9).map { |k| out[0, k] })
  end

  def test_a_median_is_the_middle_of_a_sorted_local_array
    a = CArray.double(5, 9)
    a.seq!(3.0, 7.0)
    a.map! { |value| (value * 13) % 29 }
    median = CArray.double(5)
    CArray.jit_for(5) { |i|
      w = CArray.double(9)
      (0...9).each { |k| w[k] = a[i, k] }
      sort(w)
      median[i] = w[4]
    }
    reference = (0...5).map { |i| (0...9).map { |k| a[i, k] }.sort[4] }
    assert_arrays_bits_equal(CArray.double(5) { reference }, median)
  end

  # ---------- what the C says ----------

  def test_the_network_for_nine_carries_no_branch
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(9)
        (0...9).each { |k| w[k] = out[i] + k }
        sort(w)
        out[i] = w[4]
      }
    RUBY
    helper = kernel.c_source[/static inline void\ncarray_jit_sort_float64_9.*?\n\}/m]
    refute_nil(helper, "the network helper should be in the preamble")
    refute_match(/\bif\b|\bwhile\b|\bfor\b|\?/, helper,
                 "the network is a fixed sequence, with nothing to branch on")
    assert_equal(25, helper.scan(/carray_jit_cx_float64/).size,
                 "nine cells take 25 compare-exchanges")
  end

  def test_a_length_past_the_networks_is_a_loop
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(17)
        (0...17).each { |k| w[k] = out[i] + k }
        sort(w)
        out[i] = w[8]
      }
    RUBY
    refute_match(/carray_jit_sort_float64_17/, kernel.c_source)
    assert_match(/carray_jit_sort_float64 \(double \*w, int64_t n\)/,
                 kernel.c_source)
    assert_match(/carray_jit_sort_float64\(w, 17\)/, kernel.c_source)
  end

  def test_the_sort_helpers_borrow_nothing_from_libc_that_loses_a_nan
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(9)
        (0...9).each { |k| w[k] = out[i] + k }
        sort(w)
        out[i] = w[0]
      }
    RUBY
    refute_match(/qsort/, kernel.c_source)
    # fmin and fmax answer the other number when one is a NaN, which drops a
    # cell.  A sort has to put every cell somewhere, so the comparator is
    # written out.
    refute_match(/\bfmin\b|\bfmax\b|\bfminf\b|\bfmaxf\b/, kernel.c_source)
  end

  # A comparison rather than fmin / fmax: the same NaN rule, and the first
  # of two equal cells kept, which fmin leaves to the library.
  def test_the_min_and_max_helpers_fold_by_comparison
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(9)
        (0...9).each { |k| w[k] = out[i] + k }
        out[i] = min(w) + max(w)
      }
    RUBY
    assert_match(/if \( w\[k\] < best \|\| best != best \) best = w\[k\];/,
                 kernel.c_source)
    assert_match(/if \( w\[k\] > best \|\| best != best \) best = w\[k\];/,
                 kernel.c_source)
    refute_match(/\bfmin\(|\bfmax\(/, kernel.c_source)
    assert_match(/double best = NAN;/, kernel.c_source)
  end

  # An integer type has no NaN, so its folds stay on the limit and the
  # comparison -- fmin over an int64 would go through a double and lose the
  # large ones.
  def test_the_integer_helpers_keep_the_limit_and_the_comparison
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "int64" })
      proc { |i|
        w = CArray.int64(9)
        (0...9).each { |k| w[k] = out[i] + k }
        out[i] = min(w) + max(w)
      }
    RUBY
    refute_match(/\bfmin\(|\bfmax\(/, kernel.c_source)
    assert_match(/int64_t best = INT64_MAX;/, kernel.c_source)
    assert_match(/int64_t best = INT64_MIN;/, kernel.c_source)
  end

  def test_one_helper_serves_two_sorts_of_one_type_and_length
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
        v = CArray.double(9)
        w = CArray.double(9)
        (0...9).each { |k| v[k] = out[i] + k }
        (0...9).each { |k| w[k] = out[i] - k }
        sort(v)
        sort(w)
        out[i] = v[0] + w[0]
      }
    RUBY
    assert_equal(1, kernel.c_source.scan(/^carray_jit_sort_float64_9 \(/m).size)
    assert_equal(1, kernel.c_source.scan(/^carray_jit_cx_float64 \(/m).size)
  end

  def test_two_types_take_two_helpers
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
        v = CArray.double(9)
        w = CArray.new(:int32, [9])
        (0...9).each { |k| v[k] = out[i] + k }
        (0...9).each { |k| w[k] = k }
        sort(v)
        sort(w)
        out[i] = v[0] + w[0]
      }
    RUBY
    assert_match(/carray_jit_sort_float64_9/, kernel.c_source)
    assert_match(/carray_jit_sort_int32_9/, kernel.c_source)
  end

  def test_a_kernel_with_no_intrinsic_carries_no_helper
    kernel = compile_kernel("proc { |i| a[i] = a[i] * 2.0 }")
    refute_match(/carray_jit_sum|carray_jit_min_|carray_jit_max_|carray_jit_sort|carray_jit_cx/,
                 kernel.c_source)
  end

  # ---------- what is refused ----------

  def test_a_captured_array_is_refused_with_what_it_would_cost
    pattern = /`a` is an array the block closed over/
    error = refuse(<<~RUBY, pattern, arrays: { :a => "float64", :out => "float64" })
      proc { |i| out[i] = sum(a) }
    RUBY
    assert_match(/per cell/, error.message)
  end

  def test_a_scalar_is_refused
    refuse(<<~RUBY, /takes a local array/, arrays: { :out => "float64" }, scalars: { :x => 1.0 })
      proc { |i| out[i] = sum(x) }
    RUBY
  end

  def test_an_expression_is_refused
    refuse(<<~RUBY, /takes a local array/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(4)
        out[i] = sum(w[0] + 1.0)
      }
    RUBY
  end

  def test_two_arguments_are_refused_with_what_to_write_instead
    numbers = { :x => 1.0, :y => 2.0 }
    error = refuse(<<~RUBY, /`min` takes one local array/, arrays: { :out => "float64" }, scalars: numbers)
      proc { |i| out[i] = min(x, y) }
    RUBY
    assert_match(/x < y \? x : y/, error.message)
    assert_match(/clamp/, error.message)
  end

  def test_a_method_on_an_array_is_refused
    pattern = /`sum` is a method CArray answers outside a kernel/
    refuse(<<~RUBY, pattern, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(4)
        out[i] = w.sum
      }
    RUBY
  end

  def test_sum_standing_as_a_statement_is_refused
    refuse(<<~RUBY, /puts that value nowhere/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(4)
        sum(w)
        out[i] = w[0]
      }
    RUBY
  end

  def test_sort_standing_as_an_expression_is_refused
    pattern = /`sort` rearranges the array and has no value/
    refuse(<<~RUBY, pattern, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(4)
        out[i] = sort(w)
      }
    RUBY
  end

  def test_the_minimum_of_a_complex_array_is_refused
    refuse(<<~RUBY, /does not order Complex/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.new(:cmplx128, [4])
        out[i] = min(w).real
      }
    RUBY
  end

  def test_sorting_a_complex_array_is_refused
    refuse(<<~RUBY, /does not order Complex/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.new(:cmplx128, [4])
        sort(w)
        out[i] = w[0].real
      }
    RUBY
  end

  def test_the_sum_of_a_boolean_array_is_refused
    refuse(<<~RUBY, /`sum` adds numbers/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.boolean(4)
        out[i] = sum(w)
      }
    RUBY
  end

  def test_the_minimum_of_a_boolean_array_is_refused
    refuse(<<~RUBY, /`true` and `false`/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.boolean(4)
        out[i] = min(w) ? 1.0 : 0.0
      }
    RUBY
  end

  def test_an_array_out_of_sight_is_refused
    refuse(<<~RUBY, /belongs to the loop block/, arrays: { :out => "float64" })
      proc { |i|
        (0...2).each { |k| w = CArray.double(4); w[0] = 1.0 }
        out[i] = sum(w)
      }
    RUBY
  end

  # A name the block gave a number is not an array, whatever it is passed to.
  def test_a_local_number_is_refused
    refuse(<<~RUBY, /takes a local array/, arrays: { :out => "float64" })
      proc { |i|
        w = 1.0
        out[i] = sum(w)
      }
    RUBY
  end

  # ---------- the other entry points ----------

  # A window has no index to pick a row of captured workspace by, so these
  # are the spellings the intrinsics were wanted in: the median filter and
  # the ensemble median lose their sort loop entirely.

  def test_a_spread_is_max_minus_min_over_a_window
    field = CArray.double(7, 7).seq!
    field.map! { |value| (value * 13) % 29 }
    out = CArray.jit_stencil(field, border: :clamp) { |a|
      w = CArray.double(9)
      w[0] = a[-1, -1]; w[1] = a[-1, 0]; w[2] = a[-1, 1]
      w[3] = a[0, -1];  w[4] = a[0, 0];  w[5] = a[0, 1]
      w[6] = a[1, -1];  w[7] = a[1, 0];  w[8] = a[1, 1]
      max(w) - min(w)
    }
    7.times { |row| 7.times { |column|
      window = (-1..1).flat_map { |dr| (-1..1).map { |dc|
        field[[[row + dr, 0].max, 6].min, [[column + dc, 0].max, 6].min]
      } }
      assert_equal(window.max - window.min, out[row, column],
                   "cell #{row},#{column}")
    } }
  end

  # The proposal writes this one with `border: :mask`, which is not a masked
  # kernel: the frame is marked before the loop runs and the loop never
  # reaches it, so what the kernel carries is what the operands carry.
  def test_the_spread_may_be_written_with_a_frame_border
    field = CArray.double(7, 7).seq!
    field.map! { |value| (value * 13) % 29 }
    out = CArray.jit_stencil(field, border: :mask) { |a|
      w = CArray.double(9)
      w[0] = a[-1, -1]; w[1] = a[-1, 0]; w[2] = a[-1, 1]
      w[3] = a[0, -1];  w[4] = a[0, 0];  w[5] = a[0, 1]
      w[6] = a[1, -1];  w[7] = a[1, 0];  w[8] = a[1, 1]
      max(w) - min(w)
    }
    assert_equal(UNDEF, out[0, 0], "the frame is marked")
    (1..5).each { |row| (1..5).each { |column|
      window = (-1..1).flat_map { |dr| (-1..1).map { |dc|
        field[row + dr, column + dc]
      } }
      assert_equal(window.max - window.min, out[row, column],
                   "cell #{row},#{column}")
    } }
  end

  def test_sum_in_a_jit_each_block
    a = CArray.double(6).seq!(1.0)
    b = CArray.double(6).seq!(2.0)
    out = CArray.double(6)
    CArray.jit_each {
      w = CArray.double(3)
      w[0] = a
      w[1] = b
      w[2] = a * b
      out = sum(w)
    }
    reference = (0...6).map { |k| a[k] + b[k] + a[k] * b[k] }
    assert_arrays_bits_equal(CArray.double(6) { reference }, out)
  end

  def test_sort_in_a_jit_map_block
    m1 = CArray.double(8).seq!(3.0, 7.0).map! { |v| v % 29 }
    m2 = CArray.double(8).seq!(11.0, 5.0).map! { |v| v % 29 }
    m3 = CArray.double(8).seq!(2.0, 13.0).map! { |v| v % 29 }
    out = CArray.jit_map {
      w = CArray.double(3)
      w[0] = m1; w[1] = m2; w[2] = m3
      sort(w)
      w[1]
    }
    reference = (0...8).map { |k| [m1[k], m2[k], m3[k]].sort[1] }
    assert_arrays_bits_equal(CArray.double(8) { reference }, out)
  end

  def test_min_and_max_in_a_jit_each_block
    a = CArray.double(6).seq!(1.0)
    b = CArray.double(6).seq!(9.0, -2.0)
    low = CArray.double(6)
    high = CArray.double(6)
    CArray.jit_each {
      w = CArray.double(2)
      w[0] = a
      w[1] = b
      low = min(w)
      high = max(w)
    }
    6.times do |k|
      assert_equal([a[k], b[k]].min, low[k], "cell #{k}")
      assert_equal([a[k], b[k]].max, high[k], "cell #{k}")
    end
  end

  # A local array under masks carries one of its own, a byte a cell -- but
  # what the four should do with a missing cell is not decided, so they are
  # refused over an array that carries one.
  def test_an_intrinsic_over_a_masked_kernel_is_refused
    a = CArray.double(6).seq!(1.0)
    a[2] = UNDEF
    out = CArray.double(6)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { w = CArray.double(2); w[0] = a; w[1] = a; out = sum(w) }
    end
    assert_match(/`sum`/, error.message)
    assert_match(/carries masks/, error.message)
  end

  def test_the_median_filter_loses_its_sort_loop
    image = CArray.double(7, 7).seq!
    image.map! { |value| (value * 13) % 29 }
    with_sort = CArray.jit_stencil(image, border: :clamp) { |a|
      w = CArray.double(9)
      w[0] = a[-1, -1]; w[1] = a[-1, 0]; w[2] = a[-1, 1]
      w[3] = a[0, -1];  w[4] = a[0, 0];  w[5] = a[0, 1]
      w[6] = a[1, -1];  w[7] = a[1, 0];  w[8] = a[1, 1]
      sort(w)
      w[4]
    }
    written_out = CArray.jit_stencil(image, border: :clamp) { |a|
      w = CArray.double(9)
      w[0] = a[-1, -1]; w[1] = a[-1, 0]; w[2] = a[-1, 1]
      w[3] = a[0, -1];  w[4] = a[0, 0];  w[5] = a[0, 1]
      w[6] = a[1, -1];  w[7] = a[1, 0];  w[8] = a[1, 1]
      (1...9).each { |k|
        key = w[k]
        j = k - 1
        while j >= 0 && w[j] > key
          w[j + 1] = w[j]
          j -= 1
        end
        w[j + 1] = key
      }
      w[4]
    }
    assert_equal(written_out.to_a, with_sort.to_a)
  end

  # ---------- inside a compiled function's body ----------

  MED3 = CArray.jit_function(
    "double med3(double a, double b, double c)") { |a, b, c|
    w = CArray.double(3)
    w[0] = a; w[1] = b; w[2] = c
    sort(w)
    w[1]
  }

  def test_sort_in_a_function_body_called_from_ruby
    [[3.0, 1.0, 2.0], [1.0, 1.0, 1.0], [5.0, 4.0, 9.0]].each do |a, b, c|
      assert_equal([a, b, c].sort[1], MED3.call(a, b, c), "#{[a, b, c].inspect}")
    end
  end

  def test_sort_in_a_function_body_called_from_a_kernel
    third = CArray.double(6).seq!(1.0, 3.0)
    out = CArray.double(6)
    CArray.jit_for(6) { |i| out[i] = MED3.call(3.0, 1.0, third[i]) }
    reference = (0...6).map { |i| [3.0, 1.0, third[i]].sort[1] }
    assert_arrays_bits_equal(CArray.double(6) { reference }, out)
  end

  def test_sum_in_a_function_body
    totals = CArray.jit_function("double tot(double s)") { |s|
      w = CArray.double(4)
      (0...4).each { |k| w[k] = s + k }
      sum(w)
    }
    assert_equal(10.0, totals.call(1.0), "1 + 2 + 3 + 4")
    out = CArray.double(3)
    CArray.jit_for(3) { |i| out[i] = totals.call(i * 1.0) }
    assert_equal([6.0, 10.0, 14.0], out.to_a)
  end

  def test_min_and_max_in_a_function_body
    spread = CArray.jit_function("double spread(double a, double b, double c)") { |a, b, c|
      w = CArray.double(3)
      w[0] = a; w[1] = b; w[2] = c
      max(w) - min(w)
    }
    assert_equal(8.0, spread.call(1.0, 9.0, 4.0))
    out = CArray.double(2)
    CArray.jit_for(2) { |i| out[i] = spread.call(1.0, 9.0, i * 1.0) }
    assert_equal([9.0, 8.0], out.to_a)
  end

  # ---------- the helpers a pasted body brings with it ----------

  def helper_count (source, pattern)
    source.scan(pattern).size
  end

  def test_a_pasted_body_brings_its_helper_into_the_kernels_preamble
    out = CArray.double(2)
    CArray::JIT.clear_registry
    before = CArray::JIT.registry.keys
    CArray.jit_for(2) { |i| out[i] = MED3.call(3.0, 1.0, i * 1.0) }
    kernel = CArray::JIT.registry.fetch((CArray::JIT.registry.keys - before).first)
    assert_equal(1, helper_count(kernel.c_source, /^carray_jit_sort_float64_3 \(/),
                 "the body's sort helper belongs in the file it is pasted into")
    assert_equal(1, helper_count(kernel.c_source, /^carray_jit_cx_float64 \(/))
    assert_match(/#include <string\.h>/, kernel.c_source,
                 "the body clears its array, so the header is this file's too")
  end

  def test_a_body_and_its_kernel_sorting_two_lengths_take_two_helpers
    out = CArray.double(2)
    CArray::JIT.clear_registry
    before = CArray::JIT.registry.keys
    CArray.jit_for(2) { |i|
      v = CArray.double(5)
      (0...5).each { |m| v[m] = (5 - m) * 1.0 }
      sort(v)
      out[i] = v[0] + MED3.call(3.0, 1.0, i * 1.0)
    }
    kernel = CArray::JIT.registry.fetch((CArray::JIT.registry.keys - before).first)
    assert_equal(1, helper_count(kernel.c_source, /^carray_jit_sort_float64_3 \(/),
                 "the body's length")
    assert_equal(1, helper_count(kernel.c_source, /^carray_jit_sort_float64_5 \(/),
                 "the kernel's length")
    assert_equal(1, helper_count(kernel.c_source, /^carray_jit_cx_float64 \(/),
                 "and one compare-exchange between them")
    reference = (0...2).map { |i| 1.0 + [3.0, 1.0, i * 1.0].sort[1] }
    assert_equal(reference, out.to_a, "and both sorts give their answer")
  end

  def test_two_pasted_bodies_sorting_alike_take_one_helper
    other = CArray.jit_function(
      "double med3b(double a, double b, double c)") { |a, b, c|
      w = CArray.double(3)
      w[0] = a * 2.0; w[1] = b; w[2] = c
      sort(w)
      w[1]
    }
    out = CArray.double(2)
    CArray::JIT.clear_registry
    before = CArray::JIT.registry.keys
    CArray.jit_for(2) { |i|
      out[i] = MED3.call(3.0, 1.0, i * 1.0) + other.call(3.0, 1.0, i * 1.0)
    }
    kernel = CArray::JIT.registry.fetch((CArray::JIT.registry.keys - before).first)
    assert_equal(1, helper_count(kernel.c_source, /^carray_jit_sort_float64_3 \(/),
                 "one helper serves both bodies")
    assert_equal(1, helper_count(kernel.c_source, /^carray_jit_cx_float64 \(/))
    reference = (0...2).map { |i|
      [3.0, 1.0, i * 1.0].sort[1] + [6.0, 1.0, i * 1.0].sort[1]
    }
    assert_equal(reference, out.to_a)
  end

  def test_a_standalone_body_carries_its_own_helper
    assert_equal(1, helper_count(MED3.c_source, /^carray_jit_sort_float64_3 \(/),
                 "the object CFunction#call runs needs it too")
    assert_match(/#include <string\.h>/, MED3.c_source)
  end

  # ---------- the argument stays one axis ----------

  # A local array may have more than one axis, but these four take one.
  # `sum(m)` over a row-major sweep of every cell would be natural enough;
  # `sort(m)` has no obvious meaning at all, and the four keep one rule.
  def test_more_than_one_axis_is_refused
    { "sum" => "out[i] = sum(m)", "min" => "out[i] = min(m)",
      "max" => "out[i] = max(m)", "sort" => "sort(m)\n  out[i] = m[0, 0]" }
      .each do |name, line|
      error = refuse(<<~RUBY, /`m` has 2 axes/, arrays: { :out => "float64" })
        proc { |i|
          m = CArray.double(3, 4)
          #{line}
        }
      RUBY
      assert_match(/`#{name}` takes an array of one axis/, error.message)
    end
  end

  def test_one_axis_of_a_two_dimensional_array_is_not_a_way_round_it
    # There is no spelling that hands one row over: a subscript reaches a
    # cell, not a row, so `m[0]` is refused for not being an array at all
    # rather than for its rank.
    error = refuse(<<~RUBY, /`m\[0\]` is not one/, arrays: { :out => "float64" })
      proc { |i|
        m = CArray.double(3, 4)
        out[i] = sum(m[0])
      }
    RUBY
    assert_match(/takes a local array .* named on its own/, error.message)
  end

  # ---------- the names are the compiler's, not the block's ----------

  def test_a_local_may_be_called_sum_beside_a_call_to_sum
    out = CArray.double(2)
    CArray.jit_for(2) { |i|
      w = CArray.double(3)
      (0...3).each { |k| w[k] = k * 1.0 }
      sum = sum(w)
      out[i] = sum
    }
    assert_equal([3.0, 3.0], out.to_a)
  end

  def test_a_captured_function_called_sum_does_not_collide
    f = CArray.jit_function("double sum(double x)") { |x| x * 2.0 }
    out = CArray.double(2)
    CArray.jit_for(2) { |i|
      w = CArray.double(3)
      (0...3).each { |k| w[k] = k * 1.0 }
      out[i] = f.call(sum(w))
    }
    assert_equal([6.0, 6.0], out.to_a)
  end

end
