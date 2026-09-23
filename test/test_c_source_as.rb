require_relative "test_helper"

# `#c_source_as` hands the compiled C over under a symbol the caller picked.
#
# It is for a caller writing the C into a file of its own rather than letting
# this compile it.  The symbol this compiler writes carries a digest of the
# body, which is right for an object in a cache and wrong for one committed
# to a repository, where the same build has to give the same name every time.
class TestCSourceAs < Minitest::Test

  def square
    CArray.jit_function("double square(double x)") { |x| x * x }
  end

  def test_the_definition_is_under_the_symbol_asked_for
    source = square.c_source_as("mylib_square")
    assert_match(/^double\nmylib_square \(double x\)$/, source)
    refute_match(/carray_jit_square_/, source)
  end

  # The claim the rename rests on: the symbol is the only thing in the
  # generated file that the choice of symbol decides.  Two compilations of
  # one block under two declared names differ in nothing else once both
  # symbols are levelled -- so renaming is what regenerating would have
  # produced, exactly rather than nearly.
  def test_a_rename_is_what_a_second_generation_would_have_written
    body = proc { |x| x * x + 1.0 }
    alpha = CArray.jit_function("double alpha(double x)", &body)
    beta = CArray.jit_function("double beta(double x)", &body)
    assert_equal alpha.c_source_as("levelled"), beta.c_source_as("levelled")
  end

  # A body that calls another compiled function has the callee pasted into
  # the same file.  Only the function asked about is renamed; the pasted one
  # is static and keeps the symbol it was compiled under.
  def test_only_the_function_asked_about_is_renamed
    twice = CArray.jit_function("double twice(double x)") { |x| x + x }
    outer = CArray.jit_function("double outer(double x)") { |x| twice.call(x) + 1.0 }
    source = outer.c_source_as("mylib_outer")
    assert_match(/^double\nmylib_outer \(double x\)$/, source)
    assert_match(/^static double\n#{twice.symbol}/, source)
    assert_includes source, "#{twice.symbol}(x)"
  end

  # ---------- what it refuses ----------

  def test_a_name_c_cannot_spell
    error = assert_raises(CArray::JIT::Unsupported) { square.c_source_as("3bad") }
    assert_match(/is not a C identifier/, error.message)
    assert_raises(CArray::JIT::Unsupported) { square.c_source_as("has space") }
    assert_raises(CArray::JIT::Unsupported) { square.c_source_as("") }
  end

  # A caller may not write into the namespace this compiler's cached objects
  # are entitled to.
  def test_a_name_in_this_compilers_namespace
    error = assert_raises(CArray::JIT::Unsupported) {
      square.c_source_as("carray_jit_mine")
    }
    assert_match(/this compiler's own namespace/, error.message)
  end

  def test_a_function_bound_from_a_library_has_no_c_of_its_own
    error = assert_raises(CArray::JIT::Unsupported) {
      CArray.jit_extern("double j0(double)").c_source_as("mine")
    }
    assert_match(/bound from a library/, error.message)
  end

  # The hazard the prefix exists to close is the caller's from here on, and
  # the refusals above do not cover it: `sin` is a C identifier and is not in
  # this compiler's namespace.  Nothing stops it, and the doc comment says
  # who owns that.
  def test_a_name_the_c_library_already_has_is_the_callers_to_avoid
    source = CArray.jit_function("double sin(double)") { |x| x * x }
                   .c_source_as("sin")
    assert_match(/^double\nsin \(double x\)$/, source)
  end

end
