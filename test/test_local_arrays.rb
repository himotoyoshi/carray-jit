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

  # A shape over the integers the block captured is taken, in both
  # spellings: the length is worked out at the kernel's entry and the array
  # is allocated there (see the heap section below).
  def test_the_shape_may_be_written_over_a_captured_integer
    arrays = { :out => "float64" }
    %w[CArray.double(n) CArray.new(:float64,\ [n])].each do |spelling|
      kernel = compile_kernel(<<~RUBY, arrays: arrays, scalars: { :n => 4 })
        proc { |i|
          w = #{spelling.tr("\\", " ").squeeze(" ")}
          out[i] = w[0]
        }
      RUBY
      assert_match(/double \*w = NULL;/, kernel.c_source, spelling)
      assert_match(/w__extent0 = n;/, kernel.c_source, spelling)
    end
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

  # A masked operand and a local array meet: the array carries a shadow byte
  # a cell, so what was read as missing is written back as missing.
  def test_a_masked_operand_and_a_local_array_meet
    a = CArray.double(4).seq!(1.0)
    a[2] = UNDEF
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      w = CArray.double(2)
      w[0] = a[i]
      out[i] = w[0]
    }
    assert_equal([false, false, true, false], out.is_masked.to_a)
    [0, 1, 3].each { |k| assert_bits_equal(a[k], out[k], "cell #{k}") }
  end

  def test_a_block_that_asks_about_undef_and_a_local_array_meet
    a = CArray.double(4).seq!(1.0)
    a[2] = UNDEF
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      w = CArray.double(2)
      w[0] = a[i] == UNDEF ? 0.0 : a[i]
      out[i] = w[0]
    }
    assert_equal([1.0, 2.0, 0.0, 4.0], out.to_a)
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

  # In a compiled function's body there is no mask at all -- a signature
  # carries numbers and pointers -- so a local array there has no shadow to
  # mark or to ask about.
  def test_a_local_array_in_a_function_body_has_no_mask
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double marks(double x)") { |x|
        w = CArray.double(4)
        w[0] = UNDEF
        w[0]
      }
    end
    assert_match(/nothing there carries masks/, error.message)
    asked = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double asks(double x)") { |x|
        w = CArray.double(4)
        w[0] = x
        w[0] == UNDEF ? 1.0 : 2.0
      }
    end
    assert_match(/no shadow beside these cells/, asked.message)
  end

  # ---------- the room it takes ----------

  # Past the limit the array is allocated at the kernel's entry instead of
  # standing in the frame.  Nothing is refused for its size.
  def test_one_array_larger_than_the_limit_goes_to_the_heap
    cells = CArray::JIT::Analyzer::LOCAL_ARRAY_BYTE_LIMIT / 8 + 1
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
        w = CArray.double(#{cells})
        w[0] = 1.0
        out[i] = w[0]
      }
    RUBY
    assert_match(/double \*w = NULL;/, kernel.c_source)
    assert_match(/w = malloc\(sizeof\(double\) \* \(size_t\) #{cells}\);/,
                 kernel.c_source)
    assert_match(/free\(w\);/, kernel.c_source)
    refute_match(/double w\[/, kernel.c_source)
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

  # The arrays of one kernel are held to a total in the frame, and the one
  # that would go past it is allocated instead -- so the ones before it stay
  # where they were.
  def test_the_array_that_would_pass_the_kernel_total_goes_to_the_heap
    each = CArray::JIT::Analyzer::LOCAL_ARRAY_BYTE_LIMIT / 8
    count = CArray::JIT::Analyzer::LOCAL_ARRAY_TOTAL_BYTE_LIMIT /
            CArray::JIT::Analyzer::LOCAL_ARRAY_BYTE_LIMIT + 1
    body = (0...count).map { |n|
      "  w#{n} = CArray.double(#{each})\n  w#{n}[0] = 1.0\n"
    }.join
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
      #{body}
        out[i] = w0[0]
      }
    RUBY
    (0...(count - 1)).each { |n|
      assert_match(/double w#{n}\[#{each}\];/, kernel.c_source,
                   "w#{n} still stands in the frame")
    }
    last = count - 1
    assert_match(/double \*w#{last} = NULL;/, kernel.c_source)
    assert_match(/free\(w#{last}\);/, kernel.c_source)
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

  # A kernel that carries masks gives every local array a shadow of one byte
  # per cell, and a cell of it carries what the expression written into it
  # carried.  So a window copied into an array of workspace keeps its holes,
  # and reading a cell back is reading what it was made of.
  #
  # The reference is the same loop written out in Ruby, with the mask read
  # off `is_masked` -- a Ruby loop cannot compute with UNDEF, so what it
  # writes by hand is which cells are missing and what the rest hold.

  def test_a_masked_window_copied_into_a_local_array_keeps_its_holes
    a = CArray.double(8).seq!(1.0)
    a[2] = UNDEF
    a[5] = UNDEF
    out = CArray.double(8)
    CArray.jit_for(1...7) { |i|
      w = CArray.double(3)
      w[0] = a[i - 1]
      w[1] = a[i]
      w[2] = a[i + 1]
      out[i] = w[0] + w[1] + w[2]
    }
    gone = a.is_masked.to_a
    (1...7).each do |i|
      window = [i - 1, i, i + 1]
      if window.any? { |k| gone[k] }
        assert_equal(UNDEF, out[i], "cell #{i}")
      else
        assert_bits_equal(window.sum { |k| a[k] }, out[i], "cell #{i}")
      end
    end
  end

  def test_a_masked_operand_and_a_local_array_meet_in_a_jit_each_block
    a = CArray.double(6).seq!(1.0)
    a[2] = UNDEF
    out = CArray.double(6)
    CArray.jit_each { w = CArray.double(2); w[0] = a; w[1] = a * 2.0; out = w[0] + w[1] }
    assert_equal([false, false, true, false, false, false], out.is_masked.to_a)
    [0, 1, 3, 4, 5].each { |k|
      assert_bits_equal(a[k] + a[k] * 2.0, out[k], "cell #{k}")
    }
  end

  def test_a_block_that_asks_about_undef_and_a_local_array_meet_in_a_map
    a = CArray.double(6).seq!(1.0)
    a[2] = UNDEF
    out = CArray.jit_map { w = CArray.double(2); w[0] = (a == UNDEF ? -1.0 : a); w[0] * 10.0 }
    # The question is answered rather than carried: a cell asked about UNDEF
    # is a cell whose value is known, so nothing here is missing.
    assert_equal([10.0, 20.0, -10.0, 40.0, 50.0, 60.0], out.to_a)
  end

  def test_a_masked_operand_and_a_local_array_meet_in_a_stencil
    image = CArray.double(6, 6).seq!
    image[2, 2] = UNDEF
    out = CArray.jit_stencil(image, border: :clamp) { |a|
      w = CArray.double(2)
      w[0] = a[0, 0]
      w[1] = a[0, 1]
      w[0] + w[1]
    }
    gone = image.is_masked.to_a
    6.times { |row| 6.times { |column|
      neighbour = [column + 1, 5].min
      if gone[row][column] || gone[row][neighbour]
        assert_equal(UNDEF, out[row, column], "cell #{row},#{column}")
      else
        assert_bits_equal(image[row, column] + image[row, neighbour],
                          out[row, column], "cell #{row},#{column}")
      end
    } }
  end

  def test_a_local_array_in_a_function_body_called_from_a_masked_kernel
    scale = CArray.jit_function("double scale(double x)") { |x|
      w = CArray.double(3)
      (0...3).each { |k| w[k] = x + k }
      w[0] + w[1] + w[2]
    }
    a = CArray.double(5).seq!(1.0)
    a[3] = UNDEF
    out = CArray.double(5)
    CArray.jit_for(5) { |i| out[i] = scale.call(a[i]) }
    assert_equal([false, false, false, true, false], out.is_masked.to_a)
    [0, 1, 2, 4].each { |k|
      assert_bits_equal(a[k] * 3 + 3, out[k], "cell #{k}")
    }
  end

  # ---------- UNDEF written into a local array, and asked about ----------

  def test_undef_written_into_a_cell_of_a_local_array_comes_back_out
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    CArray.jit_for(6) { |i|
      w = CArray.double(2)
      if a[i] > 3.0
        w[0] = UNDEF
      else
        w[0] = a[i]
      end
      w[1] = 100.0
      out[i] = w[0] + w[1]
    }
    assert_equal([false, false, false, true, true, true], out.is_masked.to_a)
    assert_equal([101.0, 102.0, 103.0], (0...3).map { |k| out[k] })
  end

  def test_a_cell_of_a_local_array_can_be_asked_about
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    CArray.jit_for(6) { |i|
      w = CArray.double(2)
      if a[i] > 3.0
        w[0] = UNDEF
      else
        w[0] = a[i]
      end
      w[1] = w[0] == UNDEF ? -1.0 : w[0] * 2.0
      out[i] = w[1]
    }
    assert_equal([2.0, 4.0, 6.0, -1.0, -1.0, -1.0], out.to_a)
    refute(out.has_mask? && out.is_masked.max == 1,
           "the question is answered, so nothing is carried out")
  end

  def test_a_cell_of_a_local_array_can_be_asked_the_other_way_round
    a = CArray.double(4).seq!(1.0)
    a[1] = UNDEF
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      w = CArray.double(1)
      w[0] = a[i]
      out[i] = w[0] != UNDEF ? 1.0 : 0.0
    }
    assert_equal([1.0, 0.0, 1.0, 1.0], out.to_a)
  end

  # A cell written on one arm of a branch and not the other holds, after the
  # branch, what the arm that ran put there -- the mask byte with it, since
  # the two are written together.
  def test_one_arm_of_a_branch_marks_the_cell_and_the_other_does_not
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    CArray.jit_for(6) { |i|
      w = CArray.double(1)
      if a[i] % 2.0 == 0.0
        w[0] = UNDEF
      else
        w[0] = a[i] * 10.0
      end
      out[i] = w[0]
    }
    assert_equal([false, true, false, true, false, true], out.is_masked.to_a)
    assert_equal([10.0, 30.0, 50.0], [0, 2, 4].map { |k| out[k] })
  end

  # The zeroed spellings clear the shadow as well as the cells, so a cell of
  # the array starts every pass present rather than holding what the pass
  # before left there.
  def test_the_zeroed_spelling_clears_the_shadow_at_every_cell
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    CArray.jit_for(6) { |i|
      w = CArray.double(2)
      if a[i] == 1.0
        w[0] = UNDEF
      end
      out[i] = w[0]
    }
    assert_equal([true, false, false, false, false, false], out.is_masked.to_a)
    assert_equal([0.0] * 5, (1...6).map { |k| out[k] })
  end

  def test_the_zeroed_spelling_clears_the_shadow_in_the_c
    kernel = compile_kernel(<<~RUBY, arrays: { :a => "float64", :out => "float64" }, masked: true)
      proc { |i|
        w = CArray.double(3)
        w[0] = a[i]
        out[i] = w[0]
      }
    RUBY
    assert_match(/uint8_t w__mask\[3\];/, kernel.c_source)
    assert_match(/memset\(w__mask, 0, sizeof w__mask\);/, kernel.c_source)
  end

  def test_the_empty_spelling_leaves_the_shadow_unspecified
    kernel = compile_kernel(<<~RUBY, arrays: { :a => "float64", :out => "float64" }, masked: true)
      proc { |i|
        w = CArray.empty(:float64, [3])
        w[0] = a[i]
        out[i] = w[0]
      }
    RUBY
    assert_match(/uint8_t w__mask\[3\];/, kernel.c_source)
    refute_match(/memset\(w__mask/, kernel.c_source)
  end

  # A kernel that carries no masks declares no shadow: what it emits is what
  # it emitted before there was one to declare.
  def test_an_unmasked_kernel_declares_no_shadow
    kernel = compile_kernel(<<~RUBY, arrays: { :a => "float64", :out => "float64" })
      proc { |i|
        w = CArray.double(3)
        w[0] = a[i]
        out[i] = w[0]
      }
    RUBY
    refute_match(/__mask/, kernel.c_source)
  end

  # A position only the running kernel knows is checked where it is reached,
  # and the shadow beside the cell is at that same position.  The mask is
  # asked first -- before it is known whether the cell being written is
  # missing -- so that read reports nothing, and the read of the value asks
  # the same question a moment later with that known.  One report per cell,
  # which is the rule a captured array's mask read already keeps.
  def test_a_computed_subscript_reports_once_under_masks
    kernel = compile_kernel(<<~RUBY, arrays: { :a => "float64", :idx => "int64", :out => "float64" }, masked: true)
      proc { |i|
        w = CArray.double(3)
        w[idx[i]] = a[i]
        out[i] = w[idx[i]]
      }
    RUBY
    assert_match(/w__mask\[carray_jit_index\(.*, 3, \(int32_t \*\) 0\)\]/,
                 kernel.c_source)
    assert_match(/w\[carray_jit_index\(.*, 3, \(masked__\d+ \? \(int32_t \*\) 0 : error\)\)\]/,
                 kernel.c_source)
    # The write worked its position out and tested it, so both the cell and
    # the byte beside it are reached through that one temporary.
    assert_match(/w\[position__\d+\] = /, kernel.c_source)
    assert_match(/w__mask\[position__\d+\] = /, kernel.c_source)
  end

  def test_a_computed_subscript_out_of_range_under_masks_raises
    a = CArray.double(4).seq!(1.0)
    a[1] = UNDEF
    where = CArray.int64(4).seq!
    out = CArray.double(4)
    assert_raises(IndexError) do
      CArray.jit_for(4) { |i|
        w = CArray.double(3)
        w[where[i]] = a[i]
        out[i] = w[0]
      }
    end
  end

  # ---------- the intrinsics and a C function, under masks ----------

  # What `sum` or `sort` should do with a missing cell is not decided -- skip
  # it, gather it at the end, count it in the middle of a median -- so the
  # four are refused over an array that carries one rather than given a
  # meaning here.
  def test_an_intrinsic_over_a_local_array_is_refused_under_masks
    a = CArray.double(6).seq!(1.0)
    a[2] = UNDEF
    out = CArray.double(6)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { w = CArray.double(2); w[0] = a; w[1] = a; out = sum(w) }
    end
    assert_match(/`sum`/, error.message)
    assert_match(/carries masks/, error.message)
    assert_match(/not decided|no meaning/, error.message)
  end

  def test_an_intrinsic_over_a_local_array_is_taken_without_masks
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    CArray.jit_each { w = CArray.double(2); w[0] = a; w[1] = a * 2.0; out = sum(w) }
    assert_equal((0...6).map { |k| a[k] * 3.0 }, out.to_a)
  end

  def test_a_local_array_handed_to_a_c_function_is_refused_under_masks
    total3 = CArray.jit_function("double total3(const double *v)") { |v|
      v[0] + v[1] + v[2]
    }
    a = CArray.double(6).seq!(1.0)
    a[2] = UNDEF
    out = CArray.double(6)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(6) { |i|
        w = CArray.double(3)
        w[0] = a[i]; w[1] = 1.0; w[2] = 2.0
        out[i] = total3.call(w)
      }
    end
    assert_match(/`w`/, error.message)
    assert_match(/carries masks/, error.message)
    assert_match(/no way to hand|nothing in C/, error.message)
  end

  def test_a_local_array_handed_to_a_c_function_is_taken_without_masks
    total3 = CArray.jit_function("double total3(const double *v)") { |v|
      v[0] + v[1] + v[2]
    }
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    CArray.jit_for(6) { |i|
      w = CArray.double(3)
      w[0] = a[i]; w[1] = 1.0; w[2] = 2.0
      out[i] = total3.call(w)
    }
    assert_equal((0...6).map { |k| a[k] + 3.0 }, out.to_a)
  end

  # ---------- the room the shadow takes ----------

  # The shadow is a byte a cell, and it is on the same stack, so it is
  # counted against the same limit: an array that fits by its cells alone
  # does not fit once it carries masks.
  # The shadow is a byte a cell on the same stack, so it counts towards
  # where the array goes: one that fits in the frame by its cells alone is
  # allocated once it carries masks.
  def test_the_shadow_is_counted_towards_the_placement
    cells = CArray::JIT::Analyzer::LOCAL_ARRAY_BYTE_LIMIT / 8
    unmasked = compile_kernel(<<~RUBY, arrays: { :a => "float64", :out => "float64" })
      proc { |i|
        w = CArray.double(#{cells})
        w[0] = a[i]
        out[i] = w[0]
      }
    RUBY
    assert_match(/double w\[#{cells}\];/, unmasked.c_source)
    masked = compile_kernel(<<~RUBY, arrays: { :a => "float64", :out => "float64" }, masked: true)
      proc { |i|
        w = CArray.double(#{cells})
        w[0] = a[i]
        out[i] = w[0]
      }
    RUBY
    assert_match(/double \*w = NULL;/, masked.c_source)
    assert_match(/uint8_t \*w__mask = NULL;/, masked.c_source)
    assert_match(/w__mask = malloc\(\(size_t\) #{cells}\);/, masked.c_source)
    assert_match(/free\(w__mask\);/, masked.c_source)
  end

  def test_the_shadow_is_counted_towards_the_placement_for_the_kernel
    # Small enough that each array fits on its own either way -- what is
    # being measured is the total -- and enough of them that the shadows are
    # what puts it over.
    each = 400
    count = CArray::JIT::Analyzer::LOCAL_ARRAY_TOTAL_BYTE_LIMIT / (8 * each)
    body = (0...count).map { |n|
      "  w#{n} = CArray.double(#{each})\n  w#{n}[0] = a[i]\n"
    }.join
    arrays = { :a => "float64", :out => "float64" }
    taken = compile_kernel(<<~RUBY, arrays: arrays)
      proc { |i|
      #{body}
        out[i] = w0[0]
      }
    RUBY
    assert_match(/double w0\[#{each}\];/, taken.c_source)
    masked = compile_kernel(<<~RUBY, arrays: arrays, masked: true)
      proc { |i|
      #{body}
        out[i] = w0[0]
      }
    RUBY
    # The shadows are what take the total past the frame's share, so the last
    # of them is the one allocated.
    assert_match(/double w0\[#{each}\];/, masked.c_source)
    assert_match(/double \*w#{count - 1} = NULL;/, masked.c_source)
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
    # A body has no entry outside the kernel's loop to allocate at, so the
    # one that would not fit in the frame is refused rather than moved.
    assert_match(/a function's body is called once per cell/, error.message)
    assert_match(/pass it in/, error.message)
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

  # ---------- more than one axis ----------

  # The shape is written out, so the strides are constants and each axis has
  # an extent of its own to be checked against.  That is what flattening by
  # hand gives up: `m[r * 4 + c]` with `c` at 4 walks into the next row and
  # says nothing, where `m[r, c]` is refused.

  def test_a_two_dimensional_local_array_is_addressed_per_axis
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      m = CArray.double(3, 4)
      3.times { |r| 4.times { |c| m[r, c] = (r * 4 + c) * 1.0 } }
      out[i] = m[2, 3] * 100.0 + m[0, 1]
    }
    assert_equal([1101.0] * 3, out.to_a)
  end

  def test_the_declaration_is_flat_and_the_strides_are_constants
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
        m = CArray.double(3, 4)
        m[2, 3] = 1.0
        out[i] = m[2, 3]
      }
    RUBY
    assert_match(/double m\[12\];/, kernel.c_source,
                 "twelve cells, packed row-major")
    assert_match(/m\[\(INT64_C\(2\)\) \* 4 \+ INT64_C\(3\)\]/, kernel.c_source,
                 "the stride is baked from the shape")
  end

  def test_a_three_dimensional_local_array
    out = CArray.double(2)
    CArray.jit_for(2) { |i|
      m = CArray.double(2, 3, 4)
      2.times { |p| 3.times { |r| 4.times { |c| m[p, r, c] = (p * 12 + r * 4 + c) * 1.0 } } }
      out[i] = m[1, 2, 3]
    }
    assert_equal([23.0] * 2, out.to_a, "the last cell of 2x3x4")
  end

  def test_three_axes_bake_two_strides
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
        m = CArray.double(2, 3, 4)
        m[1, 2, 3] = 1.0
        out[i] = m[1, 2, 3]
      }
    RUBY
    assert_match(/double m\[24\];/, kernel.c_source)
    assert_match(/\* 12 \+/, kernel.c_source, "the outer stride is 3 * 4")
    assert_match(/\* 4 \+/, kernel.c_source, "and the middle one is 4")
  end

  # Example 4 of the proposal: a 3x3 system per cell, forward elimination and
  # back substitution, with the triangular ranges written as `if` (§6.8).
  def test_the_three_by_three_solve_matches_the_same_loop_in_ruby
    ny, nx = 3, 4
    coef = CArray.double(ny, nx, 3, 4)
    coef.seq!(1.0, 0.25)
    # Make the diagonal dominant so the pivotless elimination is sound.
    ny.times { |i| nx.times { |j| 3.times { |r|
      coef[i, j, r, r] = coef[i, j, r, r] + 20.0
    } } }
    x = CArray.double(ny, nx, 3)
    CArray.jit_for(ny, nx) { |i, j|
      m = CArray.double(3, 4)
      3.times { |r| 4.times { |c| m[r, c] = coef[i, j, r, c] } }
      3.times { |p|
        3.times { |r|
          if r > p
            f = m[r, p] / m[p, p]
            4.times { |c| m[r, c] -= f * m[p, c] }
          end
        }
      }
      sol = CArray.double(3)
      2.step(0, -1) { |r|
        s = m[r, 3]
        3.times { |c| s -= m[r, c] * sol[c] if c > r }
        sol[r] = s / m[r, r]
      }
      3.times { |r| x[i, j, r] = sol[r] }
    }
    reference = CArray.double(ny, nx, 3)
    ny.times { |i| nx.times { |j|
      m = CArray.double(3, 4)
      3.times { |r| 4.times { |c| m[r, c] = coef[i, j, r, c] } }
      3.times { |p|
        3.times { |r|
          if r > p
            f = m[r, p] / m[p, p]
            4.times { |c| m[r, c] -= f * m[p, c] }
          end
        }
      }
      sol = CArray.double(3)
      2.step(0, -1) { |r|
        sum = m[r, 3]
        3.times { |c| sum -= m[r, c] * sol[c] if c > r }
        sol[r] = sum / m[r, r]
      }
      3.times { |r| reference[i, j, r] = sol[r] }
    } }
    assert_arrays_bits_equal(reference.flatten, x.flatten)
  end

  # ---------- the checks, per axis ----------

  def test_one_axis_past_its_end_is_refused_while_the_others_fit
    pattern = /the subscript `c` on axis 1 of `m`, which is 3 x 4,/
    error = refuse(<<~RUBY, pattern, arrays: { :out => "float64" })
      proc { |i|
        m = CArray.double(3, 4)
        3.times { |r| 5.times { |c| m[r, c] = 1.0 } }
        out[i] = m[0, 0]
      }
    RUBY
    assert_match(/reaches cell 4 of that axis's 4 cells/, error.message,
                 "the axis is named rather than a spelling nobody wrote")
  end

  def test_the_row_axis_past_its_end_is_refused_too
    refuse(<<~RUBY, /reaches cell 3/, arrays: { :out => "float64" })
      proc { |i|
        m = CArray.double(3, 4)
        4.times { |r| 4.times { |c| m[r, c] = 1.0 } }
        out[i] = m[0, 0]
      }
    RUBY
  end

  def test_a_computed_column_out_of_range_raises
    columns = CArray.int64(3).seq!(9)
    out = CArray.double(3)
    assert_raises(IndexError) do
      CArray.jit_for(3) { |i|
        m = CArray.double(3, 4)
        out[i] = m[0, columns[i]]
      }
    end
  end

  # The point of per-axis checking: a column past its end does not silently
  # become a cell of the next row.
  def test_a_write_past_one_axis_leaves_the_next_row_alone
    columns = CArray.int64(3)
    columns[0] = 0
    columns[1] = 1
    columns[2] = 9
    seen = CArray.double(3)
    assert_raises(IndexError) do
      CArray.jit_for(3) { |i|
        m = CArray.double(3, 4)
        m[1, 0] = 7.0
        m[0, columns[i]] = 99.0
        seen[i] = m[1, 0]
      }
    end
    assert_equal(7.0, seen[0], "an inside column does not touch row 1")
    assert_equal(7.0, seen[1])
  end

  def test_the_number_of_subscripts_has_to_match_the_axes
    error = refuse(<<~RUBY, /has 2 axes/, arrays: { :out => "float64" })
      proc { |i|
        m = CArray.double(3, 4)
        out[i] = m[1]
      }
    RUBY
    assert_match(/takes 2 subscripts/, error.message)
    assert_match(/1 was written/, error.message)
  end

  def test_a_literal_subscript_past_one_axis_is_refused
    pattern = /the subscript `4` on axis 1 of `m`, which is 3 x 4, is outside/
    error = refuse(<<~RUBY, pattern, arrays: { :out => "float64" })
      proc { |i|
        m = CArray.double(3, 4)
        m[0, 4] = 1.0
        out[i] = m[0, 0]
      }
    RUBY
    assert_match(/that axis's 4 cells, whose cells are 0 to 3/, error.message)
  end

  # ---------- the room it takes ----------

  # Counted over every cell rather than per axis, which is what decides
  # where a two-dimensional array of this size goes.
  def test_a_shape_whose_cells_come_to_more_than_the_limit_goes_to_the_heap
    cells = CArray::JIT::Analyzer::LOCAL_ARRAY_BYTE_LIMIT / 8
    side = Integer(Math.sqrt(cells)) + 1
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
        m = CArray.double(#{side}, #{side})
        m[0, 0] = 1.0
        out[i] = m[0, 0]
      }
    RUBY
    assert_match(/double \*m = NULL;/, kernel.c_source)
    assert_match(/\(size_t\) #{side * side}\);/, kernel.c_source)
  end

  def test_two_dimensional_arrays_count_towards_the_placement
    each = CArray::JIT::Analyzer::LOCAL_ARRAY_BYTE_LIMIT / 8 / 16
    body = (0...5).map { |n|
      "  m#{n} = CArray.double(16, #{each})\n  m#{n}[0, 0] = 1.0\n"
    }.join
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" })
      proc { |i|
      #{body}
        out[i] = m0[0, 0]
      }
    RUBY
    # Four of them fill the frame's share, counted over every cell; the
    # fifth is allocated.
    assert_match(/double m0\[#{16 * each}\];/, kernel.c_source)
    assert_match(/double \*m4 = NULL;/, kernel.c_source)
  end

  # ---------- across the entry points ----------

  def test_more_than_one_axis_in_every_entry_point
    a = CArray.double(4).seq!(1.0)

    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      m = CArray.double(2, 2)
      m[0, 0] = a[i]; m[1, 1] = a[i] * 2.0
      out[i] = m[0, 0] + m[1, 1]
    }
    assert_equal((0...4).map { |k| a[k] * 3.0 }, out.to_a, "jit_for")

    each = CArray.double(4)
    CArray.jit_each {
      m = CArray.double(2, 2)
      m[0, 0] = a
      m[1, 1] = a * 2.0
      each = m[0, 0] + m[1, 1]
    }
    assert_equal((0...4).map { |k| a[k] * 3.0 }, each.to_a, "jit_each")

    mapped = CArray.jit_map {
      m = CArray.double(2, 2)
      m[0, 0] = a
      m[1, 1] = a * 2.0
      m[0, 0] + m[1, 1]
    }
    assert_equal((0...4).map { |k| a[k] * 3.0 }, mapped.to_a, "jit_map")

    image = CArray.double(5, 5).seq!
    stencilled = CArray.jit_stencil(image, border: :clamp) { |win|
      m = CArray.double(2, 2)
      m[0, 0] = win[0, 0]
      m[1, 1] = win[0, 0] * 2.0
      m[0, 0] + m[1, 1]
    }
    assert_equal(image[2, 2] * 3.0, stencilled[2, 2], "jit_stencil")

    body = CArray.jit_function("double twodim(double x)") { |x|
      m = CArray.double(2, 2)
      m[0, 0] = x
      m[1, 1] = x * 2.0
      m[0, 0] + m[1, 1]
    }
    assert_equal(9.0, body.call(3.0), "a function body")
    from_kernel = CArray.double(2)
    CArray.jit_for(2) { |i| from_kernel[i] = body.call(i * 1.0) }
    assert_equal([0.0, 3.0], from_kernel.to_a, "and the same body pasted")
  end

  # ---------- handed to a C function, flat ----------

  # A local array is packed row-major, so C takes it as the flat run of cells
  # it is: a `double[3][4]` goes to `const double a[12]`.
  def test_a_two_dimensional_array_goes_to_a_flat_declaration
    total = CArray.jit_function("double total12(const double a[12])") { |a|
      s = 0.0
      (0...12).each { |k| s = s + a[k] }
      s
    }
    out = CArray.double(2)
    CArray.jit_for(2) { |i|
      m = CArray.double(3, 4)
      3.times { |r| 4.times { |c| m[r, c] = (r * 4 + c) * 1.0 } }
      out[i] = total.call(m)
    }
    assert_equal([(0...12).sum * 1.0] * 2, out.to_a)
  end

  def test_row_major_is_the_order_the_callee_sees
    first = CArray.jit_function("double cell(const double a[12], double k)") { |a, k|
      a[k.to_i]
    }
    out = CArray.double(12)
    CArray.jit_for(12) { |i|
      m = CArray.double(3, 4)
      3.times { |r| 4.times { |c| m[r, c] = r * 100.0 + c } }
      out[i] = first.call(m, i * 1.0)
    }
    reference = (0...3).flat_map { |r| (0...4).map { |c| r * 100.0 + c } }
    assert_equal(reference, out.to_a, "row after row")
  end

  def test_too_few_cells_for_the_declaration_is_refused_as_it_is_read
    error = assert_raises(CArray::JIT::Unsupported) do
      total = CArray.jit_function("double total12b(const double a[12])") { |a| a[0] }
      out = CArray.double(1)
      CArray.jit_for(1) { |i|
        m = CArray.double(2, 4)
        out[i] = total.call(m)
      }
    end
    assert_match(/reads 12 cells/, error.message)
    assert_match(/has 8/, error.message, "eight cells over both axes")
  end

  def test_a_three_dimensional_array_goes_to_a_flat_declaration_too
    total = CArray.jit_function("double total24(const double a[24])") { |a|
      s = 0.0
      (0...24).each { |k| s = s + a[k] }
      s
    }
    out = CArray.double(1)
    CArray.jit_for(1) { |i|
      m = CArray.double(2, 3, 4)
      2.times { |p| 3.times { |r| 4.times { |c| m[p, r, c] = 1.0 } } }
      out[i] = total.call(m)
    }
    assert_equal([24.0], out.to_a)
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

  # ---------- the arrays the kernel allocates ----------

  # Past the frame's share, and wherever the length is not known until the
  # kernel runs, the array is one allocation at the kernel's entry and a free
  # at its exit.  Nothing about how a cell is reached changes: what changes
  # is the declaration, and that every check against the length happens
  # where the cell is reached.

  def test_a_shape_over_a_captured_integer_matches_the_same_loop_in_ruby
    a = CArray.double(6).seq!(1.0)
    n = 300
    out = CArray.double(6)
    CArray.jit_for(6) { |i|
      w = CArray.double(n)
      (0...n).each { |k| w[k] = a[i] * k }
      s = 0.0
      (0...n).each { |k| s += w[k] }
      out[i] = s
    }
    reference = (0...6).map { |i|
      w = CArray.double(n)
      (0...n).each { |k| w[k] = a[i] * k }
      s = 0.0
      (0...n).each { |k| s += w[k] }
      s
    }
    assert_arrays_bits_equal(CArray.double(6) { reference }, out)
  end

  def test_a_literal_shape_over_the_limit_matches_the_same_loop_in_ruby
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      w = CArray.double(4096)
      (0...4096).each { |k| w[k] = a[i] + k }
      out[i] = w[0] + w[4095]
    }
    reference = (0...4).map { |i| a[i] + (a[i] + 4095) }
    assert_arrays_bits_equal(CArray.double(4) { reference }, out)
  end

  # The same block at two lengths is one kernel: the length travels as an
  # argument, so it is not in the C and the C is shared.  Written out rather
  # than built from a variable, because the source text is the cache key.
  def test_two_lengths_of_one_block_are_one_kernel
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    # One `proc`, called twice: two blocks written out would be two source
    # texts and so two kernels whatever the lengths were.
    pass = proc { |n|
      CArray.jit_for(6) { |i| w = CArray.double(n); w[0] = a[i] * n; out[i] = w[0] }
    }
    before = CArray::JIT.registry.size
    pass.call(7)
    after_one = CArray::JIT.registry.size
    assert_equal(1, after_one - before, "the first call compiled one kernel")
    assert_equal((0...6).map { |k| a[k] * 7 }, out.to_a)
    pass.call(900)
    assert_equal(after_one, CArray::JIT.registry.size,
                 "the second length compiled nothing")
    assert_equal((0...6).map { |k| a[k] * 900 }, out.to_a)
  end

  def test_the_length_is_worked_out_at_the_entry_and_freed_at_the_exit
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" }, scalars: { :n => 8 })
      proc { |i|
        w = CArray.double(n * 2)
        w[0] = 1.0
        out[i] = w[0]
      }
    RUBY
    body = kernel.c_source[/^static void\ncarray_jit_strided.*?\n^\}/m]
    assert_match(/const int64_t w__extent0 = n \* INT64_C\(2\);/, body)
    assert_match(/w = malloc\(sizeof\(double\) \* \(size_t\) w__cells\);/, body)
    # Allocated before the loop and freed after it, once either way.
    entry = body.index("malloc(")
    opening = body.index("for (int64_t i")
    closing = body.rindex("free(w);")
    assert(entry < opening, "the allocation stands before the loop")
    assert(closing > opening, "the free stands after it")
    assert_equal(1, body.scan(/malloc\(/).size, "one allocation per body")
  end

  # Every body allocates and frees: the two the dispatcher chooses between,
  # and the frame's own walk.
  def test_each_body_allocates_and_frees
    field = CArray.double(6, 6).seq!
    n = 40
    CArray.jit_stencil(field, border: :clamp) { |x|
      w = CArray.double(n)
      w[0] = x[0, 0]
      w[1] = x[0, 1]
      w[0] + w[1]
    }
    kernel = CArray::JIT.registry.values.last
    %w[carray_jit_strided carray_jit_contiguous carray_jit_border].each do |name|
      body = kernel.c_source[/^(?:static )?void\n#{name} .*?\n^\}/m]
      refute_nil(body, "#{name} is in the file")
      assert_equal(1, body.scan(/malloc\(/).size, "#{name} allocates once")
      # Twice over: once where the allocation failed and the body leaves
      # before the loop, once at the end.
      assert_equal(2, body.scan(/free\(w\);/).size, "#{name} frees on both ways out")
      assert_match(/free\(w\);\n\}\z/, body, "#{name} frees at its end")
    end
  end

  # A `raise` leaves the function from inside the loop, which is the one way
  # out that is not the end of it.
  def test_a_raise_frees_before_it_leaves
    a = CArray.double(6).seq!(1.0)
    n = 40
    out = CArray.double(6)
    error = assert_raises(RuntimeError) do
      CArray.jit_for(6) { |i|
        w = CArray.double(n)
        raise "past four" if a[i] > 4.5
        w[0] = a[i]
        out[i] = w[0]
      }
    end
    assert_equal("past four", error.message)
    kernel = CArray::JIT.registry.values.last
    body = kernel.c_source[/^static void\ncarray_jit_strided.*?\n^\}/m]
    reporting = body[/if \( error && !\*error \) \{.*?\n *\}/m]
    assert_match(/free\(w\);/, reporting,
                 "the array is freed on the way out of the raise")
    assert_match(/free\(w\);\n *return;/, reporting)
  end

  def test_the_cells_are_cleared_at_every_pass
    a = CArray.double(4).seq!(1.0)
    n = 300
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      w = CArray.double(n)
      if i == 0
        (0...n).each { |k| w[k] = 99.0 }
      end
      s = 0.0
      (0...n).each { |k| s += w[k] }
      out[i] = s
    }
    assert_equal([99.0 * n, 0.0, 0.0, 0.0], out.to_a,
                 "a fresh array of zeros at every pass, as in Ruby")
  end

  def test_the_empty_spelling_of_an_allocated_array_clears_nothing
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" }, scalars: { :n => 8 })
      proc { |i|
        w = CArray.empty(:float64, [n])
        w[0] = 1.0
        out[i] = w[0]
      }
    RUBY
    assert_match(/w = malloc\(/, kernel.c_source)
    refute_match(/memset\(w,/, kernel.c_source)
  end

  # ---------- the checks, against a length the kernel worked out ----------

  # (a) has no number to compare a reach against, so every position on such
  # an axis is checked where the cell is reached -- a literal one included,
  # since 3 is inside an array of 4 cells and outside one of 2.
  def test_every_position_on_such_an_axis_is_checked_at_the_access
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" }, scalars: { :n => 8 })
      proc { |i|
        w = CArray.double(n)
        w[0] = 1.0
        (0...3).each { |k| w[k] = 2.0 }
        out[i] = w[1]
      }
    RUBY
    assert_match(/w\[carray_jit_index\(INT64_C\(1\), w__extent0, error\)\]/,
                 kernel.c_source)
    assert_match(/position__\d+ < w__extent0/, kernel.c_source)
  end

  def test_a_read_past_the_end_raises
    a = CArray.double(4).seq!(1.0)
    n = 3
    out = CArray.double(4)
    assert_raises(IndexError) do
      CArray.jit_for(4) { |i|
        w = CArray.double(n)
        (0...4).each { |k| w[k] = a[i] }
        out[i] = w[0]
      }
    end
  end

  def test_a_write_past_the_end_writes_nothing_and_raises
    a = CArray.double(4).seq!(1.0)
    n = 3
    out = CArray.double(4)
    witness = CArray.double(4)
    assert_raises(IndexError) do
      CArray.jit_for(4) { |i|
        w = CArray.double(n)
        w[0] = 11.0
        w[n] = 99.0
        witness[i] = w[0]
        out[i] = w[0]
      }
    end
    # Cell zero is where a refused write would have landed if the position
    # were clamped rather than tested, so what it still holds is the
    # evidence: 11.0, not the 99.0 the refused write carried.  The pass it
    # was in runs to its end -- the report stops the loop at the head of the
    # next one -- which is what put that value in the witness.
    assert_equal(11.0, witness[0])
  end

  # ---------- a length that is no length ----------

  def test_a_captured_length_of_zero_is_reported
    a = CArray.double(4).seq!(1.0)
    n = 0
    out = CArray.double(4)
    error = assert_raises(ArgumentError) do
      CArray.jit_for(4) { |i| w = CArray.double(n); w[0] = a[i]; out[i] = w[0] }
    end
    assert_match(/at least one cell/, error.message)
    assert_match(/`w`/, error.message)
    assert_match(/0 cells/, error.message)
  end

  def test_a_negative_captured_length_is_reported
    a = CArray.double(4).seq!(1.0)
    n = -3
    out = CArray.double(4)
    error = assert_raises(ArgumentError) do
      CArray.jit_for(4) { |i| w = CArray.double(n); w[0] = a[i]; out[i] = w[0] }
    end
    assert_match(/-3 cells/, error.message)
  end

  # A length whose bytes could not be counted in a `size_t` is reported
  # rather than multiplied out: the multiplication into the allocation would
  # wrap, and a small allocation answered for a huge one is the worst of the
  # outcomes.  It is also the only size failure that can be provoked
  # portably -- an allocator that reserves lazily says yes to almost
  # anything, and the allocation that does fail reports through the same
  # slot with its own message.
  def test_a_length_too_large_to_count_in_bytes_is_reported
    a = CArray.double(4).seq!(1.0)
    n = 2**62
    out = CArray.double(4)
    error = assert_raises(ArgumentError) do
      CArray.jit_for(4) { |i| w = CArray.double(n); w[0] = a[i]; out[i] = w[0] }
    end
    assert_match(/more cells than its bytes could be counted in/, error.message)
  end

  # Each length fits and their product does not.  Two lengths of 2**32 come
  # to 2**64 cells, which multiplied in an `int64_t` is zero: asked of the
  # product, that fit, and `w[0, 1000]` -- in range on both axes -- was
  # written into an allocation of no cells.
  def test_lengths_whose_product_is_too_large_are_reported
    a = CArray.double(4).seq!(1.0)
    n = 2**32
    out = CArray.double(4)
    error = assert_raises(ArgumentError) do
      CArray.jit_for(4) { |i|
        w = CArray.double(n, n)
        w[0, 1000] = a[i]
        out[i] = w[0, 1000]
      }
    end
    assert_match(/more cells than its bytes could be counted in/, error.message)
    m = 2**22
    error = assert_raises(ArgumentError) do
      CArray.jit_for(4) { |i|
        w = CArray.double(m, m, m)
        w[1, 1, 1] = a[i]
        out[i] = w[1, 1, 1]
      }
    end
    assert_match(/more cells than its bytes could be counted in/, error.message)
  end

  def test_the_shape_may_not_vary_from_cell_to_cell
    arrays = { :a => "float64", :out => "float64" }
    index = refuse(<<~RUBY, /loop index/, arrays: arrays)
      proc { |i|
        w = CArray.double(i + 2)
        out[i] = w[0]
      }
    RUBY
    assert_match(/one allocation made before the first cell/, index.message)
    refuse(<<~RUBY, /is a cell of an array/, arrays: arrays)
      proc { |i|
        w = CArray.double(a[i])
        out[i] = w[0]
      }
    RUBY
    refuse(<<~RUBY, /worked out inside the block/, arrays: arrays)
      proc { |i|
        m = 4
        w = CArray.double(m)
        out[i] = w[0]
      }
    RUBY
  end

  def test_a_captured_length_is_a_whole_number_of_cells
    refuse(<<~RUBY, /a whole number of cells/, arrays: { :out => "float64" }, scalars: { :q => 3.5 })
      proc { |i|
        w = CArray.double(q)
        out[i] = w[0]
      }
    RUBY
  end

  # ---------- the shadow, and the intrinsics, and a C function ----------

  def test_an_allocated_array_carries_its_shadow
    a = CArray.double(6).seq!(1.0)
    a[2] = UNDEF
    n = 200
    out = CArray.double(6)
    CArray.jit_for(6) { |i|
      w = CArray.double(n)
      w[0] = a[i]
      w[1] = 1.0
      out[i] = w[0] + w[1]
    }
    assert_equal([false, false, true, false, false, false], out.is_masked.to_a)
    [0, 1, 3, 4, 5].each { |k|
      assert_bits_equal(a[k] + 1.0, out[k], "cell #{k}")
    }
  end

  def test_the_shadow_of_an_allocated_array_is_allocated_with_it
    kernel = compile_kernel(<<~RUBY, arrays: { :a => "float64", :out => "float64" }, scalars: { :n => 8 }, masked: true)
      proc { |i|
        w = CArray.double(n)
        w[0] = a[i]
        out[i] = w[0]
      }
    RUBY
    assert_match(/uint8_t \*w__mask = NULL;/, kernel.c_source)
    assert_match(/w__mask = malloc\(\(size_t\) w__cells\);/, kernel.c_source)
    assert_match(/memset\(w__mask, 0, \(size_t\) w__cells\);/, kernel.c_source)
    assert_match(/free\(w__mask\);/, kernel.c_source)
  end

  # `sum`, `min` and `max` take the length as an argument, so a length the
  # kernel worked out serves as well as a number.  `sort` chooses its
  # algorithm as the C is written, and a network is a fixed run of
  # comparators -- so a length that is not a number sorts by the helper that
  # takes one, which is the insertion sort.
  def test_the_intrinsics_over_a_length_the_kernel_worked_out
    a = CArray.double(4).seq!(1.0)
    n = 20
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      w = CArray.double(n)
      (0...n).each { |k| w[k] = a[i] * (n - k) }
      sort(w)
      out[i] = sum(w) * 1000 + min(w) * 10 + max(w)
    }
    reference = (0...4).map { |i|
      cells = (0...n).map { |k| a[i] * (n - k) }.sort
      cells.sum * 1000 + cells.first * 10 + cells.last
    }
    assert_arrays_bits_equal(CArray.double(4) { reference }, out)
  end

  def test_a_sort_over_such_a_length_is_the_insertion_sort
    kernel = compile_kernel(<<~RUBY, arrays: { :out => "float64" }, scalars: { :n => 4 })
      proc { |i|
        w = CArray.double(n)
        w[0] = 1.0
        sort(w)
        out[i] = w[0]
      }
    RUBY
    assert_match(/carray_jit_sort_float64\(w, w__extent0\);/, kernel.c_source)
    refute_match(/carray_jit_sort_float64_\d/, kernel.c_source,
                 "a network is chosen by a length that is a number")
  end

  def test_an_allocated_array_goes_to_a_pointer_with_no_length
    total = CArray.jit_function("double heap_total3(const double *v)") { |v|
      v[0] + v[1] + v[2]
    }
    a = CArray.double(4).seq!(1.0)
    n = 300
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      w = CArray.double(n)
      w[0] = a[i]; w[1] = 1.0; w[2] = 2.0
      out[i] = total.call(w)
    }
    assert_equal((0...4).map { |k| a[k] + 3.0 }, out.to_a)
  end

  def test_a_declaration_with_a_length_takes_no_such_array
    sized = CArray.jit_function("double heap_sized(const double v[3])") { |v|
      v[0] + v[1] + v[2]
    }
    a = CArray.double(4).seq!(1.0)
    n = 300
    out = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i|
        w = CArray.double(n)
        w[0] = a[i]
        out[i] = sized.call(w)
      }
    end
    assert_match(/worked out when the kernel runs/, error.message)
    assert_match(/Declare the parameter without a length/, error.message)
  end

  # ---------- a body allocates nothing ----------

  def test_a_function_body_takes_no_allocated_array
    runtime = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double body_runtime(int64_t n)") { |n|
        w = CArray.double(n)
        w[0] = 1.0
        w[0]
      }
    end
    assert_match(/worked out when the kernel runs/, runtime.message)
    assert_match(/once per cell/, runtime.message)
    assert_match(/pass it in/, runtime.message)
    big = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double body_big(double x)") { |x|
        w = CArray.double(4096)
        w[0] = x
        w[0]
      }
    end
    assert_match(/past the #{CArray::JIT::Analyzer::LOCAL_ARRAY_BYTE_LIMIT}/,
                 big.message)
    assert_match(/once per cell/, big.message)
  end

  # ---------- across the entry points ----------

  def test_an_allocated_array_in_every_entry_point
    a = CArray.double(6).seq!(1.0)
    n = 300

    out = CArray.double(6)
    CArray.jit_for(6) { |i|
      w = CArray.double(n)
      w[0] = a[i]; w[1] = a[i] * 2.0
      out[i] = w[0] + w[1]
    }
    assert_equal((0...6).map { |k| a[k] * 3.0 }, out.to_a, "jit_for")

    each = CArray.double(6)
    CArray.jit_each { w = CArray.double(n); w[0] = a; w[1] = a * 2.0; each = w[0] + w[1] }
    assert_equal((0...6).map { |k| a[k] * 3.0 }, each.to_a, "jit_each")

    mapped = CArray.jit_map { w = CArray.double(n); w[0] = a; w[1] = a * 2.0; w[0] + w[1] }
    assert_equal((0...6).map { |k| a[k] * 3.0 }, mapped.to_a, "jit_map")

    field = CArray.double(5, 5).seq!
    stencilled = CArray.jit_stencil(field, border: :clamp) { |x|
      w = CArray.double(n)
      w[0] = x[0, 0]; w[1] = x[0, 1]
      w[0] + w[1]
    }
    assert_equal(field[2, 2] + field[2, 3], stencilled[2, 2], "jit_stencil")

    # The fifth is a body, which allocates nothing of its own: what it takes
    # is the array the kernel allocated, as a pointer.
    reader = CArray.jit_function("double heap_head(const double *v)") { |v| v[0] }
    through = CArray.double(6)
    CArray.jit_for(6) { |i|
      w = CArray.double(n)
      w[0] = a[i] * 5.0
      through[i] = reader.call(w)
    }
    assert_equal((0...6).map { |k| a[k] * 5.0 }, through.to_a, "jit_function")
  end

  # A sweep hands the kernel one chunk at a time, so the entry it allocates
  # at is reached once per chunk -- which is still outside the cell loop,
  # and is what the allocation being one per entry means there.
  def test_a_swept_pass_allocates_per_chunk_and_answers_the_same
    a = CArray.double(50_000).seq!(1.0)
    n = 300
    out = CArray.double(50_000)
    CArray.jit_each { w = CArray.double(n); w[0] = a; w[1] = a * 2.0; out = w[0] + w[1] }
    kernel = CArray::JIT.registry.values.last
    assert(kernel.sweepable?, "a jit_each block with no mask sweeps")
    assert_equal(3.0, out[0])
    assert_equal(a[49_999] * 3.0, out[49_999])
  end

  # ---------- still refused, as in the first release ----------

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
