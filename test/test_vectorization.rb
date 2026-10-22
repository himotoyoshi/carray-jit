require_relative "test_helper"

# Whether the compiler vectorised the loop a kernel spends its time in.
#
# Nothing else in the suite can see this.  A kernel that loses its SIMD loop
# computes the same answer, a few times slower, and every other test still
# passes.  It happened: a kernel writing an int64 array was never vectorised,
# because the loop's limit was read out of `bounds` -- an `int64_t *`, like
# the array -- at every test, and the compiler could not tell that a store
# into the array left the limit alone.  float64 and int32 kernels were fine,
# which is why it went unseen.
#
# The compiler is asked rather than the machine code read: clang's
# `-Rpass=loop-vectorize` and gcc's `-fopt-info-vec-optimized` name the source
# line of each loop they vectorised.  The build's own flags are used; only the
# report is added.
#
# A kernel is compiled without the wrapper CArray's sweep calls.  The wrapper
# keeps `bounds` in an array of its own, so in the copy of the loop inlined
# there nothing can alias it, and that copy vectorises whatever the kernel
# does -- under the same source line.  With the wrapper in, the int64 kernel
# above was reported vectorised.  What is compiled here is the entry point
# Fiddle calls, which is handed `bounds` as a pointer.
#
# Reductions are left out.  Their split accumulators are vectorised by the
# SLP pass after the kernel is inlined into its caller, and the report then
# names the caller, not a line of the loop -- there is nothing to pin.
class TestVectorization < Minitest::Test

  include KernelCompilation

  REPORTS = {
    :clang => { :flags   => ["-Rpass=loop-vectorize"],
                :pattern => /:(\d+):\d+: remark: vectorized loop/ },
    :gcc   => { :flags   => ["-fopt-info-vec-optimized"],
                :pattern => /:(\d+):\d+: optimized: loop vectorized/ },
  }.freeze

  def self.compiler_kind
    return @compiler_kind if defined?(@compiler_kind)
    command = CArray::JIT::Compiler.compiler_command
    version = IO.popen([command, "--version"], err: [:child, :out]) { |io| io.read }
    @compiler_kind = case version
                     when /clang/i                            then :clang
                     when /\bgcc\b|Free Software Foundation/  then :gcc
                     end
  rescue SystemCallError
    @compiler_kind = nil
  end

  def setup
    @kind = self.class.compiler_kind
    unless @kind
      skip "#{CArray::JIT::Compiler.compiler_command} is neither clang nor gcc, " \
           "so there is no vectorisation report to read"
    end
  end

  # The source lines of the loops the compiler vectorised.
  def vectorized_lines (source, flags)
    report = REPORTS.fetch(@kind)
    Dir.mktmpdir("carray-jit-vectorization-") do |directory|
      path = File.join(directory, "kernel.c")
      File.write(path, source)
      command = [CArray::JIT::Compiler.compiler_command,
                 *(flags - ["-shared"]), "-c", path,
                 "-o", File.join(directory, "kernel.o"), *report[:flags]]
      output = IO.popen(command, err: [:child, :out]) { |io| io.read }
      assert $?.success?, "the kernel did not compile:\n#{output}"
      return output.scan(report[:pattern]).map { |(line)| line.to_i }
    end
  end

  # The line of the innermost loop in `function` -- the last `for` before the
  # function closes, which in generated code is the one that runs per cell.
  def innermost_loop_line (source, function)
    lines = source.lines
    first = lines.index { |line| line.start_with?("#{function} (") }
    refute_nil first, "the source defines no #{function}"
    last = (first...lines.size).find { |n| lines[n].start_with?("}") }
    loop_index = (first...last).select { |n| lines[n].include?("for (") }.last
    refute_nil loop_index, "#{function} has no loop"
    return loop_index + 1
  end

  def assert_vectorized (source, function, flags)
    line = innermost_loop_line(source, function)
    assert_includes vectorized_lines(source, flags), line,
                    "the loop at line #{line} of #{function} was not vectorised:\n" \
                    "#{source.lines[line - 1].strip}"
  end

  def assert_kernel_vectorized (body, arrays, scalars: {})
    kernel = compile_kernel(body, arrays: arrays, scalars: scalars)
    assert_vectorized(kernel.c_source, "carray_jit_contiguous",
                      CArray::JIT::Compiler::FLAGS)
  end

  # The sources an expression handed to Compiler.build, read off the build
  # for the length of the block rather than out of the evaluator.  Swapped in
  # and put back the way test_fast_path.rb counts builds.
  def expression_sources
    unless defined?(CArray::JIT::Expression)
      skip "this CArray does not carry the expression front end"
    end
    compiler = CArray::JIT::Compiler
    original = compiler.method(:build)
    sources = []
    compiler.define_singleton_method(:build) do |source, function_name, **options|
      sources << source if function_name == "carray_jit_expression"
      original.call(source, function_name, **options)
    end
    kept = CArray.expression_evaluator
    # A fresh evaluator holds no kernels, so every expression reaches the
    # build -- from the disk cache or not, the source goes through it.
    CArray.expression_evaluator = CArray::JIT::Expression.new
    yield
    return sources
  ensure
    CArray.expression_evaluator = kept
    if original
      compiler.singleton_class.send(:remove_method, :build)
      compiler.define_singleton_method(:build, original)
    end
  end

  # ---------- per-cell kernels ----------

  def test_four_terms
    assert_kernel_vectorized("->(i) { out[i] = a[i] + b[i] + c[i] + d[i] }",
                             { :out => "float64", :a => "float64", :b => "float64",
                               :c => "float64", :d => "float64" })
  end

  def test_float32_with_a_captured_scalar
    assert_kernel_vectorized("->(i) { out[i] = x * a[i] + b[i] }",
                             { :out => "float32", :a => "float32", :b => "float32" },
                             scalars: { :x => 2.5 })
  end

  def test_int32
    assert_kernel_vectorized("->(i) { out[i] = a[i] * 3 + b[i] }",
                             { :out => "int32", :a => "int32", :b => "int32" })
  end

  # The kernel that was not.  An add rather than `a[i] * 3`: arm64 has no
  # 64-bit vector multiply, so a multiply here would be a statement about the
  # machine rather than about the code generated.
  def test_int64
    assert_kernel_vectorized("->(i) { out[i] = a[i] + b[i] }",
                             { :out => "int64", :a => "int64", :b => "int64" })
  end

  def test_the_inner_axis_of_two
    assert_kernel_vectorized("->(i, j) { out[i, j] = a[i, j] + b[i, j] }",
                             { :out => "float64", :a => "float64", :b => "float64" })
  end

  def test_a_math_function
    assert_kernel_vectorized("->(i) { out[i] = Math.sqrt(a[i]) }",
                             { :out => "float64", :a => "float64" })
  end

  # The report has to be able to say no, or every test above passes for
  # nothing.  A recurrence reads the cell the last pass wrote and cannot be
  # vectorised by anybody.
  def test_a_recurrence_is_reported_as_not_vectorized
    kernel = compile_kernel("->(i) { a[i] = a[i-1] * 2.0 }",
                            arrays: { :a => "float64" })
    source = kernel.c_source
    line = innermost_loop_line(source, "carray_jit_contiguous")
    refute_includes vectorized_lines(source, CArray::JIT::Compiler::FLAGS), line
  end

  # ---------- expressions ----------

  def test_a_fused_expression
    a = CArray.float64(20_000) { 1.5 }
    b, c, d = a + 1.0, a + 2.0, a + 3.0
    sources = expression_sources { CArray.fuse { a + b + c + d }.to_ca }
    refute_empty sources, "the expression was not compiled"
    sources.each do |source|
      assert_vectorized(source, "carray_jit_expression", CArray::JIT::Expression::FLAGS)
    end
  end

  def test_a_fused_int64_expression
    a = CArray.int64(20_000) { 3 }
    b = a + 1
    sources = expression_sources { CArray.fuse { a + b + a }.to_ca }
    refute_empty sources, "the expression was not compiled"
    sources.each do |source|
      assert_vectorized(source, "carray_jit_expression", CArray::JIT::Expression::FLAGS)
    end
  end

end
