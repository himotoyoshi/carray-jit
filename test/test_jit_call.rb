require_relative "test_helper"

# `jit_call` compiles the block as a C function and calls it, here, with the
# locals around it.
#
# The declaration's parameter names are the join, and they do the work twice:
# they are the body's parameters, so the block declares none, and they name
# the locals the call reads.  In C a parameter's name in a prototype is
# decoration; here it is the whole binding.
class TestJitCall < Minitest::Test

  def ema (values, alpha)
    n = values.elements
    out = CArray.double(n)
    CArray.jit_call("void (*)(double *out, const double *values, " \
                    "size_t n, double alpha)") {
      previous = values[0]
      n.times { |i|
        previous = alpha * values[i] + (1.0 - alpha) * previous
        out[i] = previous
      }
    }
    out
  end

  def dot (x, y)
    n = x.elements
    CArray.jit_call("double (*)(const double *x, const double *y, size_t n)") {
      total = 0.0
      n.times { |i| total = total + x[i] * y[i] }
      total
    }
  end

  # ---------- what it answers ----------

  # The one an array expression cannot state, checked against the same
  # algorithm written out in Ruby rather than against a closed form.
  def test_a_recurrence_agrees_with_ruby
    values = CArray.double(16).seq!(1.0)
    previous = values[0]
    expected = (0...16).map { |i|
      previous = 0.25 * values[i] + 0.75 * previous
      previous
    }
    assert_equal expected, ema(values, 0.25).to_a
  end

  def test_a_value_comes_back
    values = CArray.double(8).seq!(1.0)
    assert_equal (1..8).sum { |x| (x * x).to_f }, dot(values, values)
  end

  def test_a_void_function_answers_nil
    out = CArray.double(4)
    n = 4
    assert_nil(CArray.jit_call("void (*)(double *out, size_t n)") {
      n.times { |i| out[i] = i * 2.0 }
    })
    assert_equal [0.0, 2.0, 4.0, 6.0], out.to_a
  end

  # The locals are read where the call stands, so the same site answers for
  # whatever is in scope on this pass.
  def test_the_locals_are_read_at_every_call
    assert_equal [1.0, 1.5, 2.25], ema(CA_DOUBLE([1, 2, 3]), 0.5).to_a
    assert_equal [10.0, 10.0, 10.0], ema(CA_DOUBLE([10, 10, 10]), 0.5).to_a
  end

  # ---------- compiled once per site ----------

  # A block literal is a fresh Proc every time the line runs; its
  # instruction sequence is the site's and does not change, which is what
  # the compiled function is kept under.
  def test_the_site_is_compiled_once
    CArray::JIT.clear_registry
    values = CArray.double(4).seq!(1.0)
    3.times { ema(values, 0.5) }
    assert_equal 1, CArray::JIT.send(:function_registry).size
  end

  # And `clear_registry` reaches it, which is the whole of what that method
  # is for: the next call compiles again.
  def test_clearing_the_registry_reaches_the_site
    values = CArray.double(4).seq!(1.0)
    ema(values, 0.5)
    CArray::JIT.clear_registry
    assert_empty CArray::JIT.send(:function_registry)
    ema(values, 0.5)
    assert_equal 1, CArray::JIT.send(:function_registry).size
  end

  # ---------- a provider may answer instead ----------

  # A compiled function may already exist somewhere other than this
  # compiler's cache -- built ahead of the program and shipped, which is
  # what carray-aot does with these same sites.
  def test_a_provider_is_asked_before_anything_is_compiled
    asked = []
    answer = Struct.new(:calls) do
      def call (*arguments) ; self.calls += 1 ; :answered ; end
    end.new(0)
    with_provider(lambda { |prototype, block, names|
      asked << [prototype, block.binding.eval("__method__"), names]
      answer
    }) do
      n = 4
      out = CArray.double(4)
      result = CArray.jit_call("void (*)(double *out, size_t n)") {
        n.times { |i| out[i] = 1.0 }
      }
      assert_equal :answered, result
      assert_equal 1, answer.calls
      assert_equal 0, CArray::JIT.send(:function_registry).size
    end
    assert_equal 1, asked.size
    _, method, names = asked.first
    assert_equal :test_a_provider_is_asked_before_anything_is_compiled, method
    assert_equal [:out, :n], names
  end

  # nil means the site is not the provider's, and it compiles as it would
  # have.
  def test_a_provider_answering_nil_leaves_the_site_alone
    with_provider(lambda { |_, _, _| nil }) do
      out = CArray.double(3)
      n = 3
      CArray.jit_call("void (*)(double *out, size_t n)") {
        n.times { |i| out[i] = i * 1.0 }
      }
      assert_equal [0.0, 1.0, 2.0], out.to_a
    end
  end

  def with_provider (provider)
    CArray::JIT.clear_registry
    was = CArray::JIT.call_provider
    CArray::JIT.call_provider = provider
    yield
  ensure
    CArray::JIT.call_provider = was
    CArray::JIT.clear_registry
  end

  # ---------- what it refuses ----------

  def test_a_declaration_with_an_unnamed_parameter
    n = 4
    error = assert_raises(CArray::JIT::Unsupported) {
      CArray.jit_call("void (*)(double *, size_t n)") { n.times { |i| i } }
    }
    assert_match(/gives parameter 1 no name/, error.message)
    assert_match(/the local the call reads/, error.message)
  end

  def test_a_declared_name_with_no_local_behind_it
    n = 4
    error = assert_raises(CArray::JIT::Unsupported) {
      CArray.jit_call("void (*)(double *missing, size_t n)") {
        n.times { |i| missing[i] = 0.0 }
      }
    }
    assert_match(/declares `missing`/, error.message)
    assert_match(/no local by that name/, error.message)
  end

  # Written in both places they could disagree, and nothing would say so.
  def test_a_block_that_names_the_parameters_again
    out = CArray.double(4)
    n = 4
    error = assert_raises(CArray::JIT::Unsupported) {
      CArray.jit_call("void (*)(double *out, size_t n)") { |out, n|
        n.times { |i| out[i] = 0.0 }
      }
    }
    assert_match(/its declaration named/, error.message)
    assert_match(/leave the block's off/, error.message)
  end

  def test_no_block
    error = assert_raises(CArray::JIT::Unsupported) {
      CArray.jit_call("void (*)(size_t n)")
    }
    assert_match(/none was given/, error.message)
  end

  # A body outside the subset says so where it is written.
  def test_a_body_outside_the_subset
    n = 4
    error = assert_raises(CArray::JIT::Unsupported) {
      CArray.jit_call("void (*)(size_t n)") { n.times { |i| puts i } }
    }
    refute_empty error.message
  end

end
