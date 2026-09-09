require_relative "test_helper"
require "fileutils"
require "tmpdir"

# A kernel can call a C function the block closed over.
#
# The reference throughout is `c_function.call`, which reaches the same function
# through Fiddle.  That is not a proxy for the right answer -- it *is* the
# same function, so agreement has to be exact, and these compare bitwise like
# the rest of the suite.
#
# What the tests are actually watching for is the seam between two facts that
# pull against each other: a kernel is compiled for a *signature*, so one
# kernel serves every function of that shape, while the address belongs to a
# particular function and can only come from the call.
class TestCFunction < Minitest::Test

  def setup
    @j0 = CArray.jit_extern("double j0(double)")
    @tgamma = CArray.jit_extern("double tgamma(double)")
    @atan2 = CArray.jit_extern("double atan2(double, double)")
  end

  # ---------- the call ----------

  def test_over_whole_arrays
    j0 = @j0
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    CArray.jit_each { out = j0.call(a) }
    assert_arrays_bits_equal(a.convert { |v| j0.call(v) }, out)
  end

  def test_at_a_named_index
    j0 = @j0
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    CArray.jit_for(6) { |i| out[i] = j0.call(a[i]) }
    assert_arrays_bits_equal(a.convert { |v| j0.call(v) }, out)
  end

  def test_two_arguments
    atan2 = @atan2
    a = CArray.double(5).seq!(1.0)
    b = CArray.double(5).seq!(0.5, 0.5)
    out = CArray.double(5)
    CArray.jit_for(5) { |i| out[i] = atan2.call(a[i], b[i]) }
    5.times { |i| assert_bits_equal(atan2.call(a[i], b[i]), out[i]) }
  end

  def test_mixed_into_an_expression
    j0 = @j0
    tgamma = @tgamma
    a = CArray.double(5).seq!(1.0)
    b = CArray.double(5).seq!(0.5, 0.5)
    out = CArray.double(5)
    CArray.jit_for(5) { |i| out[i] = 2.0 * j0.call(a[i]) + tgamma.call(b[i]) - a[i] }
    5.times do |i|
      assert_bits_equal(2.0 * j0.call(a[i]) + tgamma.call(b[i]) - a[i], out[i])
    end
  end

  # A stencil is the case that cannot be written as "apply f to an array": the
  # cell needs the function at two places at once, and there is no array of
  # intermediate results to hold them.
  def test_a_stencil
    j0 = @j0
    a = CArray.double(8).seq!(1.0)
    out = CArray.double(8)
    CArray.jit_for(1...8) { |i| out[i] = 0.5 * (j0.call(a[i]) + j0.call(a[i-1])) }
    (1...8).each do |i|
      assert_bits_equal(0.5 * (j0.call(a[i]) + j0.call(a[i-1])), out[i])
    end
  end

  def test_inside_a_reduction
    j0 = @j0
    source = CArray.double(3, 4).seq!(1.0)
    total = CArray.double(3)
    CArray.jit_for(3, reassociate: false) { |i|
      accumulator = 0.0
      (0...4).each { |j| accumulator = accumulator + j0.call(source[i, j]) }
      total[i] = accumulator
    }
    3.times do |i|
      expected = (0...4).inject(0.0) { |sum, j| sum + j0.call(source[i, j]) }
      assert_bits_equal(expected, total[i])
    end
  end

  # ---------- the three spellings ----------

  # `f.call(x)`, `f.(x)` -- which Prism also spells `call` -- and `f[x]`,
  # after Proc.  All three are real Ruby that would compute the same thing if
  # the block were run rather than compiled.
  def test_dot_call_bracket_and_dot_parentheses_agree
    j0 = @j0
    a = CArray.double(4).seq!(1.0)
    results = [
      CArray.double(4).tap { |out| CArray.jit_each { out = j0.call(a) } },
      CArray.double(4).tap { |out| CArray.jit_each { out = j0[a] } },
      CArray.double(4).tap { |out| CArray.jit_each { out = j0.(a) } },
    ]
    assert_arrays_bits_equal(results.first, results[1])
    assert_arrays_bits_equal(results.first, results[2])
    assert_arrays_bits_equal(a.convert { |v| j0.call(v) }, results.first)
  end

  # `f[x]` has to win over the array subscript it is spelled like, and only
  # because the captured name is known to hold a function rather than an array.
  def test_bracket_does_not_shadow_an_array_subscript
    j0 = @j0
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i| out[i] = j0[a[i]] }
    assert_arrays_bits_equal(a.convert { |v| j0.call(v) }, out)
  end

  # ---------- one kernel, many functions ----------

  # The kernel is keyed on the signature, so this block is compiled once; the
  # address has to arrive with the call, or every function after the first
  # would quietly compute the first one's answer.
  def test_one_kernel_serves_every_function_of_the_signature
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    apply = lambda { |f| CArray.jit_each { out = f.call(a) } }

    kernels = [@j0, @tgamma, CArray.jit_extern("double y0(double)")].map { |f|
      kernel = apply.call(f)
      assert_arrays_bits_equal(a.convert { |v| f.call(v) }, out)
      kernel
    }
    assert_equal(1, kernels.uniq.size,
                 "expected one compiled kernel for one signature")
  end

  def test_a_different_signature_is_a_different_kernel
    a = CArray.double(4).seq!(1.0)
    b = CArray.double(4).seq!(0.5, 0.5)
    out = CArray.double(4)
    j0 = @j0
    atan2 = @atan2
    first = CArray.jit_for(4) { |i| out[i] = j0.call(a[i]) }
    second = CArray.jit_for(4) { |i| out[i] = atan2.call(a[i], b[i]) }
    refute_same(first, second)
  end

  # ---------- masks ----------

  def test_a_masked_input_masks_the_output
    j0 = @j0
    a = CArray.double(6).seq!(1.0)
    a[2] = UNDEF
    out = CArray.double(6)
    CArray.jit_each { out = j0.call(a) }
    assert_equal([false, false, true, false, false, false], out.is_masked.to_a)
    [0, 1, 3, 4, 5].each { |i| assert_bits_equal(j0.call(a[i]), out[i]) }
  end

  # ---------- other types ----------

  def test_an_integer_function
    labs = CArray.jit_extern("long labs(long)")
    a = CArray.int64(5) { |i| (i - 2) * 7 }
    out = CArray.int64(5)
    CArray.jit_for(5) { |i| out[i] = labs.call(a[i]) }
    assert_equal([14, 7, 0, 7, 14], out.to_a)
  end

  def test_an_integer_argument_from_a_double_expression_is_the_C_conversion
    labs = CArray.jit_extern("long labs(long)")
    a = CArray.int64(3) { |i| -(i + 1) }
    out = CArray.int64(3)
    CArray.jit_for(3) { |i| out[i] = labs.call(a[i]) * 2 }
    assert_equal([2, 4, 6], out.to_a)
  end

  # ---------- the generated C ----------

  def test_the_function_arrives_as_an_address_not_by_linkage
    j0 = @j0
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    kernel = CArray.jit_each { out = j0.call(a) }
    assert_match(/typedef double \(\*j0_fn_t\)\(double\);/, kernel.c_source)
    assert_match(/const j0_fn_t j0 = \(j0_fn_t\) functions\[0\];/, kernel.c_source)
    refute_match(/\bextern\b/, kernel.c_source,
                 "a linked declaration would tie the kernel to one library")
  end

  # ---------- binding ----------

  def test_what_it_reports_about_itself
    assert_equal("double atan2(double, double)", @atan2.to_s)
    assert_equal(2, @atan2.arity)
    assert_equal(1, @j0.arity)
    refute_equal(@j0.signature, @atan2.signature)
    assert_equal(@j0.signature, @tgamma.signature)
  end

  def test_it_can_be_called_from_ruby
    assert_bits_equal(@j0.call(1.0), @j0[1.0])
    assert_in_delta(1.0, @tgamma.call(1.0), 0.0)
  end

  # `from:` also takes a handle the caller opened, which is how a gem that
  # already keeps one would pass it.
  def test_from_a_handle_the_caller_opened
    j0 = CArray.jit_extern("double j0(double)", from: Fiddle::Handle::DEFAULT)
    assert_bits_equal(@j0.call(2.0), j0.call(2.0))
  end

  # ---------- what is refused ----------

  def test_the_wrong_number_of_arguments
    j0 = @j0
    a = CArray.double(4).seq!(1.0)
    b = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| out[i] = j0.call(a[i], b[i]) }
    end
    assert_match(/`j0` is `double j0\(double\)`, so it takes 1 argument/, error.message)
    assert_match(/2 were given/, error.message)
  end

  def test_a_symbol_that_is_not_there
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_extern("double no_such_function_at_all(double)")
    end
    assert_match(/no_such_function_at_all/, error.message)
    assert_match(/from:/, error.message)
  end

  def test_something_that_is_not_a_prototype
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_extern("j0")
    end
    assert_match(/does not read as a C prototype/, error.message)
  end

  def test_a_prototype_that_is_not_a_string
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_extern(:j0)
    end
    assert_match(/a C prototype is expected/, error.message)
  end

  # A named prototype puts that name in the symbol, which is what a profiler
  # and a backtrace will show -- behind the prefix, for the reason below.
  def test_a_named_block_function_keeps_its_name
    f = CArray.jit_function("double squared(double)") { |x| x * x }
    assert_match(/\Acarray_jit_squared_[0-9a-f]{12}\z/, f.name.to_s)
    assert_match(/^double\ncarray_jit_squared_[0-9a-f]{12} \(double x\)$/,
                 f.c_source)
  end

  def test_a_library_that_is_not_one
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_extern("double j0(double)", from: 42)
    end
    assert_match(/takes a library name or a Fiddle::Handle/, error.message)
  end

  # A void return has no value to put in a cell, and a pointer is not one of
  # the types a kernel computes in.  Both are refused when the kernel reaches
  # them, naming the type rather than reinterpreting it.
  def test_a_return_type_a_cell_cannot_hold
    puts_fn = CArray.jit_extern("void free(void *)")
    a = CArray.double(3).seq!(1.0)
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| out[i] = puts_fn.call(a[i]) }
    end
    assert_match(/rather than a value a kernel can compute with/, error.message)
  end

  # ---------- a function written as a Ruby block ----------
  #
  # Same object, other constructor: the address comes from a compiled block
  # rather than a library symbol, and nothing downstream can tell.  What is
  # new here is that the block survives, so the two ways of computing it can
  # be put side by side -- which is the one place in this compiler where "the
  # C agrees with the Ruby" is checkable rather than argued.

  def test_a_block_compiles_to_a_function
    square = CArray.jit_function("double (*)(double)") { |x| x * x + 1 }
    assert_bits_equal(10.0, square.call(3.0))
    assert_predicate(square, :compiled?)
  end

  def test_the_compiled_c_agrees_with_the_block_run_in_ruby
    smooth = CArray.jit_function("double (*)(double)") { |x|
      t = x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x)
      t * t * (3.0 - 2.0 * t)
    }
    [-0.5, 0.0, 0.25, 0.5, 0.75, 1.0, 2.0].each do |v|
      assert_bits_equal(smooth.block.call(v), smooth.call(v),
                        "at #{v}: the compiled C and the block disagree")
    end
  end

  def test_it_is_called_from_a_kernel_like_any_other
    square = CArray.jit_function("double (*)(double)") { |x| x * x + 1 }
    a = CArray.double(5).seq!(1.0)
    out = CArray.double(5)
    CArray.jit_each { out = square.call(a) }
    assert_arrays_bits_equal(a.convert { |v| square.block.call(v) }, out)
  end

  def test_two_parameters
    hypot = CArray.jit_function("double (*)(double, double)") { |x, y|
      Math.sqrt(x * x + y * y)
    }
    assert_bits_equal(5.0, hypot.call(3.0, 4.0))
  end

  def test_integers
    step = CArray.jit_function("long long (*)(long long)") { |n| n * 2 + 1 }
    assert_equal(41, step.call(20))
  end

  # The return type is stated, not derived, so it is the declaration that
  # decides where the value is narrowed -- here on the way out, after the
  # arithmetic was done in double.
  def test_the_declared_return_type_is_what_comes_back
    third = CArray.jit_function("float (*)(double)") { |x| x / 3.0 }
    assert_bits_equal([1.0 / 3.0].pack("f").unpack1("f"), third.call(1.0))
    refute_equal(1.0 / 3.0, third.call(1.0))
  end

  def test_the_same_block_is_compiled_once
    first = CArray.jit_function("double (*)(double)") { |x| x * 7.0 }
    second = CArray.jit_function("double (*)(double)") { |x| x * 7.0 }
    assert_same(first, second)
  end

  # A borrowed function reaches the kernel as an address, so the signature
  # settles which kernel it is.  One written here does not stop there: its
  # body is on its way into the kernel's own translation unit, and two bodies
  # declared the same way have to be two kernels -- sharing one would hand the
  # second function the first one's answer, without saying anything.
  def test_two_bodies_of_one_signature_are_two_kernels
    twice = CArray.jit_function("double (*)(double)") { |x| x * 2.0 }
    thrice = CArray.jit_function("double (*)(double)") { |x| x * 3.0 }
    assert_equal(twice.signature, thrice.signature)

    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    # One block, so the source is the same text and only the function differs
    # -- which is what puts the two on the same cache key but for the body.
    apply = lambda { |f| CArray.jit_each { out = f.call(a) } }
    first = apply.call(twice)
    assert_arrays_bits_equal(a * 2.0, out)
    second = apply.call(thrice)
    assert_arrays_bits_equal(a * 3.0, out)

    refute_equal(first.object_id, second.object_id,
                 "one kernel for two bodies would compute the wrong one")
  end

  # The same body, though, is the same function and so the same kernel: the
  # digest is of the text, not of the object.
  def test_the_same_body_is_the_same_kernel
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    kernels = 2.times.map {
      f = CArray.jit_function("double (*)(double)") { |x| x * 11.0 }
      CArray.jit_each { out = f.call(a) }
    }
    assert_equal(kernels.first.object_id, kernels.last.object_id)
  end

  # ---------- pasted into the kernel ----------

  # A body written here is put in the kernel's own C as a static and called by
  # its symbol.  Through a pointer the compiler cannot see the body, so it can
  # neither inline the call nor vectorise the loop around it; pasted, the
  # kernel is the one it would have been had the expression been written where
  # it is called.
  def test_a_written_function_is_pasted_into_the_kernel
    square = CArray.jit_function("double (*)(double)") { |x| x * x + 1 }
    a = CArray.double(5).seq!(1.0)
    out = CArray.double(5)
    kernel = CArray.jit_each { out = square.call(a) }
    assert_arrays_bits_equal(a.convert { |v| square.block.call(v) }, out)

    assert_match(/^static double\n#{square.name} \(double x\)$/, kernel.c_source)
    assert_match(/#{square.name}\(/, kernel.c_source, "called by its symbol")
    refute_match(/_fn_t/, kernel.c_source,
                 "a pasted body needs no pointer typedef")
    refute_match(/functions\[/, kernel.c_source,
                 "and takes no slot in the functions buffer")
  end

  # The two kinds side by side: the borrowed one still arrives as an address,
  # and it is the first of them -- so the slots are counted over the addressed
  # functions alone, not over every function the block named.
  def test_a_pasted_body_takes_no_slot_from_a_borrowed_one
    square = CArray.jit_function("double (*)(double)") { |x| x * x + 1 }
    j0 = @j0
    a = CArray.double(5).seq!(1.0)
    out = CArray.double(5)
    kernel = CArray.jit_each { out = square.call(a) + j0.call(a) }
    assert_arrays_bits_equal(
      a.convert { |v| square.block.call(v) + j0.call(v) }, out)
    assert_match(/const j0_fn_t j0 = \(j0_fn_t\) functions\[0\];/, kernel.c_source)
  end

  # One function, two names in the block.  The symbol carries the digest of
  # the body, so the two names are the one function and it is pasted once --
  # a second definition of that symbol would not compile.
  def test_one_body_reached_by_two_names_is_pasted_once
    square = CArray.jit_function("double (*)(double)") { |x| x * x + 1 }
    twin = square
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    kernel = CArray.jit_for(4) { |i| out[i] = square.call(a[i]) + twin.call(a[i]) }
    assert_arrays_bits_equal(a.convert { |v| 2 * square.block.call(v) }, out)
    assert_equal(1, kernel.c_source.scan(/^static double\n#{square.name} /).size)
  end

  # A body that can report a failure is pasted too, with the flag as its last
  # parameter: standing alone it reports into the one in its own object, and
  # `#call` reads that, but pasted there is no such object around it and the
  # failure is the running kernel's.
  def test_a_body_that_can_fail_reports_into_the_kernels_slot
    divide = CArray.jit_function("long long (*)(long long)") { |n| 100 / n }
    assert_predicate(divide, :pasted?)
    assert_predicate(divide, :pasted_takes_error?)

    a = CArray.int64(4).seq!(1)
    out = CArray.int64(4)
    kernel = CArray.jit_each { out = divide.call(a) }
    assert_equal([100, 50, 33, 25], out.to_a)
    assert_match(/#{divide.name} \(long long n, int32_t \*carray_jit_error\)/,
                 kernel.c_source)
    refute_match(/functions\[/, kernel.c_source)
  end

  # The same body, called both ways, raises the same thing.  That is the
  # point of handing it the kernel's slot rather than leaving it to write
  # into a flag nobody is reading.
  def test_a_division_with_no_divisor_raises_from_either_side
    divide = CArray.jit_function("long long (*)(long long)") { |n| 100 / n }
    assert_raises(ZeroDivisionError) { divide.call(0) }

    a = CArray.int64(3).seq!(0)
    out = CArray.int64(3)
    assert_raises(ZeroDivisionError) { CArray.jit_each { out = divide.call(a) } }
  end

  # Null under a masked cell, as the kernel's own helpers are handed: the
  # bytes there are out of contract, so a zero that only ever feeds a masked
  # cell is not a division by zero anybody asked about.
  def test_a_failure_under_a_masked_cell_is_not_reported
    divide = CArray.jit_function("long long (*)(long long)") { |n| 100 / n }
    a = CArray.int64(4).seq!(0)
    a[0] = UNDEF
    out = CArray.int64(4)
    CArray.jit_each { out = divide.call(a) }
    assert_equal([true, false, false, false], out.is_masked.to_a)
    assert_equal([100, 50, 33], out[1..3].to_a)
  end

  # A function that calls itself passes the slot down, so a failure deep in
  # the recursion is the one the kernel reports.
  def test_a_recursive_body_passes_the_slot_down
    walk = CArray.jit_function("long long walk(long long n)") { |n|
      n <= 0 ? 0 : (100 / n) + walk.call(n - 1)
    }
    a = CArray.int64(4).seq!(1)
    out = CArray.int64(4)
    kernel = CArray.jit_each { out = walk.call(a) }
    assert_equal([100, 150, 183, 208], out.to_a)
    assert_match(/#{walk.name}\(n - INT64_C\(1\), carray_jit_error\)/,
                 kernel.c_source)
  end

  # A helper the body used comes with it: the pasted definition is in the
  # kernel's translation unit now, and calls what it called before.
  def test_a_pasted_body_brings_its_helpers
    power = CArray.jit_function("long long (*)(long long)") { |n| n ** 3 }
    a = CArray.int64(4).seq!(1)
    out = CArray.int64(4)
    kernel = CArray.jit_each { out = power.call(a) }
    assert_equal([1, 8, 27, 64], out.to_a)
    assert_match(/carray_jit_integer_power \(int64_t base/, kernel.c_source)
  end

  def test_it_carries_its_c_and_its_origin
    square = CArray.jit_function("double (*)(double)") { |x| x * x + 1 }
    assert_match(/^double\ncarray_jit_function_[0-9a-f]{12} \(double x\)$/,
                 square.c_source)
    assert_match(/^  return .+;$/, square.c_source)
    assert_match(/test_c_function.rb:\d+/, square.to_s)
  end

  # ---------- what a compiled function may not reach ----------
  #
  # Its parameters are its whole surface, with one exception: a function
  # compiled here, which is pasted rather than captured and whose symbol is
  # in the cache key beside the body's text.  Everything else would put
  # something in the compiled object that the key covers nothing of -- an
  # object built for one capture handed back for another.  The kernel path
  # passes captures in buffers at call time; a C function has no buffers,
  # which is also why a borrowed function, being only an address, stays out.

  def test_it_may_not_close_over_a_value
    scale = 2.0
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double (*)(double)") { |x| x * scale }
    end
    assert_match(/reaches `scale`, which is a value outside it/, error.message)
  end

  def test_it_may_not_close_over_an_array
    a = CArray.double(3).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double (*)(double)") { |x| x + a[0] }
    end
    assert_match(/reaches `a`, which is an array outside it/, error.message)
  end

  def test_it_may_not_close_over_a_borrowed_function
    j0 = @j0
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double (*)(double)") { |x| j0.call(x) + 1.0 }
    end
    assert_match(/reaches `j0`, which was bound with `jit_extern`/,
                 error.message)
  end

  # ---------- one compiled function calling another ----------

  def test_a_body_calls_a_function_compiled_here
    square = CArray.jit_function("double square(double)") { |x| x * x }
    plus = CArray.jit_function("double (*)(double)") { |x| square.call(x) + 1.0 }
    assert_equal(10.0, plus.call(3.0))
  end

  # The body is pasted, not reached through a pointer: that is what a
  # compiler can see through, and it is what the kernel path already does
  # with a function written here.
  def test_the_called_body_is_pasted_into_the_caller
    twice = CArray.jit_function("double twice(double)") { |x| x + x }
    outer = CArray.jit_function("double (*)(double)") { |x| twice.call(x) }
    assert_match(/^static double\n#{twice.name}/, outer.c_source)
    assert_match(/return #{twice.name}\(x\);/, outer.c_source)
  end

  # The reason the capture is allowed at all: the callee's symbol is in the
  # key, so two blocks spelled the same that call different functions are
  # two functions.  Without it the first compiled would answer for both.
  def test_two_bodies_spelled_the_same_calling_different_functions_differ
    square = CArray.jit_function("double square(double)") { |x| x * x }
    cube = CArray.jit_function("double cube(double)") { |x| x * x * x }
    wrap = lambda { |g|
      CArray.jit_function("double (*)(double)") { |x| g.call(x) + 1.0 }
    }
    assert_equal(5.0, wrap.call(square).call(2.0))
    assert_equal(9.0, wrap.call(cube).call(2.0))
  end

  def test_the_same_body_calling_the_same_function_is_compiled_once
    square = CArray.jit_function("double square(double)") { |x| x * x }
    wrap = lambda { |g|
      CArray.jit_function("double (*)(double)") { |x| g.call(x) + 1.0 }
    }
    assert_same(wrap.call(square), wrap.call(square))
  end

  # A failure travels up the chain the way it travels out of one body: the
  # called definition takes the caller's error slot, whatever depth it is at.
  def test_a_raise_in_a_called_body_reaches_the_outermost_caller
    root = CArray.jit_function("double root(double)") { |x|
      raise "no square root of a negative" if x < 0
      Math.sqrt(x)
    }
    hyp = CArray.jit_function("double hyp(double a, double b)") { |a, b|
      root.call(a * a + b * b)
    }
    outer = CArray.jit_function("double (*)(double, double)") { |a, b|
      hyp.call(a, b) / 2
    }
    assert_equal(2.5, outer.call(3.0, 4.0))
    error = assert_raises(RuntimeError) { root.call(-1.0) }
    assert_equal("no square root of a negative", error.message)
  end

  # And a kernel that pastes the outer one has to paste what that one calls,
  # or the symbol it reaches is in no translation unit.
  def test_a_kernel_pastes_the_whole_chain
    half = CArray.jit_function("double half(double)") { |x| x / 2 }
    quarter = CArray.jit_function("double (*)(double)") { |x|
      half.call(half.call(x))
    }
    a = CArray.double(3).seq!(4.0, 4.0)
    assert_equal(CArray.double(3) { |i| (i + 1) }, CArray.jit_map { quarter.call(a) })
  end

  def test_a_body_calls_another_beside_calling_itself
    half = CArray.jit_function("double half(double)") { |x| x / 2 }
    down = CArray.jit_function("double down(double n)") { |n|
      n < 1 ? n : down.call(half.call(n))
    }
    assert_equal(0.5, down.call(8.0))
  end

  # ---------- what the declaration must say ----------

  def test_the_signature_and_the_block_must_agree_on_the_count
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double (*)(double)") { |x, y| x + y }
    end
    assert_match(/names 1 parameter, and the block takes 2/, error.message)
  end

  def test_an_anonymous_prototype_names_nothing_to_find
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_extern("double (*)(double)")
    end
    assert_match(/names no function to find/, error.message)
    assert_match(/CArray\.jit_function/, error.message, "says where the body goes")
  end

  # C's integer types have exact-width names and its floating types do not,
  # so `uint16_t` reads and `float64_t` does not.  That asymmetry is C's, not
  # this compiler's, which is the point of taking C's spellings.
  def test_the_exact_width_integer_names_read
    f = CArray.jit_function("int32_t (*)(uint16_t)") { |n| n * 2 }
    assert_equal(600, f.call(300))
    assert_match(/int32_t .*\(uint16_t\)/, f.to_s)
  end

  def test_a_type_c_does_not_have
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("float64_t (*)(double)") { |x| x }
    end
    assert_match(/float64_t/, error.message)
  end

  # Fiddle reports `long double` as `long`, silently, so it is refused rather
  # than trusted at the wrong width.
  def test_a_type_fiddle_would_get_wrong
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("long double (*)(double)") { |x| x }
    end
    assert_match(/long double/, error.message)
  end

  # Splitting the two spellings retired this pair of errors: a compiled
  # function has no library to be found in, and a found one has no body to
  # compile, so neither method has the other's parameter to refuse.
  def test_a_compiled_function_has_no_library_to_name
    assert_raises(ArgumentError) do
      CArray.jit_function("double (*)(double)", from: "libm") { |x| x }
    end
  end

  def test_a_found_function_has_no_body_to_give
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_extern("double j0(double)") { |x| x }
    end
    assert_match(/a body here would be dropped/, error.message)
  end

  def test_a_compiled_function_needs_its_body
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double (*)(double)")
    end
    assert_match(/compiled from a block, and none was given/, error.message)
    assert_match(/CArray\.jit_extern/, error.message, "says where to find one")
  end

  # ---------- a slot the ABI requires ----------
  #
  # `gsl_function` is `double (*)(double x, void *params)`, and the second
  # half is not optional however little a function does with it.  `:pointer`
  # is a parameter that exists for the signature's sake: it takes a place in
  # the C, and the body may not read it.

  def test_a_pointer_slot_takes_its_place_in_the_signature
    f = CArray.jit_function("double (*)(double, void *)") { |x, params| x * x }
    assert_match(/\(double x, void \* params\)/, f.c_source)
    assert_bits_equal(9.0, f.call(3.0, nil))
  end

  def test_the_body_may_not_read_a_pointer_slot
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double (*)(double, void *)") { |x, params| x + params }
    end
    assert_match(/`params` is declared `void \*`/, error.message)
    assert_match(/the body cannot read it/, error.message)
  end

  # The point of the slot, checked the only way that means anything: a C
  # driver that takes a gsl_function-shaped pointer and calls it.
  def test_the_pointer_is_callable_at_that_abi
    square = CArray.jit_function("double (*)(double, void *)") { |x, params| x * x }
    driver = Dir.mktmpdir("carray-jit-abi-")
    begin
      source = File.join(driver, "driver.c")
      object = File.join(driver, "driver#{RbConfig::CONFIG['DLEXT'].then { |e| ".#{e}" }}")
      File.write(source, <<~C)
        struct gsl_function {
          double (*function)(double x, void *params);
          void *params;
        };
        double trapezoid (struct gsl_function *f, double a, double b, int n)
        {
          double h = (b - a) / n;
          double sum = 0.5 * (f->function(a, f->params) + f->function(b, f->params));
          int k;
          for (k = 1; k < n; k++) sum += f->function(a + k * h, f->params);
          return sum * h;
        }
      C
      command = [CArray::JIT::Compiler.compiler_command,
                 "-O2", "-fPIC", "-shared", source, "-o", object]
      skip "no working C compiler" unless system(*command, out: File::NULL,
                                                 err: File::NULL)
      handle = Fiddle::Handle.new(object)
      trapezoid = Fiddle::Function.new(
        handle["trapezoid"],
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE,
         Fiddle::TYPE_INT], Fiddle::TYPE_DOUBLE)
      gsl_function = [square.pointer.to_i, 0].pack("Q2")
      answer = trapezoid.call(Fiddle::Pointer[gsl_function], 0.0, 1.0, 100_000)
      assert_in_delta(1.0 / 3.0, answer, 1e-9)
    ensure
      FileUtils.remove_entry(driver)
    end
  end

  # Nothing in the compiled object comes from the Ruby process: it references
  # no Ruby symbol, which is why the address is safe to call from a thread
  # holding no GVL.  Checked against the object rather than argued.
  def test_the_compiled_object_references_nothing_of_rubys
    square = CArray.jit_function("double (*)(double)") { |x| x * x + 1 }
    refute_match(/rb_|ruby|VALUE/, square.c_source)
    assert_match(/\A#include <stdint\.h>/, square.c_source.sub(/\A\/\*.*?\*\/\n\n/m, ""))
  end

  # Two functions that differ only in their body get different symbols, so a
  # profiler or a backtrace can tell which one is running.
  def test_each_compiled_function_has_its_own_symbol
    first = CArray.jit_function("double (*)(double)") { |x| x + 1.0 }
    second = CArray.jit_function("double (*)(double)") { |x| x + 2.0 }
    refute_equal(first.name, second.name)
    assert_match(/\Acarray_jit_function_[0-9a-f]{12}\z/, first.name.to_s)
  end

  # ---------- the symbol never takes a name C already knows ----------

  # The dangerous case is the one that does not fail.  `double sin(double)`
  # matches math.h's declaration, so a file defining it compiles cleanly and
  # the shared object exports libm's `sin` -- where symbols are interposable
  # that replaces sine for whatever loads it next.  A mismatched signature is
  # a compile error and would have been noticed; this would not.
  def test_a_name_the_c_library_already_has
    f = CArray.jit_function("double sin(double)") { |x| x * x }
    assert_bits_equal(9.0, f.call(3.0))
    assert_match(/\Acarray_jit_sin_[0-9a-f]{12}\z/, f.name.to_s)
    refute_match(/^sin \(/, f.c_source)
  end

  def test_every_symbol_is_behind_the_prefix
    named = CArray.jit_function("double squared(double)") { |x| x * x }
    anonymous = CArray.jit_function("double (*)(double)") { |x| x * x * x }
    assert_match(/\Acarray_jit_squared_[0-9a-f]{12}\z/, named.name.to_s)
    assert_match(/\Acarray_jit_function_[0-9a-f]{12}\z/, anonymous.name.to_s)
  end

  # ---------- an array parameter keeps what C wrote about it ----------
  #
  # A subscript in this compiler has always had an extent behind it, which is
  # what lets a kernel be checked.  A bare pointer has none.  C's declarator
  # can carry the length, so the checked and unchecked cases are both
  # sayable, and the difference between them is C's rather than invented --
  # which is what the eventual reading of `const double coef[3]` will rest on.
  def test_a_sized_array_parameter_keeps_its_size
    f = CArray.jit_function("double (*)(double, const double coef[3])") { |x, c| x }
    parameter = f.parameters.last
    assert_equal(3, parameter.array)
    assert_predicate(parameter, :sized?)
    assert_equal("const double [3]", parameter.text)
    # the block's parameter names are the C parameter names; the prototype's
    # own names are documentation and are dropped
    assert_match(/\(double x, const double c\[3\]\)/, f.c_source)
  end

  def test_an_unsized_array_parameter_says_so
    f = CArray.jit_function("double (*)(double, const double y[])") { |x, y| x }
    parameter = f.parameters.last
    assert_equal(:unsized, parameter.array)
    refute_predicate(parameter, :sized?)
    assert_equal("const double []", parameter.text)
  end

  # An array parameter is a pointer at the ABI whatever its declarator says,
  # and like any pointer it is a slot rather than a value -- for now.
  def test_an_array_parameter_is_a_slot_for_now
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double (*)(double, const double c[3])") { |x, c| c }
    end
    assert_match(/`c` is declared `const double \[3\]`/, error.message)
  end

  # The whole ODE prototype reads, even though its array parameters are not
  # yet readable: what a signature may say and what a body may do with it are
  # separate questions.
  def test_an_ode_prototype_reads
    name, return_type, parameters = CArray::JIT::CDeclaration.parse(
      "int f(double t, const double y[], double dydt[], void *params)")
    assert_equal("f", name)
    assert_equal("int", return_type.text)
    assert_equal(["double", "const double []", "double []", "void *"],
                 parameters.map(&:text))
  end

  # ---------- dividing by zero ----------

  # A kernel is handed a place to report through and a compiled function is
  # not, having only the signature its declaration gave it.  So the object
  # carries one of its own, and a call from Ruby raises what the same
  # expression raises in Ruby -- and what the kernel raises for it.
  def test_integer_division_in_a_compiled_function
    quotient = CArray.jit_function("int q(int a, int b)") { |a, b| a / b }
    remainder = CArray.jit_function("int r(int a, int b)") { |a, b| a % b }
    assert_equal(2, quotient.call(7, 3))
    assert_equal(1, remainder.call(7, 3))
    assert_equal(quotient.block.call(7, 3), quotient.call(7, 3))
    assert_equal(remainder.block.call(7, 3), remainder.call(7, 3))
  end

  def test_dividing_by_zero_raises_what_ruby_raises
    remainder = CArray.jit_function("int r(int a, int b)") { |a, b| a % b }
    assert_raises(ZeroDivisionError) { remainder.call(7, 0) }
    assert_raises(ZeroDivisionError) { remainder.block.call(7, 0) }
  end

  # Ruby floors `%` with its division and C truncates, and the compiled body
  # follows Ruby, as the kernel does.
  def test_the_remainder_follows_ruby_not_c
    remainder = CArray.jit_function("int r(int a, int b)") { |a, b| a % b }
    [[7, 3], [-7, 3], [7, -3], [-7, -3]].each do |a, b|
      assert_equal(a % b, remainder.call(a, b), "#{a} % #{b}")
    end
  end

  # The flag does not stand between calls, so one bad call does not spoil
  # the next.
  def test_the_error_does_not_carry_to_the_next_call
    remainder = CArray.jit_function("int r(int a, int b)") { |a, b| a % b }
    assert_raises(ZeroDivisionError) { remainder.call(7, 0) }
    assert_equal(1, remainder.call(7, 3))
  end

  # A body that cannot divide by zero carries no flag at all, and pays
  # nothing for one.
  def test_a_body_that_cannot_fail_carries_no_flag
    plain = CArray.jit_function("double p(double a, double b)") { |a, b| a * b }
    refute_includes(plain.c_source, "carray_jit_error")
    float = CArray.jit_function("double d(double a, double b)") { |a, b| a / b }
    refute_includes(float.c_source, "carray_jit_error",
                    "a float division is an infinity, not an error")
    assert_predicate(float.call(1.0, 0.0), :infinite?)
  end

  def test_a_recursive_function_may_divide
    gcd = CArray.jit_function("int gcd(int a, int b)") { |a, b|
      b == 0 ? a : gcd.call(b, a % b)
    }
    assert_equal(6, gcd.call(48, 18))
    assert_equal(6, gcd.block.call(48, 18))
    assert_equal(48, gcd.call(48, 0), "the body guards its own zero")
  end

  # ---------- calling itself ----------

  # C puts a declarator's name in scope inside the body it heads, so a named
  # declaration can call itself.  The spelling is `.call`, the one every C
  # function takes here, which keeps the block runnable in Ruby.
  def test_a_named_function_calls_itself
    fact = CArray.jit_function("double fact(double)") { |n|
      n <= 1.0 ? 1.0 : n * fact.call(n - 1.0)
    }
    assert_equal(120.0, fact.call(5.0))
    assert_equal(120.0, fact.block.call(5.0), "and the block still runs")
  end

  # The name in the block is a spelling; the symbol is qualified and carries
  # the digest, so the call cannot reach anything else answering to `fact`.
  def test_the_recursive_call_goes_to_the_qualified_symbol
    fact = CArray.jit_function("double fact(double)") { |n|
      n <= 1.0 ? 1.0 : n * fact.call(n - 1.0)
    }
    symbol = fact.name.to_s
    assert_match(/\Acarray_jit_fact_[0-9a-f]{12}\z/, symbol)
    body = fact.c_source.split("*/", 2).last
    assert_includes(body, "#{symbol}(n - 1.0)")
    refute_match(/[^_a-z]fact\(/, body, "never the bare name")
  end

  def test_two_recursive_calls_in_one_body
    fib = CArray.jit_function("double fib(double)") { |n|
      n < 2.0 ? n : fib.call(n - 1.0) + fib.call(n - 2.0)
    }
    assert_equal(6765.0, fib.call(20.0))
    assert_equal(6765.0, fib.block.call(20.0))
  end

  def test_a_recursive_function_is_called_from_a_kernel
    fib = CArray.jit_function("double fib(double)") { |n|
      n < 2.0 ? n : fib.call(n - 1.0) + fib.call(n - 2.0)
    }
    values = CArray.double(8).seq!(0.0)
    out = CArray.double(8)
    CArray.jit_each { out = fib.call(values) }
    assert_equal([0.0, 1.0, 1.0, 2.0, 3.0, 5.0, 8.0, 13.0], out.to_a)
  end

  # A function's own pointer parameter is already the address the callee
  # wants, so handing it on is what C does.
  def test_recursion_carries_an_array_parameter
    total = CArray.jit_function("double total(int n, const double v[8])") { |n, v|
      n == 0 ? 0.0 : v[n - 1] + total.call(n - 1, v)
    }
    values = CArray.double(8).seq!(1.0)
    assert_equal(36.0, total.call(8, values))
    assert_equal(36.0, total.block.call(8, values))
  end

  # A bare `fact(...)` reads better as C and is not Ruby, so the block it
  # was written in could never be run beside the compiled function.
  def test_the_bare_spelling_is_refused
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double fact(double)") { |n|
        n <= 1.0 ? 1.0 : n * fact(n - 1.0)
      }
    end
    assert_match(/as `fact\.call\(\.\.\.\)`/, error.message)
    assert_match(/has to stay runnable/, error.message)
  end

  # An anonymous declaration has no name to call itself by, which is C's
  # position too: a function pointer type names nothing.
  def test_an_anonymous_function_has_nothing_to_recurse_through
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double (*)(double)") { |n|
        n <= 1.0 ? 1.0 : n * fact.call(n - 1.0)
      }
    end
    assert_match(/reaches `fact`, which is a value outside it/, error.message)
  end

  def test_a_recursive_call_is_checked_against_the_declaration
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double fact(double)") { |n| fact.call(n, n) }
    end
    assert_match(/`fact` takes 1 argument; 2 were given/, error.message)
  end

  # ---------- the two shapes that have nothing to do ----------

  def test_an_anonymous_prototype_cannot_be_found
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_extern("double (*)(double)", from: "libm")
    end
    assert_match(/names no function to find/, error.message)
  end

  # `void` is a return type a body may have: the work is through the pointer
  # parameters, and C says so with the word.  What it may not do is stand
  # where a value is wanted.
  def test_a_block_may_return_void
    fill = CArray.jit_function("void fill(double out[], double value)") { |out, value|
      out[0] = value
      out[1] = value * 2.0
    }
    buffer = CArray.double(2)
    assert_nil(fill.call(buffer, 7.5))
    assert_equal([7.5, 15.0], buffer.to_a)
    assert_match(/^void\ncarray_jit_fill_[0-9a-f]+ \(double out\[\], double value\)$/,
                 fill.c_source)
    refute_match(/return /, fill.c_source)
  end

  # Every statement in it is a statement, this being the whole of what `void`
  # changes, so the last line of a void body has to do something.
  def test_a_void_body_ends_in_a_statement_like_any_other
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("void (*)(double)") { |x| x * 2.0 }
    end
    assert_match(/a kernel body holds assignments/, error.message)
  end

  def test_a_void_function_is_not_a_value
    fill = CArray.jit_function("void fill(double out[], double value)") { |out, value|
      out[0] = value
    }
    buffer = CArray.double(1)
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| out[i] = fill.call(buffer, i * 1.0) }
    end
    assert_match(/`fill` returns `void`/, error.message)
    assert_match(/rather than a value a kernel can compute with/, error.message)
  end

  # A pointer return is refused as it was: there is nothing in a body to take
  # the address of that would outlive the call.
  def test_a_block_cannot_return_a_pointer
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double *(*)(double)") { |x| x * 2.0 }
    end
    assert_match(/no value a compiled body can produce/, error.message)
  end

  # ---------- reading and writing through a pointer parameter ----------
  #
  # This is what replaces capturing.  A compiled function may reach nothing
  # outside its parameters, so coefficients arrive as a parameter -- which is
  # what C does anyway, and C's declarator already says everything needed:
  # `const` is the read/write distinction, and a length is a length.

  def test_a_const_pointer_is_read_by_subscript
    poly = CArray.jit_function("double (*)(double x, const double coef[3])") { |x, c|
      c[0] + c[1] * x + c[2] * x * x
    }
    coef = CArray.double(3) { |i| [1.0, 2.0, 3.0][i] }
    assert_bits_equal(17.0, poly.call(2.0, coef))
    assert_match(/const double c\[3\]/, poly.c_source)
  end

  # The property the block was kept for, now that a parameter can be a run of
  # numbers: `coef[0]` means the same to a CArray as to a C pointer, so the
  # body agrees with itself whichever way it is run, unchanged.
  def test_the_compiled_c_agrees_with_the_block_through_a_pointer
    poly = CArray.jit_function("double (*)(double x, const double coef[3])") { |x, c|
      c[0] + c[1] * x + c[2] * x * x
    }
    coef = CArray.double(3) { |i| [0.5, -1.25, 2.0][i] }
    [-2.0, 0.0, 0.5, 3.0].each do |x|
      assert_bits_equal(poly.block.call(x, coef), poly.call(x, coef),
                        "at #{x}: the compiled C and the block disagree")
    end
  end

  # `const double y[]` reads and `double dydt[]` writes -- the whole ODE
  # signature, with no spelling invented for either half.
  def test_a_writable_pointer_is_written_through
    ode = CArray.jit_function(
      "int (*)(double t, const double y[2], double dydt[2], void *params)"
    ) { |t, y, dydt, params|
      dydt[0] = y[1]
      dydt[1] = -y[0]
      0
    }
    y = CArray.double(2) { |i| [1.0, 0.0][i] }
    dydt = CArray.double(2)
    assert_equal(0, ode.call(0.0, y, dydt, nil))
    assert_equal([0.0, -1.0], dydt.to_a)

    in_ruby = CArray.double(2)
    assert_equal(0, ode.block.call(0.0, y, in_ruby, nil))
    assert_equal(dydt.to_a, in_ruby.to_a)
  end

  # A pointer is walked contiguously, so a view is packed for the call and
  # copied back if the C may have written to it.  Getting this wrong is
  # silent: handing the C a view's base pointer to walk contiguously writes
  # over the cells beside it.
  def test_a_view_is_packed_and_written_back
    ode = CArray.jit_function("int (*)(const double y[2], double out[2])") { |y, out|
      out[0] = y[1]
      out[1] = -y[0]
      0
    }
    grid = CArray.double(2, 2).seq
    y = CArray.double(2) { |i| [1.0, 0.0][i] }
    ode.call(y, grid[nil, 1])
    assert_equal([[0.0, 0.0], [2.0, -1.0]], grid.to_a,
                 "the write landed outside the view")
  end

  def test_a_view_as_a_const_pointer_is_read_in_place
    sum = CArray.jit_function("double (*)(const double c[2])") { |c| c[0] + c[1] }
    grid = CArray.double(2, 2).seq
    assert_bits_equal(4.0, sum.call(grid[nil, 1]))
    assert_equal([[0.0, 1.0], [2.0, 3.0]], grid.to_a, "reading changed the array")
  end

  # ---------- what a pointer parameter refuses ----------

  def test_writing_through_a_const_pointer
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double (*)(const double c[2])") { |c| c[0] = 1.0; c[1] }
    end
    assert_match(/declared const, so the function may read it but not write/,
                 error.message)
  end

  def test_a_pointer_read_without_a_subscript
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double (*)(const double c[2])") { |c| c }
    end
    assert_match(/which is a pointer; index it, as in `c\[0\]`/, error.message)
  end

  def test_indexing_a_pointer_to_nothing_in_particular
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double (*)(double x, void *p)") { |x, p| p[0] }
    end
    assert_match(/points at nothing in particular/, error.message)
  end

  def test_an_array_of_the_wrong_data_type
    f = CArray.jit_function("double (*)(const double c[2])") { |c| c[0] }
    error = assert_raises(CArray::JIT::Unsupported) do
      f.call(CArray.int32(2).seq!)
    end
    assert_match(/takes a float64 array, and this one is int32/, error.message)
  end

  # A length is checked where the declaration carried one.  C's own rule is
  # that an unsized pointer is the caller's business, and writing `coef[3]`
  # is how a caller asks to be checked instead.
  def test_an_array_shorter_than_the_declaration_says
    f = CArray.jit_function("double (*)(const double c[4])") { |c| c[0] }
    error = assert_raises(CArray::JIT::Unsupported) do
      f.call(CArray.double(2).seq!)
    end
    assert_match(/reads 4 elements, and this array has 2/, error.message)
  end

  def test_an_unsized_pointer_is_not_length_checked
    f = CArray.jit_function("double (*)(const double c[])") { |c| c[0] }
    assert_bits_equal(7.0, f.call(CArray.double(1) { 7.0 }))
  end

  # ---------- handing a kernel's array to a C function ----------
  #
  # Inside a kernel a captured array has meant one thing -- the cell the
  # kernel is on.  A pointer parameter asks for the other thing, the array
  # itself, and which is meant comes from the declaration rather than from
  # the spelling: `poly.call(x[i], coef)` says both in one line.

  def test_a_captured_array_is_handed_over_whole
    poly = CArray.jit_function("double (*)(double x, const double coef[3])") { |x, c|
      c[0] + c[1] * x + c[2] * x * x
    }
    coef = CArray.double(3) { |i| [1.0, 2.0, 3.0][i] }
    x = CArray.double(5).seq!(0.0, 1.0)
    out = CArray.double(5)
    CArray.jit_for(5) { |i| out[i] = poly.call(x[i], coef) }
    x.elements.times { |i| assert_bits_equal(poly.block.call(x[i], coef), out[i]) }
  end

  # The address does not vary with the cell, so it travels beside the captured
  # scalars rather than through the addressing machinery an array cell needs.
  def test_the_address_travels_in_its_own_buffer
    sum = CArray.jit_function("double (*)(const double c[3])") { |c| c[0] + c[1] + c[2] }
    coef = CArray.double(3).seq!(1.0)
    out = CArray.double(2)
    kernel = CArray.jit_for(2) { |i| out[i] = sum.call(coef) }
    assert_match(/double \*const coef = \(double \*\) data\[0\];/, kernel.c_source)
  end

  def test_the_c_function_writes_into_it
    bump = CArray.jit_function("double (*)(double x, double tally[1])") { |x, t|
      t[0] = t[0] + x
      x * 2.0
    }
    tally = CArray.double(1)
    x = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i| out[i] = bump.call(x[i], tally) }
    assert_equal([2.0, 4.0, 6.0, 8.0], out.to_a)
    assert_equal([10.0], tally.to_a, "every cell should have added to it")
  end

  def test_one_array_both_subscripted_and_handed_over
    sum = CArray.jit_function("double (*)(const double c[3])") { |c| c[0] + c[1] + c[2] }
    a = CArray.double(3).seq!(1.0)
    out = CArray.double(3)
    CArray.jit_for(3) { |i| out[i] = a[i] + sum.call(a) }
    assert_equal([7.0, 8.0, 9.0], out.to_a)
  end

  def test_a_captured_view_is_packed_and_copied_back
    bump = CArray.jit_function("double (*)(double x, double t[1])") { |x, t|
      t[0] = t[0] + x
      x
    }
    grid = CArray.double(2, 2).seq
    column = grid[nil, 1]
    out = CArray.double(1)
    CArray.jit_for(1) { |i| out[i] = bump.call(2.0, column) }
    assert_equal([[0.0, 3.0], [2.0, 3.0]], grid.to_a,
                 "the write landed outside the view")
  end

  # ---------- what a kernel refuses to hand over ----------

  def test_only_an_array_may_stand_where_a_pointer_is_declared
    sum = CArray.jit_function("double (*)(const double c[3])") { |c| c[0] }
    out = CArray.double(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i| out[i] = sum.call(1.0) }
    end
    assert_match(/which is an array; pass one by name/, error.message)
  end

  def test_an_array_of_the_wrong_type_from_a_kernel
    sum = CArray.jit_function("double (*)(const double c[3])") { |c| c[0] }
    c = CArray.int32(3).seq!
    out = CArray.double(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i| out[i] = sum.call(c) }
    end
    assert_match(/takes a float64 array, and `c` is int32/, error.message)
  end

  def test_an_array_shorter_than_the_declaration_from_a_kernel
    sum = CArray.jit_function("double (*)(const double c[3])") { |c| c[0] }
    c = CArray.double(2).seq!
    out = CArray.double(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i| out[i] = sum.call(c) }
    end
    assert_match(/reads 3 of them, and `c` has 2/, error.message)
  end

  # A masked cell's bytes are out of contract -- the kernel may compute
  # anything into them so long as the mask ends up right -- and a C function
  # has no mask to consult, so it would read whatever is underneath.
  def test_a_masked_array_is_not_handed_over
    sum = CArray.jit_function("double (*)(const double c[3])") { |c| c[0] }
    c = CArray.double(3).seq!
    c[1] = UNDEF
    out = CArray.double(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i| out[i] = sum.call(c) }
    end
    assert_match(/has no mask to read/, error.message)
  end

  # uint64 is a computation type of its own, and CArray has the array to
  # match, so a pointer to one reaches its cells and a value of one comes back
  # out whole.  Neither did: the table that reads a declaration was written
  # when there was no uint64 to read, and said `uint64_t` held no value a body
  # could compute with.
  def test_a_uint64_pointer_and_return_value
    increment = CArray.jit_function("void (*)(uint64_t *, int64_t)") { |p, n|
      (0...n).each { |i| p[i] = p[i] + 1 }
    }
    large = CArray.uint64(3) { |i| 2**63 + i }
    increment.call(large, 3)
    assert_equal([2**63 + 1, 2**63 + 2, 2**63 + 3], large.to_a)

    doubled = CArray.jit_function("uint64_t (*)(int64_t)") { |n| n * 2 }
    assert_equal(4, doubled.call(2))
  end

  # A value reaches a body through one of the kernel's three scalar buses --
  # doubles, int64s, complexes -- and uint64 is the one numeric type none of
  # them carries whole.  Saying so where the declaration is beats a kernel
  # that cannot be built.
  def test_a_uint64_parameter_by_value
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("uint64_t (*)(uint64_t)") { |n| n + 1 }
    end
    assert_match(/a value is handed to a body as a double, an int64 or a complex/,
                 error.message)
    assert_match(/uint64_t \*/, error.message)
  end

  # And not through `#call` either, which is the same array reaching the same
  # C by the other road.  The block is what says what the body means, and the
  # block reaches an UNDEF and stops; the C would have read the number lying
  # underneath the mask and answered as though it were the value.
  def test_a_masked_array_is_not_handed_over_by_call
    sum = CArray.jit_function("double (*)(const double c[3])") { |c| c[0] }
    c = CArray.double(3).seq!
    c[1] = UNDEF
    error = assert_raises(CArray::JIT::Unsupported) { sum.call(c) }
    assert_match(/has no mask to read/, error.message)
  end

end
