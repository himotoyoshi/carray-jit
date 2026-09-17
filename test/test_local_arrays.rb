require_relative "test_helper"
require "rbconfig"

# A local variable falls to a C variable, and a `CArray` the block makes
# falls to a C array.  It lives on the stack of the scope it was written in,
# its shape is what the block wrote, and it is reached at a subscript the way
# a captured array is.
#
# What it is held to is the same Ruby loop written out by hand, cell for cell
# and bit for bit.  Where the Ruby loop cannot be the reference -- a float32
# array, whose every operation Ruby would widen to a double -- the reference
# is the same algorithm written with a captured array of workspace, which is
# a jit kernel this suite already holds to CArray's own operators.
class TestLocalArrays < Minitest::Test

  # ---------- what it computes ----------

  def test_a_row_wise_mode_matches_the_same_loop_in_ruby
    labels = CArray.uint8(5, 40)
    labels.seq!
    labels.map! { |value| value % 7 }
    mode = CArray.int64(5)
    CArray.jit_for(5) { |i|
      counts = CArray.int64(256)
      (0...40).each { |j| counts[labels[i, j]] += 1 }
      best = 0
      (1...256).each { |c| best = c if counts[c] > counts[best] }
      mode[i] = best
    }
    reference = (0...5).map { |i|
      counts = CArray.int64(256)
      (0...40).each { |j| counts[labels[i, j]] += 1 }
      best = 0
      (1...256).each { |c| best = c if counts[c] > counts[best] }
      best
    }
    assert_equal(reference, mode.to_a)
  end

  def test_an_insertion_sort_over_a_local_array_matches_ruby
    a = CArray.double(4, 9)
    a.seq!(3.0, 7.0)
    a.map! { |value| (value * 13) % 29 }
    median = CArray.double(4)
    CArray.jit_for(4) { |i|
      w = CArray.double(9)
      (0...9).each { |k| w[k] = a[i, k] }
      (1...9).each { |k|
        key = w[k]
        j = k - 1
        while j >= 0 && w[j] > key
          w[j + 1] = w[j]
          j -= 1
        end
        w[j + 1] = key
      }
      median[i] = w[4]
    }
    reference = (0...4).map { |i|
      w = CArray.double(9)
      (0...9).each { |k| w[k] = a[i, k] }
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
    assert_arrays_bits_equal(CArray.double(4) { reference }, median)
  end

  # Every storage type the constructors reach, against the same loop in Ruby.
  # float32 and cmplx64 are not here: Ruby would compute them as doubles, so
  # the reference for those is a kernel (below).
  #
  # Compiled from source text rather than from a live block, because the type
  # has to be written out: a Symbol the test interpolated would be a name the
  # block closed over, which is not the spelling under test.
  %w[int8 int16 int32 int64 uint8 uint16 uint32 uint64
     float64 cmplx128].each do |type|
    define_method("test_a_local_#{type}_array_matches_the_same_loop_in_ruby") do
      source = CArray.new(type.to_sym, [4, 5])
      source.seq!(1, 2)
      out = CArray.new(type.to_sym, [4])
      kernel = compile_kernel(<<~RUBY, arrays: { :source => type, :out => type })
        proc { |i|
          w = CArray.new(:#{type}, [5])
          (0...5).each { |k| w[k] = source[i, k] + k }
          total = w[0]
          (1...5).each { |k| total = total + w[k] }
          out[i] = total
        }
      RUBY
      kernel.call({ :source => source, :out => out }, {}, [[0, 4, 1]], {})
      # The reference stores its answer in an array of the same type, as the
      # kernel does: a narrow integer wraps on the way in, and comparing
      # against a Ruby Integer would be comparing against a wider type.
      reference = CArray.new(type.to_sym, [4])
      (0...4).each { |i|
        w = CArray.new(type.to_sym, [5])
        (0...5).each { |k| w[k] = source[i, k] + k }
        total = w[0]
        (1...5).each { |k| total = total + w[k] }
        reference[i] = total
      }
      assert_equal(reference.to_a, out.to_a)
    end
  end

  def test_a_local_boolean_array_normalises_what_is_stored
    source = CArray.int32(4, 5)
    source.seq!(-2)
    out = CArray.int64(4)
    CArray.jit_for(4) { |i|
      flags = CArray.boolean(5)
      (0...5).each { |k| flags[k] = source[i, k] > 0 }
      count = 0
      (0...5).each { |k| count += 1 if flags[k] }
      out[i] = count
    }
    reference = (0...4).map { |i|
      (0...5).count { |k| source[i, k] > 0 }
    }
    assert_equal(reference, out.to_a)
  end

  # §6.7: float32 computes narrow in a kernel and wide in Ruby, so the
  # reference is the same algorithm over a captured row of workspace.
  def test_a_local_float32_array_matches_a_row_of_captured_workspace
    a = CArray.float32(6, 5)
    a.seq!(1.0, 0.25)
    mine = CArray.float32(6)
    CArray.jit_for(6) { |i|
      w = CArray.float32(5)
      (0...5).each { |k| w[k] = a[i, k] * a[i, k] + 1.0 }
      total = w[0]
      (1...5).each { |k| total = total + w[k] / 3.0 }
      mine[i] = total
    }
    work = CArray.float32(6, 5)
    theirs = CArray.float32(6)
    CArray.jit_for(6) { |i|
      (0...5).each { |k| work[i, k] = a[i, k] * a[i, k] + 1.0 }
      total = work[i, 0]
      (1...5).each { |k| total = total + work[i, k] / 3.0 }
      theirs[i] = total
    }
    assert_arrays_bits_equal(theirs, mine)
  end

  def test_a_local_cmplx64_array_matches_a_row_of_captured_workspace
    a = CArray.cmplx64(4, 4)
    a.seq!(1.0, 0.5)
    mine = CArray.cmplx64(4)
    CArray.jit_for(4) { |i|
      w = CArray.cmplx64(4)
      (0...4).each { |k| w[k] = a[i, k] * (1.0 + 1.0i) }
      total = w[0]
      (1...4).each { |k| total = total + w[k] }
      mine[i] = total
    }
    work = CArray.cmplx64(4, 4)
    theirs = CArray.cmplx64(4)
    CArray.jit_for(4) { |i|
      (0...4).each { |k| work[i, k] = a[i, k] * (1.0 + 1.0i) }
      total = work[i, 0]
      (1...4).each { |k| total = total + work[i, k] }
      theirs[i] = total
    }
    assert_arrays_bits_equal(theirs, mine)
  end

  # ---------- the three spellings ----------

  def test_the_three_constructors_reach_the_same_array
    out = CArray.int64(3, 3)
    CArray.jit_for(3) { |i|
      a = CArray.int64(4)
      b = CArray.new(:int64, [4])
      c = CArray.empty(:int64, [4])
      (0...4).each { |k| c[k] = 0 }
      a[i] = 5
      b[i] = 5
      c[i] = 5
      out[i, 0] = a[i]
      out[i, 1] = b[i]
      out[i, 2] = c[i]
    }
    assert_equal([[5, 5, 5], [5, 5, 5], [5, 5, 5]], out.to_a)
  end

  def test_the_receiver_may_be_written_with_the_leading_colons
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      w = ::CArray.double(2)
      w[0] = i * 1.0
      w[1] = w[0] + 1.0
      out[i] = w[1]
    }
    assert_equal([1.0, 2.0, 3.0], out.to_a)
  end

  ALIASES = { :float => "float32", :double => "float64",
              :complex => "cmplx64", :dcomplex => "cmplx128",
              :byte => "uint8", :short => "int16", :int => "int32" }

  def test_the_aliases_name_the_type_carray_names
    ALIASES.each do |spelling, storage|
      kernel = compile_kernel(<<~RUBY, arrays: { :out => storage })
        proc { |i|
          w = CArray.#{spelling}(2)
          w[0] = 1
          out[i] = w[0]
        }
      RUBY
      assert_match(/#{Regexp.escape(CArray::JIT::CGenerator::STORAGE_C_TYPES.fetch(storage))} w\[2\];/,
                   kernel.c_source,
                   "`CArray.#{spelling}` should be #{storage}")
    end
  end

  # ---------- what the statement emits ----------

  def test_a_zeroed_array_is_cleared_at_the_statement
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "int64" })
      proc { |i|
        counts = CArray.int64(4)
        counts[0] = 1
        out[i] = counts[0]
      }
    RUBY
    assert_match(/int64_t counts\[4\];/, kernel.c_source)
    assert_match(/memset\(counts, 0, sizeof counts\);/, kernel.c_source)
    assert_match(/#include <string\.h>/, kernel.c_source)
  end

  def test_an_empty_array_is_not_cleared_and_pulls_in_no_header
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "int64" })
      proc { |i|
        scratch = CArray.empty(:int64, [4])
        scratch[0] = 1
        out[i] = scratch[0]
      }
    RUBY
    assert_match(/int64_t scratch\[4\];/, kernel.c_source)
    refute_match(/memset/, kernel.c_source)
    refute_match(/#include <string\.h>/, kernel.c_source)
  end

  def test_a_kernel_with_no_local_array_pulls_in_no_string_header
    kernel = compile_kernel("proc { |i| a[i] = a[i] * 2.0 }")
    refute_match(/#include <string\.h>/, kernel.c_source)
    refute_match(/memset/, kernel.c_source)
  end

  def test_the_zeroed_family_starts_from_zero_at_every_pass
    labels = CArray.uint8(4, 6)
    labels.seq!
    labels.map! { |value| value % 3 }
    out = CArray.int64(4)
    CArray.jit_for(4) { |i|
      counts = CArray.int64(3)
      (0...6).each { |j| counts[labels[i, j]] += 1 }
      out[i] = counts[0] * 100 + counts[1] * 10 + counts[2]
    }
    reference = (0...4).map { |i|
      counts = [0, 0, 0]
      (0...6).each { |j| counts[labels[i, j]] += 1 }
      counts[0] * 100 + counts[1] * 10 + counts[2]
    }
    assert_equal(reference, out.to_a,
                 "each pass has to start from a cleared array")
  end

  def test_the_shape_is_folded_where_it_is_written
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "int64" })
      proc { |i|
        w = CArray.int64(2 * 3 + 1)
        w[6] = 1
        out[i] = w[6]
      }
    RUBY
    assert_match(/int64_t w\[7\];/, kernel.c_source)
  end

  # ---------- names ----------

  # The C the kernel writes for itself owns `data`, `error` and `p_a`; a
  # local array is moved off them the way a scalar local is.
  %w[data error strides bounds p_a a_n0 a_s0 index0].each do |name|
    define_method("test_a_local_array_may_be_called_#{name}") do
      out = CArray.double(3)
      a = CArray.double(3).seq!(1.0)
      kernel = compile_kernel(<<~RUBY, arrays: { :a => "float64", :out => "float64" })
        proc { |i|
          #{name} = CArray.double(2)
          #{name}[0] = a[i]
          #{name}[1] = #{name}[0] * 2.0
          out[i] = #{name}[1]
        }
      RUBY
      kernel.call({ :a => a, :out => out }, {}, [[0, 3, 1]], {})
      assert_equal([2.0, 4.0, 6.0], out.to_a)
    end
  end

  def test_sibling_inner_loops_may_each_make_an_array_of_one_name
    a = CArray.double(3, 4)
    a.seq!(1.0)
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      total = 0.0
      (0...1).each { |k|
        w = CArray.double(4)
        (0...4).each { |m| w[m] = a[i, m] }
        total = total + w[3]
      }
      (0...1).each { |k|
        w = CArray.double(4)
        (0...4).each { |m| w[m] = a[i, m] * 10.0 }
        total = total + w[3]
      }
      out[i] = total
    }
    reference = (0...3).map { |i| a[i, 3] + a[i, 3] * 10.0 }
    assert_arrays_bits_equal(CArray.double(3) { reference }, out)
  end

  def test_one_name_at_two_shapes_is_two_arrays
    out = CArray.int64(2)
    CArray.jit_for(2) { |i|
      w = CArray.int64(2)
      w[0] = 7
      first = w[0]
      w = CArray.int64(5)
      w[4] = 9
      out[i] = first + w[4]
    }
    assert_equal([16, 16], out.to_a)
  end

  # Out of sight is out of the way: the array belonged to a block that closed,
  # so a line below it may introduce a number under the same name, and a line
  # below that reads the number.
  def test_a_name_an_inner_loop_gave_an_array_may_hold_a_number_after_it
    out = CArray.double(2)
    CArray.jit_for(2) { |i|
      (0...2).each { |k| w = CArray.double(4); w[0] = 1.0 }
      w = 2.0
      out[i] = w
    }
    assert_equal([2.0, 2.0], out.to_a)
  end

  def test_a_name_an_inner_loop_gave_a_number_may_hold_an_array_after_it
    out = CArray.double(2)
    CArray.jit_for(2) { |i|
      (0...2).each { |k| w = 1.0; out[i] = w }
      w = CArray.double(4)
      w[0] = 3.0
      out[i] = w[0]
    }
    assert_equal([3.0, 3.0], out.to_a)
  end

  def test_an_array_may_not_take_a_name_the_block_gave_a_number
    pattern = /`w` holds a number here, and a local array is not a number/
    refuse(<<~RUBY, pattern, arrays: { :out => "float64" })
      proc { |i|
        w = 1.0
        w = CArray.double(4)
        out[i] = w[0]
      }
    RUBY
  end

  def test_a_number_may_not_take_a_name_the_block_gave_an_array
    pattern = /`w` is a local array here, and cannot hold a number/
    refuse(<<~RUBY, pattern, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(4)
        w = 1.0
        out[i] = w
      }
    RUBY
  end

  def test_an_array_may_not_take_the_name_of_a_loop_index
    refuse(<<~RUBY, /`i` is a loop index/, arrays: { :out => "float64" })
      proc { |i|
        i = CArray.double(4)
        out[0] = 1.0
      }
    RUBY
  end

  def test_an_array_made_in_an_inner_loop_is_gone_after_it
    pattern = /`w` belongs to the loop block it was assigned in/
    refuse(<<~RUBY, pattern, arrays: { :out => "float64" })
      proc { |i|
        (0...3).each { |k| w = CArray.double(4); w[0] = 1.0 }
        out[i] = w[0]
      }
    RUBY
  end

  def test_an_array_made_in_one_arm_of_a_branch_does_not_survive_it
    refuse(<<~RUBY, /`w`/, arrays: { :out => "float64", :a => "float64" })
      proc { |i|
        if a[i] > 0.0
          w = CArray.double(4)
          w[0] = 1.0
        else
          out[i] = 0.0
        end
        out[i] = w[0]
      }
    RUBY
  end

  # ---------- the bounds check, settled when the block is read ----------

  def test_a_reach_past_the_end_through_an_inner_index_is_refused
    error = refuse(<<~RUBY, /`t\[k \+ 1\]`/, arrays: { :out => "float64" })
      proc { |i|
        t = CArray.double(4)
        (0...4).each { |k| t[k + 1] = 0.0 }
        out[i] = t[0]
      }
    RUBY
    assert_match(/4/, error.message)
  end

  def test_a_reach_past_the_end_is_refused_inside_a_branch_too
    refuse(<<~RUBY, /`t\[k \+ 1\]`/, arrays: { :out => "float64" })
      proc { |i|
        t = CArray.double(4)
        (0...4).each { |k| t[k + 1] = 0.0 if k < 3 }
        out[i] = t[0]
      }
    RUBY
  end

  def test_a_reach_below_zero_through_an_inner_index_is_refused
    refuse(<<~RUBY, /`t\[k - 1\]`/, arrays: { :out => "float64" })
      proc { |i|
        t = CArray.double(4)
        (0...4).each { |k| t[k - 1] = 0.0 }
        out[i] = t[0]
      }
    RUBY
  end

  def test_an_inner_index_inside_the_shape_is_not_refused
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      t = CArray.double(4)
      (0...3).each { |k| t[k + 1] = k * 1.0 }
      out[i] = t[3]
    }
    assert_equal([2.0, 2.0, 2.0], out.to_a)
  end

  def test_a_literal_subscript_past_the_end_is_refused
    refuse(<<~RUBY, /`t\[4\]` is outside/, arrays: { :out => "float64" })
      proc { |i|
        t = CArray.double(4)
        t[4] = 0.0
        out[i] = t[0]
      }
    RUBY
  end

  def test_a_literal_negative_subscript_is_refused
    refuse(<<~RUBY, /counts from the start/, arrays: { :out => "float64" })
      proc { |i|
        t = CArray.double(4)
        t[-1] = 0.0
        out[i] = t[0]
      }
    RUBY
  end

  def test_a_local_array_takes_one_subscript_in_this_release
    refuse(<<~RUBY, /one axis/, arrays: { :out => "float64" })
      proc { |i|
        t = CArray.double(4)
        t[0, 1] = 0.0
        out[i] = t[0]
      }
    RUBY
  end

  # ---------- the bounds check, at the access ----------

  def test_a_read_at_a_position_off_the_end_raises
    a = CArray.int64(3).seq!(10)
    out = CArray.double(3)
    assert_raises(IndexError) do
      CArray.jit_for(3) { |i|
        w = CArray.double(4)
        out[i] = w[a[i]]
      }
    end
  end

  def test_a_write_at_a_position_off_the_end_raises_and_writes_nothing
    a = CArray.int64(1).seq!(9)
    probe = CArray.double(1)
    assert_raises(IndexError) do
      CArray.jit_for(1) { |i|
        w = CArray.double(4)
        w[0] = 11.0
        w[a[i]] = 99.0
        probe[i] = w[0]
      }
    end
  end

  def test_the_cell_a_refused_write_would_have_landed_on_is_left_alone
    # The position is off the end on the last pass only, so the passes before
    # it show what the guard did: cell zero holds what the block put there,
    # not the value the scatter was carrying.
    positions = CArray.int64(3)
    positions[0] = 0
    positions[1] = 1
    positions[2] = 9
    seen = CArray.double(3)
    assert_raises(IndexError) do
      CArray.jit_for(3) { |i|
        w = CArray.double(4)
        w[0] = 1.0
        w[positions[i]] = 2.0
        seen[i] = w[0]
      }
    end
    assert_equal(2.0, seen[0], "position 0 is inside and is written")
    assert_equal(1.0, seen[1], "position 1 does not touch cell zero")
  end

  def test_a_read_at_a_local_position_inside_the_array_is_not_checked_away
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      w = CArray.double(4)
      (0...4).each { |k| w[k] = k * 1.0 }
      j = 3
      total = 0.0
      while j >= 0
        total = total + w[j]
        j -= 1
      end
      out[i] = total
    }
    assert_equal([6.0, 6.0, 6.0, 6.0], out.to_a)
  end

  # ---------- a loop that reports leaves ----------

  LIMIT = 60

  def load_path
    extension = $LOADED_FEATURES.grep(%r{/carray_ext\.#{RbConfig::CONFIG['DLEXT']}\z}).first
    library = $LOADED_FEATURES.grep(%r{/carray\.rb\z}).first
    [File.expand_path("../lib", __dir__), extension, library]
      .compact.map { |path| File.directory?(path) ? path : File.dirname(path) }.uniq
  end

  # A kernel that has let go of the GVL is out of Timeout's reach, so the run
  # is a child process with a deadline and a KILL behind it.
  def run_isolated (script)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "local_arrays.rb")
      File.write(path, "require \"carray/jit\"\n" + script)
      reader, writer = IO.pipe
      pid = Process.spawn(RbConfig.ruby, *load_path.map { |p| "-I#{p}" }, path,
                          :out => writer, :err => writer)
      writer.close
      deadline = Time.now + LIMIT
      status = nil
      until (status = Process.wait2(pid, Process::WNOHANG)&.last)
        if Time.now > deadline
          Process.kill(:KILL, pid)
          Process.wait(pid)
          reader.close
          flunk "still running after #{LIMIT} s"
        end
        sleep 0.05
      end
      output = reader.read
      reader.close
      assert_predicate(status, :success?, output)
      output
    end
  end

  def test_a_while_whose_body_reads_a_local_array_off_the_end_stops
    output = run_isolated(<<~RUBY)
      out = CArray.double(1)
      begin
        CArray.jit_for(1) { |i|
          w = CArray.double(4)
          (0...4).each { |k| w[k] = 1.0 }
          j = 0
          s = 1.0
          while s != 0.0
            s = w[j]
            j += 1
          end
          out[i] = s
        }
        puts "no error"
      rescue IndexError
        puts "IndexError"
      end
    RUBY
    assert_equal("IndexError\n", output)
  end

  # ---------- the spellings that are not these ----------

  def test_the_numpy_and_numo_spellings_are_sent_to_the_carray_ones
    {
      "CArray.zeros(4)"        => /`CArray\.new\(:float64, \[4\]\)`/,
      "CArray.ones(4)"         => /CArray\.new/,
      "CArray.full(4, 1.0)"    => /CArray\.new/,
      "CArray.empty(4)"        => /CArray\.new/,
      "CArray::Int64.empty(4)" => /CArray\.new\(:int64, \[4\]\)/,
      "CArray::Int64.zeros(4)" => /CArray\.new\(:int64, \[4\]\)/,
    }.each do |spelling, pattern|
      refuse(<<~RUBY, pattern, arrays: { :out => "float64" })
        proc { |i|
          w = #{spelling}
          out[i] = w[0]
        }
      RUBY
    end
  end

  def test_the_two_dimensional_shapes_say_which_release_takes_them
    refuse(<<~RUBY, /one axis/, arrays: { :out => "float64" })
      proc { |i|
        m = CArray.double(3, 4)
        out[i] = m[0]
      }
    RUBY
    refuse(<<~RUBY, /one axis/, arrays: { :out => "float64" })
      proc { |i|
        m = CArray.new(:float64, [3, 4])
        out[i] = m[0]
      }
    RUBY
  end

  def test_object_and_fixlen_are_not_types_a_kernel_computes_with
    refuse(<<~RUBY, /`object`/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.object(4)
        out[i] = w[0]
      }
    RUBY
    refuse(<<~RUBY, /`fixlen`/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.fixlen(4)
        out[i] = w[0]
      }
    RUBY
  end

  def test_the_type_is_a_symbol_rather_than_one_of_carrays_constants
    refuse(<<~RUBY, /a Symbol/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.new(CA_INT64, [4])
        out[i] = w[0]
      }
    RUBY
  end

  def test_the_shape_is_written_out_rather_than_captured
    arrays = { :out => "float64" }
    refuse(<<~RUBY, /written out/, arrays: arrays, scalars: { :n => 4 })
      proc { |i|
        w = CArray.double(n)
        out[i] = w[0]
      }
    RUBY
    refuse(<<~RUBY, /written out/, arrays: arrays, scalars: { :n => 4 })
      proc { |i|
        w = CArray.new(:float64, [n])
        out[i] = w[0]
      }
    RUBY
  end

  def test_a_shape_of_zero_or_less_is_refused
    refuse(<<~RUBY, /at least one cell/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(0)
        out[i] = w[0]
      }
    RUBY
    refuse(<<~RUBY, /at least one cell/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(2 - 3)
        out[i] = w[0]
      }
    RUBY
  end

  def test_a_constructor_takes_no_block
    refuse(<<~RUBY, /block/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(4) { 1.0 }
        out[i] = w[0]
      }
    RUBY
  end

  def test_a_constructor_stands_on_the_right_of_an_assignment_and_nowhere_else
    refuse(<<~RUBY, /on the right of an assignment/, arrays: { :out => "float64" })
      proc { |i| out[i] = CArray.double(4)[0] }
    RUBY
    refuse(<<~RUBY, /on the right of an assignment/, arrays: { :out => "float64" })
      proc { |i| out[i] = CArray.double(4) + 1 }
    RUBY
  end

  def test_a_local_array_is_read_at_a_subscript_and_not_bare
    refuse(<<~RUBY, /index it/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(4)
        out[i] = w
      }
    RUBY
    refuse(<<~RUBY, /index it/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(4)
        out[i] = w + 1.0
      }
    RUBY
  end

  def test_a_local_array_has_no_methods
    refuse(<<~RUBY, /`sum`/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(4)
        out[i] = w.sum
      }
    RUBY
  end

  # The two reasons a kernel carries masks are told apart, because what to do
  # about them differs: one has a fill to choose, the other has a question to
  # take out of the kernel.
  def test_a_masked_operand_and_a_local_array_do_not_meet
    a = CArray.double(4).seq!(1.0)
    a[2] = UNDEF
    out = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i|
        w = CArray.double(2)
        w[0] = a[i]
        out[i] = w[0]
      }
    end
    assert_match(/`w` is a local array/, error.message)
    assert_match(/carries a mask/, error.message)
    assert_match(/strip_mask/, error.message)
  end

  def test_a_block_that_asks_about_undef_and_a_local_array_do_not_meet
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i|
        w = CArray.double(2)
        w[0] = a[i] == UNDEF ? 0.0 : a[i]
        out[i] = w[0]
      }
    end
    assert_match(/`w` is a local array/, error.message)
    assert_match(/asks about\s+UNDEF/, error.message)
    refute_match(/strip_mask/, error.message)
  end

  def test_a_masked_operand_with_the_mask_stripped_is_taken
    a = CArray.double(4).seq!(1.0)
    a[2] = UNDEF
    out = CArray.double(4)
    stripped = a.strip_mask(0.0)
    CArray.jit_for(4) { |i|
      w = CArray.double(2)
      w[0] = stripped[i]
      w[1] = w[0] * 2.0
      out[i] = w[1]
    }
    assert_equal([2.0, 4.0, 0.0, 8.0], out.to_a)
  end

  def test_a_local_array_carries_no_mask
    refuse(<<~RUBY, /carries no mask/, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(4)
        w[0] = UNDEF
        out[i] = w[0]
      }
    RUBY
  end

  def test_a_local_array_is_not_handed_to_a_c_function_in_this_release
    f = CArray.jit_function("double s2(const double x[2])") { |x| x[0] + x[1] }
    out = CArray.double(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i|
        w = CArray.double(2)
        w[0] = 1.0
        w[1] = 2.0
        out[i] = f.call(w)
      }
    end
    assert_match(/`w` is a local array/, error.message)
  end

  # ---------- the room it takes ----------

  def test_one_array_larger_than_the_limit_is_refused
    cells = CArray::JIT::Analyzer::LOCAL_ARRAY_BYTE_LIMIT / 8 + 1
    pattern = /#{CArray::JIT::Analyzer::LOCAL_ARRAY_BYTE_LIMIT}/
    refuse(<<~RUBY, pattern, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(#{cells})
        out[i] = w[0]
      }
    RUBY
  end

  def test_one_array_at_the_limit_is_taken
    cells = CArray::JIT::Analyzer::LOCAL_ARRAY_BYTE_LIMIT / 8
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(#{cells})
        w[0] = 1.0
        out[i] = w[0]
      }
    RUBY
    assert_match(/double w\[#{cells}\];/, kernel.c_source)
  end

  def test_the_arrays_of_one_kernel_together_are_held_to_a_limit
    each = CArray::JIT::Analyzer::LOCAL_ARRAY_BYTE_LIMIT / 8
    count = CArray::JIT::Analyzer::LOCAL_ARRAY_TOTAL_BYTE_LIMIT /
            CArray::JIT::Analyzer::LOCAL_ARRAY_BYTE_LIMIT + 1
    body = (0...count).map { |n|
      "  w#{n} = CArray.double(#{each})\n  w#{n}[0] = 1.0\n"
    }.join
    pattern = /#{CArray::JIT::Analyzer::LOCAL_ARRAY_TOTAL_BYTE_LIMIT}/
    refuse(<<~RUBY, pattern, arrays: { :out => "float64" })
      proc { |i|
      #{body}
        out[i] = w0[0]
      }
    RUBY
  end

  # ---------- the entry points that do not take one yet ----------

  def test_the_other_entry_points_say_which_release_takes_a_local_array
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)

    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { w = CArray.double(2); w[0] = a; out = w[0] }
    end
    assert_match(/local array/, error.message)

    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_map { w = CArray.double(2); w[0] = a; w[0] }
    end
    assert_match(/local array/, error.message)

    image = CArray.double(4, 4).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(image) { |win| w = CArray.double(2); w[0] = win[0, 0]; w[0] }
    end
    assert_match(/local array/, error.message)

    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double f(double x)") { |x|
        w = CArray.double(2)
        w[0] = x
        w[0]
      }
    end
    assert_match(/local array/, error.message)

    x = CArray.double(4, 4).seq!
    y = CArray.double(4, 4).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, k, j|
        w = CArray.double(2)
        x[i, k] * y[k, j]
      }
    end
    assert_match(/local array/, error.message)
  end

  # ---------- the cache ----------

  def test_two_shapes_of_one_block_are_two_kernels
    first = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i| w = CArray.double(4); w[0] = 1.0; out[i] = w[0] }
    RUBY
    second = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i| w = CArray.double(5); w[0] = 1.0; out[i] = w[0] }
    RUBY
    refute_equal(first.c_source, second.c_source)
  end

end
