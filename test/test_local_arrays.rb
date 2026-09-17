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

  def test_a_contraction_says_why_it_takes_none
    x = CArray.double(4, 4).seq!
    y = CArray.double(4, 4).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, k, j|
        w = CArray.double(2)
        x[i, k] * y[k, j]
      }
    end
    assert_match(/a contraction's body is one expression/, error.message)
  end

  # ---------- the cache ----------

  # ---------- the other entry points over cells ----------

  # `jit_each`, `jit_map` and `jit_stencil` give a block no index, which is
  # what a row of captured workspace needed one for.  So these are the
  # spellings a local array was wanted in most: a window has no index to pick
  # a row by at all.

  def test_a_local_array_in_a_jit_each_block
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    CArray.jit_each {
      w = CArray.double(3)
      w[0] = a
      w[1] = a * 2.0
      w[2] = a * 3.0
      out = w[0] + w[1] + w[2]
    }
    reference = (0...6).map { |k| a[k] + a[k] * 2.0 + a[k] * 3.0 }
    assert_arrays_bits_equal(CArray.double(6) { reference }, out)
  end

  def test_a_local_array_in_a_jit_map_block
    a = CArray.double(6).seq!(1.0)
    out = CArray.jit_map {
      w = CArray.double(3)
      w[0] = a
      w[1] = a * 2.0
      w[2] = a * 3.0
      w[0] + w[1] + w[2]
    }
    reference = (0...6).map { |k| a[k] + a[k] * 2.0 + a[k] * 3.0 }
    assert_arrays_bits_equal(CArray.double(6) { reference }, out)
  end

  def test_a_local_array_in_a_jit_stencil_block
    image = CArray.double(6, 6).seq!
    out = CArray.jit_stencil(image, border: :clamp) { |a|
      w = CArray.double(3)
      w[0] = a[-1, 0]
      w[1] = a[0, 0]
      w[2] = a[1, 0]
      w[0] + w[1] + w[2]
    }
    reference = CArray.double(6, 6)
    6.times { |row| 6.times { |column|
      above = image[[row - 1, 0].max, column]
      below = image[[row + 1, 5].min, column]
      reference[row, column] = above + image[row, column] + below
    } }
    assert_equal(reference.to_a, out.to_a)
  end

  # Example 1 of the proposal: the 3x3 median filter, which is why the window
  # spelling wanted one.  Written both ways -- the insertion sort spelled out,
  # and `sort(w)` -- and both held to the same Ruby loop.
  def median_reference (image)
    rows, columns = image.dim
    reference = CArray.double(rows, columns)
    rows.times { |row| columns.times { |column|
      window = (-1..1).flat_map { |dr| (-1..1).map { |dc|
        image[[[row + dr, 0].max, rows - 1].min,
              [[column + dc, 0].max, columns - 1].min]
      } }
      reference[row, column] = window.sort[4]
    } }
    reference
  end

  def test_the_median_filter_with_the_insertion_sort_written_out
    image = CArray.double(7, 7).seq!
    image.map! { |value| (value * 13) % 29 }
    out = CArray.jit_stencil(image, border: :clamp) { |a|
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
    assert_equal(median_reference(image).to_a, out.to_a)
  end

  def test_the_median_filter_with_sort
    image = CArray.double(7, 7).seq!
    image.map! { |value| (value * 13) % 29 }
    out = CArray.jit_stencil(image, border: :clamp) { |a|
      w = CArray.double(9)
      w[0] = a[-1, -1]; w[1] = a[-1, 0]; w[2] = a[-1, 1]
      w[3] = a[0, -1];  w[4] = a[0, 0];  w[5] = a[0, 1]
      w[6] = a[1, -1];  w[7] = a[1, 0];  w[8] = a[1, 1]
      sort(w)
      w[4]
    }
    assert_equal(median_reference(image).to_a, out.to_a)
  end

  # Example 3: the median of five ensemble members, per cell.  `jit_map` has
  # no index either, and the five members are five operands.
  def ensemble_reference (members)
    count = members.first.elements
    CArray.double(count) { (0...count).map { |k| members.map { |m| m[k] }.sort[2] } }
  end

  def test_the_ensemble_median_with_the_insertion_sort_written_out
    m1 = CArray.double(8).seq!(3.0, 7.0).map! { |v| v % 29 }
    m2 = CArray.double(8).seq!(11.0, 5.0).map! { |v| v % 29 }
    m3 = CArray.double(8).seq!(2.0, 13.0).map! { |v| v % 29 }
    m4 = CArray.double(8).seq!(23.0, 3.0).map! { |v| v % 29 }
    m5 = CArray.double(8).seq!(17.0, 19.0).map! { |v| v % 29 }
    out = CArray.jit_map {
      w = CArray.double(5)
      w[0] = m1; w[1] = m2; w[2] = m3; w[3] = m4; w[4] = m5
      (1...5).each { |k|
        key = w[k]
        j = k - 1
        while j >= 0 && w[j] > key
          w[j + 1] = w[j]
          j -= 1
        end
        w[j + 1] = key
      }
      w[2]
    }
    assert_arrays_bits_equal(ensemble_reference([m1, m2, m3, m4, m5]), out)
  end

  def test_the_ensemble_median_with_sort
    m1 = CArray.double(8).seq!(3.0, 7.0).map! { |v| v % 29 }
    m2 = CArray.double(8).seq!(11.0, 5.0).map! { |v| v % 29 }
    m3 = CArray.double(8).seq!(2.0, 13.0).map! { |v| v % 29 }
    m4 = CArray.double(8).seq!(23.0, 3.0).map! { |v| v % 29 }
    m5 = CArray.double(8).seq!(17.0, 19.0).map! { |v| v % 29 }
    out = CArray.jit_map {
      w = CArray.double(5)
      w[0] = m1; w[1] = m2; w[2] = m3; w[3] = m4; w[4] = m5
      sort(w)
      w[2]
    }
    assert_arrays_bits_equal(ensemble_reference([m1, m2, m3, m4, m5]), out)
  end

  # ---------- the two paths the bounds check has to survive ----------

  # `Kernel#verify` is not on either of them: a swept pass never calls it, and
  # a stencil with a border calls it with `reach: false`.  A local array's
  # bounds were deliberately put somewhere else -- settled as the block is
  # read, or checked at the access -- so both paths keep them.  These say so.

  def test_the_swept_path_is_the_one_under_test
    a = CArray.double(64).seq!(1.0)
    out = CArray.double(64)
    assert(CArray::JIT::Sweep.available?,
           "this CArray has no ca_call_cslab, so there is no swept path here")
    assert(CArray::JIT.send(:sweepable_pass?, { :a => a, :out => out },
                            [64], false),
           "these operands should take the swept path")
    kernel = CArray.jit_each { w = CArray.double(2); w[0] = a; out = w[0] }
    assert_equal(1, kernel.rank, "a swept pass is compiled flat")
  end

  def test_a_read_off_the_end_on_the_swept_path_raises
    a = CArray.int64(64).seq!(70)
    out = CArray.double(64)
    assert(CArray::JIT.send(:sweepable_pass?, { :a => a, :out => out },
                            [64], false))
    assert_raises(IndexError) do
      CArray.jit_each {
        w = CArray.double(4)
        out = w[a]
      }
    end
  end

  def test_a_write_off_the_end_on_the_swept_path_writes_nothing
    positions = CArray.int64(64).seq!(70)
    seen = CArray.double(64)
    assert(CArray::JIT.send(:sweepable_pass?,
                            { :positions => positions, :seen => seen },
                            [64], false))
    assert_raises(IndexError) do
      CArray.jit_each {
        w = CArray.double(4)
        w[0] = 11.0
        w[positions] = 99.0
        seen = w[0]
      }
    end
  end

  def test_a_read_off_the_end_on_a_bordered_path_raises
    image = CArray.double(8, 8).seq!
    assert_raises(IndexError) do
      CArray.jit_stencil(image, border: :clamp) { |a|
        w = CArray.double(4)
        j = 9
        w[j]
      }
    end
  end

  def test_a_write_off_the_end_on_a_bordered_path_writes_nothing
    image = CArray.double(8, 8).seq!
    assert_raises(IndexError) do
      CArray.jit_stencil(image, border: :clamp) { |a|
        w = CArray.double(4)
        w[0] = 11.0
        j = 9
        w[j] = 99.0
        w[0]
      }
    end
  end

  # (a) is settled as the block is read, so it does not depend on which
  # driver would have run.
  def test_the_reach_is_refused_in_a_stencil_too
    image = CArray.double(8, 8).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(image, border: :clamp) { |a|
        t = CArray.double(4)
        (0...4).each { |k| t[k + 1] = a[0, 0] }
        t[0]
      }
    end
    assert_match(/`t\[k \+ 1\]` reaches cell 4/, error.message)
  end

  def test_the_reach_is_refused_in_a_jit_each_block_too
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each {
        t = CArray.double(4)
        (0...4).each { |k| t[k + 1] = a }
        out = t[0]
      }
    end
    assert_match(/reaches cell 4/, error.message)
  end

  # ---------- cleared at every cell ----------

  def test_the_zeroed_family_starts_from_zero_at_every_cell
    a = CArray.int64(6).seq!(1)
    out = CArray.int64(6)
    CArray.jit_each {
      counts = CArray.int64(3)
      counts[0] += a
      out = counts[0]
    }
    assert_equal(a.to_a, out.to_a,
                 "each cell has to start from a cleared array")
  end

  def test_the_zeroed_family_starts_from_zero_at_every_cell_of_a_stencil
    image = CArray.int64(5, 5)
    image.seq!(1)
    out = CArray.jit_stencil(image, border: :clamp) { |a|
      counts = CArray.int64(3)
      counts[0] += a[0, 0]
      counts[0]
    }
    assert_equal(image.to_a, out.to_a)
  end

  # ---------- the name the block makes, against a name outside ----------

  def test_an_outer_array_of_the_same_name_is_refused_before_the_broadcast
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    w = CArray.double(9)          # a different shape: the broadcast would fail
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { w = CArray.double(9); out = a * 1.0 }
    end
    assert_match(/`w` is made in this block/, error.message)
    assert_match(/closes over an array named `w`/, error.message)
    assert_match(/Rename one/, error.message)
    refute_equal(9, w.elements + 0 - 9, "the outer array is untouched")
  end

  def test_an_outer_array_of_the_same_name_is_refused_when_the_shapes_agree
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    w = CArray.double(6)          # the same shape: it would slip in unnoticed
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { w = CArray.double(6); out = a * 1.0 }
    end
    assert_match(/`w` is made in this block/, error.message)
    assert_equal([0.0] * 6, w.to_a, "the outer array is untouched")
  end

  # `jit_map` reaches the probe before it reaches the kernel, so the check has
  # to be in front of that too.
  def test_an_outer_array_of_the_same_name_is_refused_in_a_map
    a = CArray.double(6).seq!(1.0)
    w = CArray.double(9)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_map { w = CArray.double(9); a * 1.0 }
    end
    assert_match(/`w` is made in this block/, error.message)
  end

  def test_the_probe_reads_a_body_that_makes_an_array
    # The probe types the block before there is a result array to collect
    # into, so it has to be able to read the constructor at all.
    a = CArray.float32(6).seq!(1.0)
    out = CArray.jit_map {
      w = CArray.float32(2)
      w[0] = a
      w[1] = a * 2.0
      w[0] + w[1]
    }
    assert_equal("float32", out.data_type_name,
                 "the probe should have typed this from the local array")
  end

  def test_a_name_the_block_makes_is_not_an_operand
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    kernel = CArray.jit_each { w = CArray.double(2); w[0] = a; out = w[0] }
    refute_includes(kernel.arrays, :w,
                    "a local array is not one of the kernel's operands")
  end

  # ---------- masks ----------

  def test_a_masked_operand_and_a_local_array_do_not_meet_in_a_jit_each_block
    a = CArray.double(6).seq!(1.0)
    a[2] = UNDEF
    out = CArray.double(6)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { w = CArray.double(2); w[0] = a; out = w[0] }
    end
    assert_match(/`w` is a local array/, error.message)
    assert_match(/carries a mask/, error.message)
    assert_match(/strip_mask/, error.message)
  end

  def test_a_block_that_asks_about_undef_and_a_local_array_do_not_meet_in_a_map
    a = CArray.double(6).seq!(1.0)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_map { w = CArray.double(2); w[0] = (a == UNDEF ? 0.0 : a); w[0] }
    end
    assert_match(/`w` is a local array/, error.message)
    assert_match(/asks about\s+UNDEF/, error.message)
    refute_match(/strip_mask/, error.message)
  end

  def test_a_masked_operand_and_a_local_array_do_not_meet_in_a_stencil
    image = CArray.double(6, 6).seq!
    image[2, 2] = UNDEF
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(image, border: :clamp) { |a|
        w = CArray.double(2)
        w[0] = a[0, 0]
        w[0]
      }
    end
    assert_match(/`w` is a local array/, error.message)
    assert_match(/carries a mask/, error.message)
  end

  # `border: :mask` is not a masked kernel: the frame is marked before the
  # loop runs and the loop never reaches it, so what the kernel carries is
  # what the operands carry.  A local array is therefore fine under it.
  def test_a_frame_border_is_not_a_masked_kernel
    field = CArray.double(6, 6).seq!
    out = CArray.jit_stencil(field, border: :mask) { |a|
      w = CArray.double(9)
      w[0] = a[-1, -1]; w[1] = a[-1, 0]; w[2] = a[-1, 1]
      w[3] = a[0, -1];  w[4] = a[0, 0];  w[5] = a[0, 1]
      w[6] = a[1, -1];  w[7] = a[1, 0];  w[8] = a[1, 1]
      max(w) - min(w)
    }
    assert(out.has_mask?, "`border: :mask` marks the frame")
    assert_equal(UNDEF, out[0, 0], "the frame is marked, not computed")
    # The interior is the spread of the nine cells around it.
    (1..4).each { |row| (1..4).each { |column|
      window = (-1..1).flat_map { |dr| (-1..1).map { |dc| field[row + dr, column + dc] } }
      assert_equal(window.max - window.min, out[row, column], "cell #{row},#{column}")
    } }
  end

  def test_every_border_takes_a_local_array
    field = CArray.double(6, 6).seq!
    [:mask, :skip, :zero, :clamp, :wrap].each do |border|
      out = CArray.jit_stencil(field, border: border) { |a|
        w = CArray.double(2)
        w[0] = a[0, 0]
        w[1] = a[0, 0] * 2.0
        w[0] + w[1]
      }
      assert_equal(field[3, 3] * 3.0, out[3, 3], "border: #{border.inspect}")
    end
  end

  # ---------- handed to a C function ----------

  # A local array decays to the pointer a C function wants, as it does in C.
  # What the declaration says about it -- the element type, and the length
  # where the declarator carries one -- is matched as the block is read,
  # because both are written in the block: the shape is a literal and the type
  # is the constructor.  A captured array is matched at the call instead, its
  # type and length not being knowable until there is an array.
  #
  # The match has to happen: a compiled function does not check a subscript on
  # a pointer parameter (unchecked by design, the caller's business as in C),
  # and a local array is on the stack, so a declaration that reads more cells
  # than the array holds would walk over the frame.

  DOT4 = CArray.jit_function(
    "double dot4(const double x[4], const double y[4])") { |x, y|
    x[0] * y[0] + x[1] * y[1] + x[2] * y[2] + x[3] * y[3]
  }

  # Example 6 of the proposal.
  def test_a_local_array_is_handed_to_a_compiled_function
    n = 12
    signal = CArray.double(n).seq!(1.0, 0.5)
    weights = CArray.double(4)
    weights[0] = 0.1; weights[1] = 0.2; weights[2] = 0.3; weights[3] = 0.4
    smoothed = CArray.double(n)
    CArray.jit_for(0...(n - 3)) { |i|
      w = CArray.double(4)
      w[0] = signal[i]; w[1] = signal[i + 1]
      w[2] = signal[i + 2]; w[3] = signal[i + 3]
      smoothed[i] = DOT4.call(w, weights)
    }
    reference = CArray.double(n)
    (0...(n - 3)).each { |i|
      reference[i] = (0...4).inject(0.0) { |total, k|
        total + signal[i + k] * weights[k]
      }
    }
    assert_arrays_bits_equal(reference, smoothed)
  end

  def test_a_local_array_reaches_a_function_from_every_entry_point
    a = CArray.double(6).seq!(1.0)
    ones = CArray.double(4)
    (0...4).each { |k| ones[k] = 1.0 }

    out = CArray.double(6)
    CArray.jit_for(6) { |i|
      w = CArray.double(4)
      (0...4).each { |k| w[k] = a[i] }
      out[i] = DOT4.call(w, ones)
    }
    assert_equal((0...6).map { |k| a[k] * 4.0 }, out.to_a, "jit_for")

    # Both arguments are local arrays in the spellings below.  A *captured*
    # array handed over by address joins the line-up and is broadcast against
    # the operands, so one of a different length clashes there -- which is
    # so with or without a local array, and is not this release's business.
    each = CArray.double(6)
    CArray.jit_each {
      w = CArray.double(4)
      u = CArray.double(4)
      w[0] = a; w[1] = a; w[2] = a; w[3] = a
      u[0] = 1.0; u[1] = 1.0; u[2] = 1.0; u[3] = 1.0
      each = DOT4.call(w, u)
    }
    assert_equal((0...6).map { |k| a[k] * 4.0 }, each.to_a, "jit_each")

    mapped = CArray.jit_map {
      w = CArray.double(4)
      u = CArray.double(4)
      w[0] = a; w[1] = a; w[2] = a; w[3] = a
      u[0] = 1.0; u[1] = 1.0; u[2] = 1.0; u[3] = 1.0
      DOT4.call(w, u)
    }
    assert_equal((0...6).map { |k| a[k] * 4.0 }, mapped.to_a, "jit_map")

    image = CArray.double(5, 5).seq!
    stencilled = CArray.jit_stencil(image, border: :clamp) { |win|
      w = CArray.double(4)
      u = CArray.double(4)
      w[0] = win[0, 0]; w[1] = win[0, 0]
      w[2] = win[0, 0]; w[3] = win[0, 0]
      u[0] = 1.0; u[1] = 1.0; u[2] = 1.0; u[3] = 1.0
      DOT4.call(w, u)
    }
    assert_equal(image[2, 2] * 4.0, stencilled[2, 2], "jit_stencil")
  end

  # The callee writes through a parameter that is not const, and the line
  # after the call reads what it wrote.
  def test_a_function_writes_into_a_local_array_it_was_handed
    fill = CArray.jit_function("double fill3(double x[3])") { |x|
      x[0] = 10.0
      x[1] = 20.0
      x[2] = 30.0
      x[0] + x[1] + x[2]
    }
    total = CArray.double(3)
    first = CArray.double(3)
    last = CArray.double(3)
    CArray.jit_for(3) { |i|
      w = CArray.double(3)
      total[i] = fill.call(w)
      first[i] = w[0]
      last[i] = w[2]
    }
    assert_equal([60.0] * 3, total.to_a, "what the function returned")
    assert_equal([10.0] * 3, first.to_a, "what it wrote, read back after")
    assert_equal([30.0] * 3, last.to_a)
  end

  # And what it wrote does not survive into the next cell: the clearing runs
  # again, as it does for any other pass.
  def test_what_a_function_wrote_does_not_reach_the_next_cell
    bump = CArray.jit_function("double bump2(double x[2])") { |x|
      x[0] = x[0] + 1.0
      x[0]
    }
    seen = CArray.double(4)
    CArray.jit_for(4) { |i| w = CArray.double(2); seen[i] = bump.call(w) }
    assert_equal([1.0] * 4, seen.to_a,
                 "each cell starts from a cleared array, so each sees 1.0")
  end

  def test_the_same_local_array_may_be_handed_to_two_arguments
    # The declarations carry no `restrict`, so this is well-formed C.
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      w = CArray.double(4)
      (0...4).each { |k| w[k] = 2.0 }
      out[i] = DOT4.call(w, w)
    }
    assert_equal([16.0] * 3, out.to_a)
  end

  def test_a_function_declaration_carries_no_restrict
    refute_match(/restrict/, DOT4.c_source.lines.grep(/carray_jit_dot4/).join,
                 "a declaration with `restrict` would make `f.call(w, w)` "                  "undefined, and that call is taken")
  end

  # ---------- what the declaration is held to ----------

  def test_an_element_type_that_does_not_match_is_refused
    error = assert_raises(CArray::JIT::Unsupported) do
      out = CArray.double(1)
      CArray.jit_for(1) { |i|
        w = CArray.float32(4)
        (0...4).each { |k| w[k] = 1.0 }
        out[i] = DOT4.call(w, w)
      }
    end
    assert_match(/`w` is float32/, error.message)
    assert_match(/float64 array/, error.message)
    assert_match(/CArray\.new\(:float64, \[4\]\)/, error.message,
                 "the message should say what to write instead")
  end

  def test_an_array_shorter_than_the_declaration_is_refused
    error = assert_raises(CArray::JIT::Unsupported) do
      out = CArray.double(3)
      CArray.jit_for(3) { |i|
        w = CArray.double(3)
        (0...3).each { |k| w[k] = 1.0 }
        out[i] = DOT4.call(w, w)
      }
    end
    assert_match(/`w`/, error.message)
    assert_match(/4/, error.message)
    assert_match(/3/, error.message)
  end

  # Refused as the block is read, so no kernel is ever built for it.
  def test_a_short_array_is_refused_before_a_kernel_is_built
    CArray::JIT.clear_registry
    out = CArray.double(1)
    assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i|
        w = CArray.double(2)
        w[0] = 1.0; w[1] = 2.0
        out[i] = DOT4.call(w, w)
      }
    end
    assert_empty(CArray::JIT.registry,
                 "the refusal comes from reading the block, so nothing " \
                 "should have been compiled for it")
  end

  def test_an_array_longer_than_the_declaration_is_taken
    # The callee reads four of the six, which is what a captured array of six
    # is allowed to do as well.
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      w = CArray.double(6)
      (0...6).each { |k| w[k] = 2.0 }
      out[i] = DOT4.call(w, w)
    }
    assert_equal([16.0] * 3, out.to_a)
  end

  def test_a_declaration_with_no_length_takes_any_local_array
    star = CArray.jit_function("double first(const double *x)") { |x| x[0] }
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      w = CArray.double(2)
      w[0] = 7.0
      out[i] = star.call(w)
    }
    assert_equal([7.0] * 3, out.to_a)
  end

  def test_a_borrowed_function_takes_a_local_array
    # `hypot` takes no pointer, so the borrowed function here is one that
    # does: memcpy's cousin `fabs` will not do.  `cblas_ddot` is not on every
    # machine, so the borrowed declaration is `qsort`-free and uses libm's
    # `frexp`, which takes an `int *`.
    frexp = CArray.jit_extern("double frexp(double value, int *exponent)")
    out = CArray.double(1)
    got = CArray.int32(1)
    CArray.jit_for(1) { |i|
      e = CArray.new(:int32, [1])
      out[i] = frexp.call(8.0, e)
      got[i] = e[0]
    }
    assert_equal(0.5, out[0], "8.0 is 0.5 * 2**4")
    assert_equal(4, got[0], "and the exponent the borrowed function wrote")
  end

  def test_two_axes_are_still_refused_as_an_argument
    error = assert_raises(CArray::JIT::Unsupported) do
      out = CArray.double(1)
      CArray.jit_for(1) { |i|
        m = CArray.double(2, 2)
        out[i] = DOT4.call(m, m)
      }
    end
    assert_match(/one axis in this release/, error.message)
  end

  # ---------- inside a compiled function's body ----------

  # A function body is the one place with no captures at all, so a workspace
  # it needs has nowhere else to come from: an extra parameter is the only
  # other answer, and a signature settled outside -- a callback's -- has no
  # room for one.
  #
  # The body is built once and reaches two places: the standalone object
  # `CFunction#call` runs, and the definition a kernel pastes into its own
  # file.  Every test here checks both.

  # Example 5 of the proposal: Neville's interpolation, which walks a
  # workspace of its own length and overwrites it as it goes.
  NEVILLE = CArray.jit_function(
    "double neville(double x, const double xs[4], const double ys[4])"
  ) { |x, xs, ys|
    t = CArray.double(4)
    4.times { |k| t[k] = ys[k] }
    (1...4).each { |m|
      (0...3).each { |k|
        if k < 4 - m
          t[k] = ((x - xs[k + m]) * t[k] + (xs[k] - x) * t[k + 1]) /
                 (xs[k] - xs[k + m])
        end
      }
    }
    t[0]
  }

  def neville_reference (x, xs, ys)
    t = ys.dup
    (1...4).each { |m|
      (0...3).each { |k|
        if k < 4 - m
          t[k] = ((x - xs[k + m]) * t[k] + (xs[k] - x) * t[k + 1]) /
                 (xs[k] - xs[k + m])
        end
      }
    }
    t[0]
  end

  def test_neville_interpolates_as_the_same_loop_in_ruby
    xs = CArray.double(4)
    ys = CArray.double(4)
    [0.0, 1.0, 2.0, 3.0].each_with_index { |v, k| xs[k] = v }
    [1.0, 2.5, 0.5, 4.0].each_with_index { |v, k| ys[k] = v }
    plain_xs = (0...4).map { |k| xs[k] }
    plain_ys = (0...4).map { |k| ys[k] }
    [0.5, 1.5, 2.25].each do |x|
      assert_bits_equal(neville_reference(x, plain_xs, plain_ys),
                        NEVILLE.call(x, xs, ys), "at x = #{x}")
    end
  end

  def test_neville_interpolates_the_same_way_from_a_kernel
    xs = CArray.double(4)
    ys = CArray.double(4)
    [0.0, 1.0, 2.0, 3.0].each_with_index { |v, k| xs[k] = v }
    [1.0, 2.5, 0.5, 4.0].each_with_index { |v, k| ys[k] = v }
    query = CArray.double(5).seq!(0.25, 0.5)
    out = CArray.double(5)
    CArray.jit_for(5) { |i| out[i] = NEVILLE.call(query[i], xs, ys) }
    plain_xs = (0...4).map { |k| xs[k] }
    plain_ys = (0...4).map { |k| ys[k] }
    reference = CArray.double(5) {
      (0...5).map { |i| neville_reference(query[i], plain_xs, plain_ys) }
    }
    assert_arrays_bits_equal(reference, out)
  end

  def test_the_body_declares_its_array_at_its_own_head
    assert_match(/^\{\n  double t\[4\];\n/, NEVILLE.definition,
                 "the pasted definition carries the declaration")
    assert_match(/double t\[4\];/, NEVILLE.c_source,
                 "and so does the standalone object")
  end

  # ---------- a body handing an array to another function ----------

  def test_a_body_hands_a_local_array_to_another_function
    total = CArray.jit_function("double total3(const double x[3])") { |x|
      x[0] + x[1] + x[2]
    }
    outer = CArray.jit_function("double outer(double s)") { |s|
      w = CArray.double(3)
      w[0] = s; w[1] = s * 2.0; w[2] = s * 3.0
      total.call(w)
    }
    assert_equal(12.0, outer.call(2.0), "2 + 4 + 6")
    out = CArray.double(3)
    CArray.jit_for(3) { |i| out[i] = outer.call(i * 1.0) }
    assert_equal([0.0, 6.0, 12.0], out.to_a, "and the same from a kernel")
  end

  def test_a_callee_writes_into_a_body_s_local_array
    fill = CArray.jit_function("void fill2(double x[2])") { |x|
      x[0] = 4.0
      x[1] = 6.0
    }
    outer = CArray.jit_function("double outer2(double s)") { |s|
      w = CArray.double(2)
      fill.call(w)
      s + w[0] + w[1]
    }
    assert_equal(11.0, outer.call(1.0), "1 + 4 + 6")
    out = CArray.double(2)
    CArray.jit_for(2) { |i| out[i] = outer.call(i * 1.0) }
    assert_equal([10.0, 11.0], out.to_a)
  end

  def test_a_body_may_hand_on_its_own_pointer_parameter
    # Unchanged behaviour: a pointer the body was given is already an address
    # and is passed along as C passes one.
    total = CArray.jit_function("double total3b(const double x[3])") { |x|
      x[0] + x[1] + x[2]
    }
    relay = CArray.jit_function("double relay(const double x[3])") { |x|
      total.call(x)
    }
    given = CArray.double(3)
    given[0] = 1.0; given[1] = 2.0; given[2] = 4.0
    assert_equal(7.0, relay.call(given))
  end

  def test_a_declaration_a_body_cannot_satisfy_is_refused_as_it_is_read
    wants4 = CArray.jit_function("double wants4(const double x[4])") { |x| x[0] }
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double tooshort(double s)") { |s|
        w = CArray.double(2)
        w[0] = s
        wants4.call(w)
      }
    end
    assert_match(/reads 4 cells/, error.message)
    assert_match(/has 2/, error.message)
  end

  def test_an_element_type_a_body_cannot_satisfy_is_refused
    wants4 = CArray.jit_function("double wants4b(const double x[4])") { |x| x[0] }
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double wrongtype(double s)") { |s|
        w = CArray.float32(4)
        (0...4).each { |k| w[k] = s }
        wants4.call(w)
      }
    end
    assert_match(/float64 array/, error.message)
    assert_match(/`w` is float32/, error.message)
  end

  # ---------- recursion ----------

  # Each activation declares its own array, as C does for an automatic.
  def test_a_recursive_body_gets_one_array_per_call
    down = CArray.jit_function("double down(double n)") { |n|
      w = CArray.double(2)
      w[0] = n
      w[1] = n <= 0.0 ? 0.0 : down.call(n - 1.0)
      w[0] + w[1]
    }
    assert_equal(6.0, down.call(3.0), "3 + 2 + 1 + 0, each level keeping its n")
    out = CArray.double(4)
    CArray.jit_for(4) { |i| out[i] = down.call(i * 1.0) }
    assert_equal([0.0, 1.0, 3.0, 6.0], out.to_a)
  end

  # ---------- the bounds checks, in a body ----------

  def test_a_read_off_the_end_in_a_body_raises
    reader = CArray.jit_function("double reader(double j)") { |j|
      w = CArray.double(4)
      k = j.to_i
      w[k]
    }
    assert_raises(IndexError) { reader.call(9.0) }
  end

  def test_a_write_off_the_end_in_a_body_writes_nothing
    writer = CArray.jit_function("double writer(double j)") { |j|
      w = CArray.double(4)
      w[0] = 11.0
      k = j.to_i
      w[k] = 99.0
      w[0]
    }
    # An inside position writes where it says, and cell zero keeps its value.
    assert_equal(11.0, writer.call(1.0))
    # Cell zero is the position a refused write would have landed on, and it
    # is not written: the call raises instead.
    assert_raises(IndexError) { writer.call(9.0) }
  end

  def test_the_reach_is_refused_in_a_body_as_the_block_is_read
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double reach(double s)") { |s|
        t = CArray.double(4)
        (0...4).each { |k| t[k + 1] = s }
        t[0]
      }
    end
    assert_match(/reaches cell 4/, error.message)
  end

  def test_a_while_in_a_body_that_reads_off_the_end_stops
    output = run_isolated(<<~RUBY)
      f = CArray.jit_function("double spin(double start)") { |start|
        w = CArray.double(4)
        (0...4).each { |k| w[k] = 1.0 }
        j = start.to_i
        s = 1.0
        while s != 0.0
          s = w[j]
          j += 1
        end
        s
      }
      begin
        f.call(0.0)
        puts "no error"
      rescue IndexError
        puts "IndexError"
      end
    RUBY
    assert_equal("IndexError\n", output)
  end

  # ---------- the limit is per function ----------

  # Five arrays of 4 KiB each is 20 KiB, past the 16 KiB a single function is
  # held to.  Written out rather than built by eval: a block made in eval has
  # no source to read back.
  def test_one_body_is_held_to_the_total
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double big(double s)") { |s|
        a = CArray.double(512)
        b = CArray.double(512)
        c = CArray.double(512)
        d = CArray.double(512)
        e = CArray.double(512)
        a[0] = s; b[0] = s; c[0] = s; d[0] = s; e[0] = s
        a[0] + b[0] + c[0] + d[0] + e[0]
      }
    end
    assert_match(/#{CArray::JIT::Analyzer::LOCAL_ARRAY_TOTAL_BYTE_LIMIT}/,
                 error.message)
    assert_match(/come to \d+ bytes of stack/, error.message)
  end

  # The chain is not counted: each function answers for its own frame, which
  # is the same bargain a deep recursion already takes.
  def test_a_chain_of_functions_each_within_the_limit_is_taken
    inner = CArray.jit_function("double inner(double s)") { |s|
      u = CArray.double(512)
      v = CArray.double(512)
      u[0] = s; v[0] = s
      u[0] + v[0]
    }
    middle = CArray.jit_function("double middle(double s)") { |s|
      u = CArray.double(512)
      v = CArray.double(512)
      u[0] = inner.call(s); v[0] = 1.0
      u[0] + v[0]
    }
    outer = CArray.jit_function("double outer3(double s)") { |s|
      u = CArray.double(512)
      v = CArray.double(512)
      u[0] = middle.call(s); v[0] = 1.0
      u[0] + v[0]
    }
    assert_equal(8.0, outer.call(3.0), "3 + 3, then + 1, then + 1")
    per_function = 512 * 8 * 2
    assert_operator(per_function, :<=,
                    CArray::JIT::Analyzer::LOCAL_ARRAY_TOTAL_BYTE_LIMIT,
                    "each function is inside the limit")
    assert_operator(per_function * 3, :>,
                    CArray::JIT::Analyzer::LOCAL_ARRAY_TOTAL_BYTE_LIMIT,
                    "and the three frames together are past it, which is " \
                    "not counted: each function answers for its own")
  end

  # ---------- names, across the paste ----------

  def test_a_body_and_the_kernel_pasting_it_may_use_one_name
    doubler = CArray.jit_function("double doubler(double x)") { |x|
      w = CArray.double(2)
      w[0] = x * 2.0
      w[0]
    }
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      w = CArray.double(3)
      w[0] = i * 1.0
      out[i] = doubler.call(w[0]) + w[0]
    }
    assert_equal([0.0, 3.0, 6.0], out.to_a,
                 "each `w` is its own function's automatic")
  end

  def test_a_body_may_name_its_array_after_a_kernel_parameter
    named = CArray.jit_function("double named(double x)") { |x|
      error = CArray.double(2)
      error[0] = x * 3.0
      error[0]
    }
    out = CArray.double(2)
    CArray.jit_for(2) { |i| out[i] = named.call(i * 1.0) }
    assert_equal([0.0, 3.0], out.to_a)
  end

  # ---------- a contraction still takes none ----------

  def test_a_contraction_still_takes_no_local_array
    x = CArray.double(4, 4).seq!
    y = CArray.double(4, 4).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, k, j| w = CArray.double(2); x[i, k] * y[k, j] }
    end
    assert_match(/a contraction's body is one expression/, error.message)
  end

  # ---------- a name the window already had ----------

  # Giving one of the block's own arrays the window's name rebinds it, here as
  # in Ruby, so the window has no name left afterwards.  What it computes is
  # therefore right; what was wrong was the account of it, the axis count
  # alone saying nothing about where the window went.
  def test_an_array_may_take_the_windows_name_and_rebinds_it
    image = CArray.double(4, 4).seq!
    out = CArray.jit_stencil(image, border: :clamp) { |a|
      a = CArray.double(9)
      a[0] = 7.0
      a[0]
    }
    assert_equal([[7.0] * 4] * 4, out.to_a,
                 "Ruby rebinds the parameter here, and so does this")
  end

  def test_the_window_may_be_read_before_its_name_is_taken
    image = CArray.double(4, 4).seq!
    out = CArray.jit_stencil(image, border: :clamp) { |a|
      v = a[0, 0]
      a = CArray.double(9)
      a[0] = v * 2.0
      a[0]
    }
    reference = CArray.double(4, 4) { |r, c| image[r, c] * 2.0 }
    assert_equal(reference.to_a, out.to_a)
  end

  def test_reaching_the_window_after_its_name_is_taken_says_where_it_went
    image = CArray.double(4, 4).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(image, border: :clamp) { |a|
        a = CArray.double(9)
        a[0] = 1.0
        a[-1, 0] + a[1, 0]
      }
    end
    assert_match(/`a` is the window this block was given/, error.message)
    assert_match(/rebinds it, here as in Ruby/, error.message)
    assert_match(/`a\[0, 0\]` is the window's spelling and wants 2 offsets/,
                 error.message)
    assert_match(/give the array a name of its own/, error.message)
  end

  # ---------- what a map block may end with ----------

  def test_a_map_block_may_not_end_by_making_an_array
    a = CArray.double(6).seq!(1.0)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_map { s = a * 1.0; v = CArray.double(2) }
    end
    assert_match(/ends by making `v`/, error.message)
    assert_match(/no cell for one to go in/, error.message)
  end

  def test_a_map_block_may_not_end_with_the_array_read_bare
    a = CArray.double(6).seq!(1.0)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_map { v = CArray.double(2); v[0] = a; v }
    end
    assert_match(/`v` is a local array; index it/, error.message)
  end

  # ---------- still refused, as in the first release ----------

  def test_two_axes_are_still_refused_in_the_new_entry_points
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { m = CArray.double(3, 4); out = m[0] }
    end
    assert_match(/one axis in this release/, error.message)
  end

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
