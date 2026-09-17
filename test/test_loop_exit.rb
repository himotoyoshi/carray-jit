require_relative "test_helper"
require "rbconfig"

# A failure that reports and carries on -- a division with no divisor, a
# computed index off the end -- leaves a loop at the head of its next pass.
# A loop that did not look would run on the zero it was handed, and a `while`
# decided by that zero need never finish.
#
# So every run here is in a child process with a time limit.  A kernel that
# has let go of the GVL is out of Timeout's reach, and a test that hangs
# says less than one that fails.
class TestLoopExit < Minitest::Test

  include KernelCompilation

  LIMIT = 60

  # The CArray this process loaded, so the child runs against the same one.
  def load_path
    extension = $LOADED_FEATURES.grep(%r{/carray_ext\.#{RbConfig::CONFIG['DLEXT']}\z}).first
    library = $LOADED_FEATURES.grep(%r{/carray\.rb\z}).first
    [File.expand_path("../lib", __dir__), extension, library]
      .compact.map { |path| File.directory?(path) ? path : File.dirname(path) }.uniq
  end

  # Runs `script` after `require "carray/jit"` and answers what it printed.
  # A child still running at the limit is killed and fails the test.
  def run_isolated (script)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "loop_exit.rb")
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

  def raised_by
    yield
    nil
  rescue StandardError => error
    error.class
  end

  # ---------- a function standing on its own ----------

  def test_a_function_whose_loop_divides_by_zero_stops
    reference = ->(n) { k = 0; while 10 / n == 0; k += 1; end; k }
    output = run_isolated(<<~RUBY)
      f = CArray.jit_function("int64_t f(int64_t n)") { |n|
        k = 0
        while 10 / n == 0
          k += 1
        end
        k
      }
      p f.call(5)
      begin
        f.call(0)
        p :returned
      rescue StandardError => error
        p error.class
      end
    RUBY
    assert_equal("#{reference.(5)}\n#{raised_by { reference.(0) }}\n", output)
  end

  # ---------- the same function pasted into a kernel ----------

  def test_a_pasted_function_whose_loop_divides_by_zero_stops
    values = [5, 0, 2]
    expected = raised_by {
      values.map { |n| k = 0; while 10 / n == 0; k += 1; end; k }
    }
    output = run_isolated(<<~RUBY)
      f = CArray.jit_function("int64_t f(int64_t n)") { |n|
        k = 0
        while 10 / n == 0
          k += 1
        end
        k
      }
      a = CArray.int64(3) { #{values.inspect} }
      out = CArray.int64(3)
      begin
        CArray.jit_each { out = f.call(a) }
        p :returned
      rescue StandardError => error
        p error.class
      end
    RUBY
    assert_equal("#{expected}\n", output)
  end

  # Under a masked cell the kernel hands the body a null slot.  The guard
  # asks about the pointer before what it points at, so the body neither
  # reports nor stops there -- and does not fall over.
  def test_a_pasted_function_under_a_masked_cell_neither_reports_nor_stops
    values = [5, 0, 2]
    reference = values.each_with_index.map { |n, position|
      next nil if position == 1
      k = 0
      t = 0
      while k < 3
        t = 10 / n
        k += 1
      end
      k + t
    }
    output = run_isolated(<<~RUBY)
      f = CArray.jit_function("int64_t f(int64_t n)") { |n|
        k = 0
        t = 0
        while k < 3
          t = 10 / n
          k += 1
        end
        k + t
      }
      a = CArray.int64(3) { #{values.inspect} }
      a[1] = UNDEF
      out = CArray.int64(3)
      CArray.jit_each { out = f.call(a) }
      p out.is_masked.to_a
      p [out[0], out[2]]
    RUBY
    assert_equal("#{reference.map(&:nil?).inspect}\n" \
                 "#{[reference[0], reference[2]].inspect}\n", output)
  end

  # ---------- a kernel whose first report is inside the loop ----------

  WHILE_SOURCE = <<~RUBY
    ->(i) {
      k = 0
      found = 0.0
      while found >= 0.0
        found = a[k]
        k += 1
      end
      out[i] = k
    }
  RUBY

  def test_a_while_whose_body_reads_off_the_end_stops
    table = (1..5).map(&:to_f)
    expected = raised_by {
      3.times { k = 0; found = 0.0; while found >= 0.0; found = table.fetch(k); k += 1; end }
    }
    output = run_isolated(<<~RUBY)
      a = CArray.double(5).seq!(1.0)
      out = CArray.int64(3)
      begin
        CArray.jit_for(3) { |i|
          k = 0
          found = 0.0
          while found >= 0.0
            found = a[k]
            k += 1
          end
          out[i] = k
        }
        p :returned
      rescue StandardError => error
        p error.class
      end
    RUBY
    assert_equal("#{expected}\n", output)

    kernel = compile_kernel(WHILE_SOURCE,
                            arrays: { :a => "float64", :out => "int64" })
    assert_match(/while \(found >= 0\.0\) \{\n\s*if \( \*error \) break;\n/,
                 kernel.c_source)
  end

  # A scatter off the end writes nothing, so every cell the kernel leaves can
  # be held against the Ruby loop -- including the ones after the failing
  # pass, which a loop that kept going would have written.
  def test_an_inner_loop_whose_body_scatters_off_the_end_runs_no_later_pass
    positions = [0, 1, 9, 2, 3, 4]
    reference = [-1] * 5
    assert_raises(IndexError) do
      6.times { |k|
        raise IndexError, "outside" unless (0...5).cover?(positions[k])
        reference[positions[k]] = k
      }
    end
    output = run_isolated(<<~RUBY)
      index = CArray.int64(6) { #{positions.inspect} }
      out = CArray.int64(5) { -1 }
      begin
        CArray.jit_for(1) { |i|
          (0...6).each { |k| out[index[k]] = k + i }
        }
        p :returned
      rescue StandardError => error
        p error.class
      end
      p out.to_a
    RUBY
    assert_equal("IndexError\n#{reference.inspect}\n", output)
  end

  # ---------- the split reduction ----------

  REDUCTION_SOURCE = <<~RUBY
    ->(i) {
      acc = 0.0
      (0...16).each { |k| acc += a[index[k]] }
      out[i] = acc
    }
  RUBY

  def test_a_split_reduction_whose_term_reads_off_the_end_stops
    table = (1..8).map(&:to_f)
    positions = (0...16).to_a
    expected = raised_by {
      acc = 0.0
      16.times { |k| acc += table.fetch(positions[k]) }
    }
    output = run_isolated(<<~RUBY)
      a = CArray.double(8).seq!(1.0)
      index = CArray.int64(16).seq!
      out = CArray.double(2)
      begin
        CArray.jit_for(2) { |i|
          acc = 0.0
          (0...16).each { |k| acc += a[index[k]] }
          out[i] = acc
        }
        p :returned
      rescue StandardError => error
        p error.class
      end
    RUBY
    assert_equal("#{expected}\n", output)

    kernel = CArray::JIT.compile(REDUCTION_SOURCE,
                                 array_names: [:a, :index, :out],
                                 storage_types: { :a => "float64",
                                                  :index => "int64",
                                                  :out => "float64" },
                                 scalar_values: {}, reassociate: true)
    source = kernel.c_source
    assert_includes(source, "acc__p0")
    assert_match(/for \(; k__base \+ 8 <= k__end; k__base \+= 8\) \{\n\s*if \( \*error \) break;\n/,
                 source)
    assert_match(/for \(int64_t k = k__base; k < k__end; k\+\+\) \{\n\s*if \( \*error \) break;\n/,
                 source)
  end

end
