require_relative "test_helper"

# The scaffolding that lets a run here reach a CArray checkout rather than the
# installed gem.  The two gems are developed together, so a CArray-side change
# has to be visible to this suite before anything here can be written against
# it -- `CARRAY_TREE=../carray rake test` is what puts it on the load path.
#
# This file does not ask for the tree.  It says which CArray answered, so a
# run that meant to test against a checkout and silently did not is visible in
# the output rather than only in a puzzling failure somewhere else.
class TestCArrayTree < Minitest::Test

  def carray_extension
    $LOADED_FEATURES.grep(/carray_ext/).first
  end

  def test_a_carray_is_loaded_and_says_where_from
    refute_nil(carray_extension, "CArray's extension is not loaded")
    assert(File.exist?(carray_extension), "#{carray_extension} is not there")
  end

  def test_the_declared_range_admits_it
    spec = Gem::Specification.load(
      File.expand_path("../carray-jit.gemspec", __dir__)
    )
    carray = spec.dependencies.find { |dependency| dependency.name == "carray" }
    assert(carray.requirement.satisfied_by?(Gem::Version.new(CArray::VERSION)),
           "CArray #{CArray::VERSION} is outside #{carray.requirement}")
  end

  # The whole point of the scaffolding: when CARRAY_TREE names a checkout, the
  # CArray that answered has to be that one.  Version is not enough to tell
  # them apart -- a checkout and the gem it was built from carry the same
  # number -- so this asks where the extension came from.
  def test_carray_tree_is_the_one_that_answered
    tree = ENV["CARRAY_TREE"]
    skip "CARRAY_TREE is not set; running against the installed gem" unless tree
    expected = File.expand_path(File.join(tree, "ext"))
    assert(carray_extension.start_with?(expected),
           "CARRAY_TREE=#{tree} was asked for, but CArray answered from " \
           "#{carray_extension}")
  end

end
