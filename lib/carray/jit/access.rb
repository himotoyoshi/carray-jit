# The address basis a kernel is handed -- a pointer, and one byte stride per
# axis, lent for the length of a block -- is knowledge about CArray's views
# written against CArray's own C, and it lives there.  This gem carried it as
# a second C extension until carray 3.0.2, which is why the old name is still
# here; it goes at the next minor.
#
# The file stays rather than the alias moving into `carray/jit.rb`, because
# this is what the light half loads.  A program whose sites are all answered
# by a library built ahead of it never loads the compiler, and `CFunction`
# still has to be handed an address -- see `carray/jit/call`.
require "carray"
require "carray/jit/version"

CArray::JIT::Access = CArray::AddressBasis
