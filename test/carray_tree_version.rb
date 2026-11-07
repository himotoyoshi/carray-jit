# Loaded into every child process when CARRAY_TREE names a CArray checkout.
#
# The command that looks after the cache does not load CArray, and asks
# RubyGems for the version a `require` would activate.  For a user that is the
# installed gem, which is also the CArray their kernels were compiled against.
# Under CARRAY_TREE the kernels are compiled against the checkout instead, and
# the checkout's version need not match any installed gem (it differs as soon
# as the checkout is bumped for the next release).  This makes RubyGems answer
# with the checkout's version, so the command and the suite name the same
# cache directory.  It belongs to the test scaffolding, not to the command.
tree = ENV["CARRAY_TREE"]
header = tree && File.join(File.expand_path(tree), "ext", "version.h")
version = header && File.file?(header) &&
          File.read(header)[/^#define\s+CA_VERSION\s+"([^"]+)"/, 1]

if version
  Gem::Specification.singleton_class.prepend(Module.new {
    define_method(:find_by_name) do |name, *requirements|
      found = super(name, *requirements)
      return found unless name == "carray"
      # Ask RubyGems first, so a test that makes CArray missing still sees
      # it missing, whichever order the two patches were loaded in.
      found = found.dup
      found.version = version
      found
    end
  })
end
