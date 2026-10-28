require "fiddle"
require "fiddle/import"
require "carray/jit/errors"

class CArray
  module JIT

    # Everything this library asks of the layer that reaches C from Ruby, and
    # the one place that layer is named.  The rest of the library says what
    # it wants -- open this object, find this symbol, make a function of
    # these types, read these bytes -- in the words below, and only this
    # file knows that Fiddle is what answers.
    #
    # That is so the layer can be replaced by changing one file.  Fiddle does
    # not let a call be made from a Ractor other than the main one, and a
    # layer that does would be a second version of this module rather than a
    # second version of the library (devel/PROPOSAL_FFI_SEAM.md).
    #
    # What is asked:
    #
    # - a shared object opened, and the libraries already loaded searched
    # - a symbol's address found in one
    # - a function made from an address and its types, and called
    # - bytes read and written at an address
    # - a Ruby object handed to C as the VALUE it is
    #
    # A function is called by calling what #function returns: its #call is
    # the layer's own, so nothing stands between a kernel and the C beyond
    # what the layer itself costs.  The arguments it takes for a `:pointer`
    # are an Integer address, a String -- whose bytes are what C is handed --
    # or nil.
    # @private
    module Native

      # The C types a function is made with, by this library's names for
      # them.  `:pointer` is any pointer; a function's arguments say what it
      # points at only to the C, which is all that needs to know.
      TYPES = {
        void:       Fiddle::TYPE_VOID,
        pointer:    Fiddle::TYPE_VOIDP,
        char:       Fiddle::TYPE_CHAR,
        uchar:      Fiddle::TYPE_UCHAR,
        short:      Fiddle::TYPE_SHORT,
        ushort:     Fiddle::TYPE_USHORT,
        int:        Fiddle::TYPE_INT,
        uint:       Fiddle::TYPE_UINT,
        long:       Fiddle::TYPE_LONG,
        ulong:      Fiddle::TYPE_ULONG,
        long_long:  Fiddle::TYPE_LONG_LONG,
        ulong_long: Fiddle::TYPE_ULONG_LONG,
        float:      Fiddle::TYPE_FLOAT,
        double:     Fiddle::TYPE_DOUBLE,
      }.freeze

      # The other way round, for what Fiddle's parser answers.  Every code it
      # gives for a spelling CDeclaration hands it is one of the fourteen
      # above: `size_t` and the other platform words arrive as the code of
      # whichever of these they are on this machine.
      NAMES = TYPES.invert.freeze
      private_constant :NAMES

      POINTER_SIZE = Fiddle::SIZEOF_VOIDP

      # What a library is, for a caller that was handed one.  `jit_extern`'s
      # `from:` takes one of these as it stands.
      Library = Fiddle::Handle

      # Raised when a library will not open or a symbol is not in it.
      LinkError = Fiddle::DLError

      PARSER = ::Object.new.extend(Fiddle::CParser)
      private_constant :PARSER

      # Opens a shared object.  `global:` is whether its symbols join the
      # process-wide namespace -- RTLD_GLOBAL -- and it is a required word
      # because layers differ on what they do unasked: Fiddle opens globally,
      # and a layer that opened locally would change which definition a name
      # in one generated object resolves to (see Compiler's link flags).
      # Fiddle has no word for the other way, and nothing here asks for it.
      def self.open_library (path, global:)
        raise ArgumentError, "Fiddle opens a library only globally" unless global
        Fiddle::Handle.new(path, Fiddle::RTLD_LAZY | Fiddle::RTLD_GLOBAL)
      end

      # What the process has already loaded, searched as one library.
      def self.loaded_libraries
        Fiddle::Handle::DEFAULT
      end

      # The address of `name` in `library`, as an Integer.
      def self.address (library, name)
        library[name]
      end

      # A function at `address` taking `arguments` and returning `result`,
      # each one of the names in TYPES.
      #
      # `release_gvl:` is whether the GVL is let go for the length of a call,
      # and it is a required word because layers differ on what they do
      # unasked -- Fiddle lets it go, FFI keeps it.  Letting it go is right
      # for C that touches no Ruby value, which is every generated kernel; it
      # is wrong for C that does, which is CArray's own sweep.
      def self.function (address, arguments, result, release_gvl:, name: nil)
        types = arguments.map { |type| TYPES.fetch(type) }
        options = name ? { name: name } : {}
        return Fiddle::Function.new(address, types, TYPES.fetch(result), **options) if release_gvl
        begin
          Fiddle::Function.new(address, types, TYPES.fetch(result),
                               need_gvl: true, **options)
        rescue ArgumentError
          # A Fiddle too old to be told.  It is also too old to have let go
          # of the GVL in the first place -- the keyword and the releasing
          # arrived together -- so what is left here is what that Fiddle
          # would have done anyway.
          Fiddle::Function.new(address, types, TYPES.fetch(result), **options)
        end
      end

      # The type a C spelling is on this machine, as a name in TYPES, or nil
      # where it is not one.  The spelling is one CDeclaration has already
      # put in order: `unsigned long` rather than `long unsigned`, `void *`
      # for any pointer.
      def self.c_type (spelling)
        NAMES.fetch(PARSER.parse_ctype(spelling))
      rescue StandardError
        nil
      end

      # `size` bytes at `address`, as a String.  Fiddle::Pointer.read and
      # .write are not in the fiddle Ruby 3.2 ships (1.1.1).
      def self.read (address, size)
        Fiddle::Pointer.new(address)[0, size]
      end

      # `bytes` written at `address`.
      def self.write (address, bytes)
        Fiddle::Pointer.new(address)[0, bytes.bytesize] = bytes
      end

      # `object` as the VALUE C sees -- for CArray's own C, which takes the
      # array itself rather than its memory.
      def self.value (object)
        Fiddle.dlwrap(object)
      end

    end

  end
end
