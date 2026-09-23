require_relative "test_helper"

# A compiled function has two names, and they are not the same name.
#
# `#name` is what the declaration said -- what a reader wrote, and what a
# message about the function should say.  `#symbol` is what is in the object:
# what a call reaches, and what two functions have to differ by.  For one
# bound from a library they coincide; for one compiled here the symbol
# carries a digest of the body, so that two bodies declared alike stay apart.
#
# They used to be one attribute holding whichever of the two its constructor
# was handed, so `#name` answered `j0` for an extern and
# `carray_jit_square_<digest>` for a compiled function -- different kinds of
# answer from the same question, decided by provenance.
class TestFunctionNames < Minitest::Test

  def square
    CArray.jit_function("double square(double x)") { |x| x * x }
  end

  def test_a_compiled_function_keeps_the_name_it_was_declared_by
    assert_equal :square, square.name
  end

  def test_its_symbol_is_the_one_in_the_object
    assert_match(/\Acarray_jit_square_[0-9a-f]+\z/, square.symbol.to_s)
  end

  def test_an_extern_answers_the_same_for_both
    j0 = CArray.jit_extern("double j0(double)")
    assert_equal :j0, j0.name
    assert_equal :j0, j0.symbol
  end

  # A prototype may name no function, and then there is no declared name to
  # answer with.  The symbol is still there.
  def test_an_anonymous_prototype_has_no_name_and_still_has_a_symbol
    anonymous = CArray.jit_function("double (*)(double)") { |x| x + 1 }
    assert_nil anonymous.name
    assert_match(/\Acarray_jit_function_[0-9a-f]+\z/, anonymous.symbol.to_s)
  end

  def test_what_it_prints_is_the_declaration
    assert_includes square.to_s, "double square(double)"
    refute_match(/carray_jit_/, square.to_s)
  end

  # What two functions are told apart by has to be the symbol.  Declared
  # alike, two different bodies would share a cache key under the name, and
  # the first compiled would be handed back for the second -- quietly, since
  # nothing about them differs to look at.
  def test_two_bodies_declared_alike_are_told_apart
    one = CArray.jit_function("double f(double x)") { |x| x + 1.0 }
    two = CArray.jit_function("double f(double x)") { |x| x + 2.0 }
    assert_equal one.name, two.name
    refute_equal one.symbol, two.symbol
    refute_equal one.kernel_key, two.kernel_key
    assert_equal 2.0, one.call(1.0)
    assert_equal 3.0, two.call(1.0)
  end

  # And a kernel that calls both has to paste both, which is the same
  # question asked of the generated C.
  def test_a_kernel_calling_both_pastes_both
    one = CArray.jit_function("double f(double x)") { |x| x + 1.0 }
    two = CArray.jit_function("double f(double x)") { |x| x + 2.0 }
    out = CArray.double(3)
    kernel = CArray.jit_for(3) { |i| out[i] = one.call(i * 1.0) + two.call(i * 1.0) }
    assert_equal [3.0, 5.0, 7.0], out.to_a
    assert_includes kernel.c_source, one.symbol.to_s
    assert_includes kernel.c_source, two.symbol.to_s
  end

end
