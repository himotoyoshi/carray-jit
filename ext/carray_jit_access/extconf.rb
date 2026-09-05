require "mkmf"
require "carray/mkmf"

# Only the public carray.h surface is used: the query predicates, the
# CAStride compose-fold, and the attach lifecycle.
if have_carray()
  create_makefile("carray/jit/access")
end
