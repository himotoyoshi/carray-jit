require "carray"

class CArray
  module JIT

    # Letting CArray drive the loop instead of driving it here.
    #
    # `ca_call_cslab_N` is CArray's chunked sweep: it acquires the operands,
    # broadcasts them, ORs the inputs' masks and propagates the result, and
    # hands a callback one chunk at a time.  A non-alias operand -- a gather,
    # a lazy array, anything the tiers here would have to materialise -- is
    # re-gathered into a ~32KB arena scratch per chunk rather than copied
    # whole, so the input memory peak stops scaling with the operand.
    #
    # That is what this is for, and it is the only thing it is for.  A kernel
    # that names an index is not a sweep: it reaches neighbours, chooses an
    # order and runs inner loops, none of which a chunked walk can offer.
    # jit_each is the form with no neighbour in it, which is the same thing
    # as saying it is the form a sweep can drive.
    module Sweep

      # The largest arity the family was generated for.  Whether a pass can
      # go this way at all is decided in CArray::JIT.sweepable_pass?, before
      # there is a kernel -- because the answer changes what is compiled.
      MAX_ARITY = 7

      # `arrays` are the operands in the order the kernel addresses them, and
      # `fsync` says which of them it writes -- CArray's own spelling, one
      # character per operand.  `parts` become the table the slab is handed
      # as `userdata`, in order; one that is not frozen is the slab's to
      # write.
      #
      # CArray makes the call, and points the slab at the Strings' own bytes:
      # they arrive as arguments, and an argument is pinned against
      # compaction for the length of the call.  It holds the GVL throughout,
      # unlike every other call this library makes into C.  Acquiring the
      # operands attaches them, allocates and raises on a shape that will not
      # broadcast, none of which may be done without it, and the kernel is
      # called back from inside, where there is nowhere to let go of it.
      def self.run (slab, fsync, arrays, *parts)
        CArray::AddressBasis.sweep(slab, fsync, arrays, *parts)
      end

    end

  end
end
