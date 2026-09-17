require_relative "test_helper"

# A local lives in the scope Ruby gives it.  The kernel's block and an inner
# loop's block each make one, `while` and `if` do not, and the C declares
# every local at the head of the block that stands for its scope -- so two
# loops may use one name, and a value assigned inside a `while` is still
# there after it.
class TestScopes < Minitest::Test

  def test_sibling_inner_loops_may_use_one_name
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      s = 0.0
      (0...3).each { |k| t = a[i] * k; s = s + t }
      (0...3).each { |k| t = a[i] + k; s = s + t }
      out[i] = s
    }
    reference = (0...4).map { |i|
      s = 0.0
      (0...3).each { |k| t = a[i] * k; s = s + t }
      (0...3).each { |k| t = a[i] + k; s = s + t }
      s
    }
    assert_arrays_bits_equal(CArray.double(4) { reference }, out)
  end

  def test_sibling_inner_loops_may_use_one_name_at_two_types
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      s = 0.0
      (0...3).each { |k| t = a[i] * k; s = s + t }
      (0...3).each { |k| t = k * 7 / 2; s = s + t }
      out[i] = s
    }
    reference = (0...4).map { |i|
      s = 0.0
      (0...3).each { |k| t = a[i] * k; s = s + t }
      (0...3).each { |k| t = k * 7 / 2; s = s + t }
      s
    }
    assert_arrays_bits_equal(CArray.double(4) { reference }, out)
  end

  def test_a_local_assigned_before_a_while_is_read_after_it
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      v = a[i]
      c = 0
      while c < 3
        v = v * 1.5
        c += 1
      end
      out[i] = v + c
    }
    reference = (0...4).map { |i|
      v = a[i]
      c = 0
      while c < 3
        v = v * 1.5
        c += 1
      end
      v + c
    }
    assert_arrays_bits_equal(CArray.double(4) { reference }, out)
  end

  # Ruby's value there is nil when the loop ran no passes, and the C would
  # read a variable nothing had written.
  def test_a_local_first_assigned_inside_a_while_is_not_read_after_it
    refuse("->(i) { c = 0; while c < 2; y = a[i]; c += 1; end; a[i] = y }",
           /`y` is first assigned inside this `while`, which may run no passes; give it a value before the loop/)
  end

  # Ruby does not see it there at all: after the block the name is a method
  # call.
  def test_a_local_of_an_inner_loop_block_is_not_read_after_it
    refuse("->(i) { (0...2).each { |k| t = a[i] * k }; a[i] = t }",
           /`t` belongs to the loop block it was assigned in/)
  end

  def test_an_inner_loop_assigns_the_local_outside_it
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      total = 0.0
      (0...3).each { |k| w = a[i] * k; total = total + w }
      out[i] = total
    }
    reference = (0...4).map { |i|
      total = 0.0
      (0...3).each { |k| w = a[i] * k; total = total + w }
      total
    }
    assert_arrays_bits_equal(CArray.double(4) { reference }, out)
  end

  def test_a_reduction_is_still_split
    b = CArray.double(16).seq!(1.0)
    out = CArray.double(2)
    kernel = CArray.jit_for(2) { |i|
      acc = 0.0
      (0...16).each { |k| acc += b[k] * (i + 1) }
      out[i] = acc
    }
    reference = (0...2).map { |i|
      acc = 0.0
      (0...16).each { |k| acc += b[k] * (i + 1) }
      acc
    }
    assert_includes(kernel.c_source, "acc__p0")
    assert_arrays_bits_equal(CArray.double(2) { reference }, out)
  end

  def test_a_masked_local_is_declared_with_its_mask
    a = CArray.double(4).seq!(1.0)
    a[2] = UNDEF
    out = CArray.double(4)
    kernel = CArray.jit_for(4) { |i|
      x = a[i] * 2.0
      (0...2).each { |k| y = x + k; out[i] = y }
    }
    assert_match(/i\+\+\) \{\n(\s*if \( \*error \) break;\n)?\s*double x;\n\s*uint8_t x__mask;\n/,
                 kernel.c_source)
    assert_match(/k\+\+\) \{\n(\s*if \( \*error \) break;\n)?\s*double y;\n\s*uint8_t y__mask;\n/,
                 kernel.c_source)
    assert_equal([false, false, true, false], out.is_masked.to_a)
    reference = [0, 1, 3].map { |i| x = a[i] * 2.0; y = nil; (0...2).each { |k| y = x + k }; y }
    assert_equal(reference.pack("d*"), [out[0], out[1], out[3]].pack("d*"))
  end

  # The border is the same body emitted a third time, and has to come out with
  # the same declarations as the other two.
  def test_a_stencil_border_declares_what_the_body_declares
    rows, columns = 4, 5
    source = CArray.double(rows, columns) { |i, j| (i * 10 + j).to_f }
    read = lambda { |i, j| source[i.clamp(0, rows - 1), j.clamp(0, columns - 1)] }
    reference = CArray.double(rows, columns) { |i, j|
      s = 0.0
      (0...2).each { |k| t = read.(i - 1, j) * k; s = s + t }
      (0...2).each { |k| t = read.(i, j + 1) + k; s = s + t }
      s
    }
    result = CArray.jit_stencil(source, border: :clamp) { |a|
      s = 0.0
      (0...2).each { |k| t = a[-1, 0] * k; s = s + t }
      (0...2).each { |k| t = a[0, 1] + k; s = s + t }
      s
    }
    assert_arrays_bits_equal(reference, result)
  end

  def test_a_swept_pass_declares_what_the_body_declares
    skip "this CArray has no ca_call_cslab" unless CArray::JIT::Sweep.available?
    a = CArray.double(3, 4).seq!(1.0)
    out = CArray.double(3, 4)
    kernel = CArray.jit_each {
      s = 0.0
      (0...2).each { |k| t = a * k; s = s + t }
      (0...2).each { |k| t = a + k; s = s + t }
      out = s
    }
    assert_equal(1, kernel.rank, "the pass was swept")
    reference = a.to_a.flatten.map { |v|
      s = 0.0
      (0...2).each { |k| t = v * k; s = s + t }
      (0...2).each { |k| t = v + k; s = s + t }
      s
    }
    assert_equal(reference.pack("d*"), out.to_a.flatten.pack("d*"))
    assert_equal(2, kernel.c_source.scan(/^\s*double s;\n/).size,
                 "one declaration in each of the two bodies")
  end

  # ---------- the same in a compiled function ----------

  def test_a_function_may_use_one_name_in_sibling_loops
    f = CArray.jit_function("double f(double x)") { |x|
      s = 0.0
      (0...3).each { |k| t = x * k; s = s + t }
      (0...3).each { |k| t = k * 7 / 2; s = s + t }
      s
    }
    reference = ->(x) {
      s = 0.0
      (0...3).each { |k| t = x * k; s = s + t }
      (0...3).each { |k| t = k * 7 / 2; s = s + t }
      s
    }
    assert_bits_equal(reference.(2.5), f.call(2.5))
  end

  def test_a_function_reads_a_local_after_a_while_it_was_carried_through
    f = CArray.jit_function("double f(double x)") { |x|
      v = x
      c = 0
      while c < 3
        v = v * 1.5
        c += 1
      end
      v + c
    }
    reference = ->(x) {
      v = x
      c = 0
      while c < 3
        v = v * 1.5
        c += 1
      end
      v + c
    }
    assert_bits_equal(reference.(2.5), f.call(2.5))
  end

  def test_a_function_may_not_read_a_local_first_assigned_inside_a_while
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double f(double x)") { |x|
        c = 0
        while c < 2
          y = x
          c += 1
        end
        y
      }
    end
    assert_match(/`y` is first assigned inside this `while`/, error.message)
  end

  def test_a_function_may_not_read_a_local_of_an_inner_loop_block_after_it
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double f(double x)") { |x|
        (0...2).each { |k| t = x * k }
        t
      }
    end
    assert_match(/`t` belongs to the loop block it was assigned in/, error.message)
  end

end
