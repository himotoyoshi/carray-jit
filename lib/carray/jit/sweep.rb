require "fiddle"

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

      # The sweep is reached by address, the way this library reaches every
      # other C function: CArray's extension is already loaded, so the symbol
      # is there to be found rather than linked against.
      def self.handle
        return @handle if defined?(@handle)
        path = $LOADED_FEATURES.find { |feature|
          File.basename(feature) =~ /\Acarray_ext\.(so|bundle|dylib)\z/
        }
        @handle = path && begin
          Fiddle::Handle.new(path)
        rescue Fiddle::DLError
          nil
        end
      end

      # True when this CArray is new enough to have the chunked slab family.
      def self.available?
        return @available if defined?(@available)
        @available = !handle.nil? && begin
          handle["ca_call_cslab_1_r"]
          true
        rescue Fiddle::DLError
          false
        end
      end

      # ca_call_cslab_N_r(func, fsync, rcx0..rcxN-1, userdata)
      #
      # `need_gvl: true` is not a detail.  Fiddle releases the GVL for a call
      # unless it is told otherwise, which is right for every other function
      # this library reaches -- a generated kernel is pure C, touches no Ruby
      # value and is the better for running while other threads do.  This one
      # is not that: it is CArray's own C, and acquiring the operands attaches
      # them, allocates with `xmalloc`, creates a mask where an output needs
      # one and raises on a shape that will not broadcast.  All of that is the
      # Ruby runtime's, and none of it may be done without the GVL.  The
      # kernel it calls back into is still pure C, but the GVL is held for the
      # whole call rather than the callback, because Fiddle's choice is made
      # once at the boundary and there is nowhere inside to make it again.
      def self.function (arity)
        @functions ||= {}
        @functions[arity] ||=
          begin
            types = [Fiddle::TYPE_VOIDP] * (arity + 3)
            begin
              Fiddle::Function.new(handle["ca_call_cslab_#{arity}_r"], types,
                                   Fiddle::TYPE_VOIDP, need_gvl: true)
            rescue ArgumentError
              # A Fiddle too old to be told.  It is also too old to have let
              # go of the GVL in the first place -- the keyword and the
              # releasing arrived together -- so what is left here is what
              # that Fiddle would have done anyway.
              Fiddle::Function.new(handle["ca_call_cslab_#{arity}_r"], types,
                                   Fiddle::TYPE_VOIDP)
            end
          end
      end

      # The largest arity the family was generated for.  Whether a pass can
      # go this way at all is decided in CArray::JIT.sweepable_pass?, before
      # there is a kernel -- because the answer changes what is compiled.
      MAX_ARITY = 7

      # `arrays` are the operands in the order the kernel addresses them, and
      # `fsync` says which of them it writes -- CArray's own spelling, one
      # character per operand.
      def self.call (slab, fsync, arrays, context)
        function(arrays.size).call(slab, fsync,
                                   *arrays.map { |array| Fiddle.dlwrap(array) },
                                   context)
      end

    end

  end
end
