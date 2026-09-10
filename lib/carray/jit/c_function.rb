require "digest"
require "fiddle"
require "fiddle/import"

class CArray
  module JIT

    # One parameter or return type, as the prototype spelled it.
    #
    # Fiddle's parser answers what the ABI needs and no more: every pointer
    # comes back as `TYPE_VOIDP`, so `const double *`, `double *` and `void *`
    # are one thing to it.  That is enough to *call* a function and not enough
    # to *write* one, which is why the declarator's own text is kept beside
    # the code Fiddle assigned it.
    CType = Struct.new(:text, :fiddle, :computation, :pointer, :array,
                       :element, :const) do
      # True for a type that may be written into a signature but holds no
      # value a kernel or a body can compute with.
      def opaque?
        computation.nil?
      end

      # A pointer to numbers, which a body may index.  `void *` is not one:
      # it points at nothing in particular, so it stays a slot.
      def indexable?
        pointer && !element.nil?
      end

      # A C99 complex passed or returned by value.  Fiddle cannot carry one,
      # so a call from Ruby goes through a shim; a call from a kernel is C
      # calling C and needs nothing.
      def complex?
        !pointer && CDeclaration::COMPLEX_CODES.value?(fiddle)
      end

      # `CMPLX` for a double complex, `CMPLXF` for a float one.
      def complex_build
        fiddle == :float_complex ? "CMPLXF" : "CMPLX"
      end

      # C's own declarator puts an array's length where a reader can see it,
      # so `const double coef[3]` and `const double *coef` are different
      # declarations of the same ABI.  The length is kept rather than folded
      # away: a subscript into a parameter has no extent behind it unless the
      # declaration carried one, and this compiler's subscripts have always
      # had one.
      def sized?
        array.is_a?(Integer)
      end

      # A declarator with the name in it, which for an array is not simply
      # the type followed by the name.
      def declare (name)
        return "#{text} #{name}" unless array
        "#{text.sub(/\s*\[.*\]\z/, "")} #{name}[#{array if sized?}]"
      end

      # @return [String] the type, as C spells it.
      def to_s
        text
      end
    end

    # A C function a kernel body can call, and that C can be handed back.
    #
    # The binding is borrowed from Fiddle -- `Fiddle::Handle` finds the
    # library and the symbol, and `Fiddle::CParser` decides the ABI code of a
    # type, which is the same path `Fiddle::Importer#extern` takes.  The
    # *call* is not borrowed: reaching a function through `Fiddle::Function`
    # costs a few hundred nanoseconds per cell, against single digits from
    # compiled C.  Fiddle is asked where the function is; the kernel calls it.
    #
    # The address travels to the kernel in a buffer, the way a captured scalar
    # already does, rather than being linked against.  That means no `-l`
    # flag, no library path at compile time, and a compiled kernel that does
    # not depend on which library the function came from -- so `f.call(a)`
    # compiles once and serves every function of that signature.
    class CFunction

      # @!attribute [r] name
      #   @return [String] the function's name, as the prototype gives it.
      # @!attribute [r] prototype
      #   @return [String] the C declaration this was named by.
      # @!attribute [r] c_source
      #   @return [String, nil] the C compiled for a body written here, or
      #     `nil` for one found elsewhere.
      attr_reader :name, :prototype, :return_type, :parameters, :pointer,
                  :block, :c_source, :origin, :definition, :helpers,
                  # The compiled functions this body calls.  Whoever pastes
                  # the definition has to paste these beside it: it reaches
                  # them by symbol, and the symbol is only there if the
                  # definition is.
                  :dependencies,
                  # What `raise` in the body said, by the code it reports.
                  # The kernel that pastes it answers for these too.
                  :raise_messages

      def initialize (name, prototype, return_type, parameters, pointer,
                      block: nil, c_source: nil, origin: nil, error: nil,
                      definition: nil, helpers: nil, takes_error: false,
                      raise_messages: {}, dependencies: [], shim: nil)
        @name = name && name.to_sym
        @prototype = prototype
        @return_type = return_type
        @parameters = parameters
        @pointer = pointer
        # A function written in Ruby keeps its block, so that what the kernel
        # runs and what Ruby would compute can be put side by side.
        @block = block
        @c_source = c_source
        # The definition on its own, without the file it was compiled in, and
        # what it wants from a preamble -- what a kernel needs to paste it.
        @definition = definition
        @helpers = helpers
        @dependencies = dependencies
        # True when that definition ends in an `int32_t *`: the body can report
        # a failure, and pasted it reports into the caller's slot rather than
        # into the flag in its own object.
        @takes_error = takes_error
        @raise_messages = raise_messages
        @origin = origin
        # Where the compiled body says a division had no divisor, or a
        # subscript ran off its array.  Nil when the body can do neither.
        @error = error
        # The address of the entry point a call from Ruby takes where the
        # signature carries a complex by value; nil where it does not, which
        # is every other signature and every borrowed function.
        @shim = shim
        @function = nil
      end

      # True for one compiled from a Ruby block rather than bound from a
      # library.
      def compiled?
        !@block.nil?
      end

      # True for one a kernel can paste into its own C rather than call
      # through a pointer.  The body has to be here to paste, which a borrowed
      # function's is not: it arrives as an address and nothing else.
      def pasted?
        compiled? && !@definition.nil?
      end

      # True when the pasted copy takes the caller's error slot as its last
      # argument.  Standing alone the same body reports into the flag in its
      # own object -- `#call` reads that one -- but pasted there is no such
      # object around it, and the failure belongs to the kernel that is
      # running: `1 / 0` in a function called from a kernel raises the
      # ZeroDivisionError the kernel raises for its own.
      def pasted_takes_error?
        pasted? && @takes_error
      end

      # The declaration under the name the block reached it by.  What a
      # message about a call should say: the caller wrote `f`, and the symbol
      # a body compiled here carries -- `carray_jit_two_<digest>` -- along
      # with the file it was written in are answers to a question nobody
      # asked there.  Those stay in `to_s`, which names the object rather
      # than the call.
      def declaration_as (name)
        "#{@return_type.text} #{name}(#{@parameters.map(&:text).join(', ')})"
      end

      # The signature, without the address.
      def signature
        [@return_type.text, @parameters.map(&:text)]
      end

      # What a compiled kernel depends on.  Two functions that share it share
      # a kernel.
      #
      # For one bound from a library that is the signature alone: the address
      # arrives with the call, so `j0` and `y0` are the same kernel and it is
      # compiled once.  For one compiled here it is the signature *and* the
      # symbol, which carries the digest of the body -- the body is on its way
      # into the kernel's own translation unit, and a kernel that has one body
      # pasted into it cannot serve another function that is merely declared
      # the same way.  Splitting the cache costs a compile per body; sharing
      # it would hand back the wrong answer, and would do it quietly.
      def kernel_key
        compiled? ? [signature, @name] : signature
      end

      # @return [Integer] how many arguments the function takes.
      def arity
        @parameters.size
      end

      # The Fiddle types, for calling it from Ruby.
      def argument_types
        @parameters.map(&:fiddle)
      end

      # The C spelling of the pointer type, for the typedef a kernel emits.
      def c_declaration (typedef_name)
        "typedef #{@return_type.text} (*#{typedef_name})" \
        "(#{@parameters.map(&:text).join(', ')});"
      end

      # What a kernel computes the result in.
      def result_type
        computation_of(@return_type, "returns")
      end

      # What it computes in where the value is dropped.  `void` is a return
      # type a call may have and a cell may not, so the question only has an
      # answer in statement position -- which is the one place that asks.
      def discarded_result_type
        @return_type.opaque? ? :void : @return_type.computation
      end

      # @private
      def argument_result_types
        @parameters.map { |type| computation_of(type, "takes") }
      end

      # Calling it from Ruby, so that a body means the same thing run either
      # way.  Slow -- this is the several-hundred-nanosecond path -- and here
      # for testing and for the odd cell, not for sweeping an array.
      #
      # A pointer to numbers takes a CArray, which is the thing in this
      # library that is a run of numbers with a type.  The block sees the
      # array itself and reaches it with `#[]`, the compiled C sees its
      # address and reaches it with a subscript, and `coef[0]` means the same
      # in both -- so the body agrees with itself whichever way it is run.
      def call (*arguments)
        unless arguments.size == @parameters.size
          raise ArgumentError,
                "wrong number of arguments (given #{arguments.size}, " \
                "expected #{@parameters.size})"
        end
        return call_through_shim(arguments) if @shim
        if carries_a_complex?
          raise Unsupported,
                "`#{self}` carries a C99 complex by value, which Fiddle has " \
                "no type for, so it cannot be called from Ruby; a kernel " \
                "calls it as C calls it"
        end
        @function ||= Fiddle::Function.new(@pointer, argument_types,
                                           @return_type.fiddle,
                                           name: @name.to_s)
        arrays = []
        prepared = arguments.zip(@parameters).map { |argument, type|
          next argument unless type.indexable? && argument.is_a?(CArray)
          buffer = check_array(argument, type)
          arrays << [argument, buffer, type]
          buffer
        }
        # Borrowed rather than cleared, and borrowed here rather than on the
        # way in: a call made inside a window -- someone else is holding this
        # function's address and watching the same flag -- must answer for
        # itself without disarming them.  The checks above never reach the C
        # and so never touch the flag at all.
        outer = error_code
        write_error(0)
        begin
          Access.open(arrays.map { |_, buffer, _| buffer },
                      arrays.map { |_, _, type| !type.const },
                      arrays.map { nil }, arrays.map { nil }) do |bases|
            slot = -1
            prepared = prepared.map { |value|
              next value unless arrays.any? { |_, buffer, _| buffer.equal?(value) }
              Fiddle::Pointer.new(bases[slot += 1][:pointer])
            }
            @result = @function.call(*prepared)
          end
          code = error_code
        ensure
          write_error(outer)
        end
        raise_for(code)
        # A view was copied to be made contiguous; a writable one is copied
        # back, because the C wrote into the copy.
        arrays.each do |array, buffer, type|
          array[] = buffer unless type.const || array.equal?(buffer)
        end
        @result
      end

      alias [] call

      # Whether a call from Ruby has to go round through the shim.
      def carries_a_complex?
        @return_type.complex? || @parameters.any?(&:complex?)
      end

      # Fiddle carries no complex, so the shim takes each complex argument as
      # a pair of doubles and writes a complex result back the same way.
      # Everything else keeps the type the declaration gave it and goes
      # through Fiddle as before -- including a pointer parameter, which is
      # still a CArray on this side.
      #
      # It is the same compiled body either way: the shim calls the function,
      # it does not reimplement it.
      def call_through_shim (arguments)
        returns_complex = @return_type.complex?
        types = @parameters.map { |type|
          type.complex? ? Fiddle::TYPE_VOIDP : type.fiddle
        }
        types << Fiddle::TYPE_VOIDP if returns_complex
        @shim_function ||=
          Fiddle::Function.new(@shim, types,
                               returns_complex ? Fiddle::TYPE_VOID
                                               : @return_type.fiddle)
        result = returns_complex ? String.new("\0" * 16) : nil
        arrays = []
        prepared = arguments.zip(@parameters).map { |argument, type|
          next pack_complex(argument, type) if type.complex?
          next argument unless type.indexable? && argument.is_a?(CArray)
          buffer = check_array(argument, type)
          arrays << [argument, buffer, type]
          buffer
        }
        outer = error_code
        write_error(0)
        begin
          Access.open(arrays.map { |_, buffer, _| buffer },
                      arrays.map { |_, _, type| !type.const },
                      arrays.map { nil }, arrays.map { nil }) do |bases|
            slot = -1
            passed = prepared.map { |value|
              next value unless arrays.any? { |_, buffer, _| buffer.equal?(value) }
              Fiddle::Pointer.new(bases[slot += 1][:pointer])
            }
            passed << result if returns_complex
            @result = @shim_function.call(*passed)
          end
          code = error_code
        ensure
          write_error(outer)
        end
        raise_for(code)
        arrays.each do |array, buffer, type|
          array[] = buffer unless type.const || array.equal?(buffer)
        end
        @result = Complex(*result.unpack("dd")) if returns_complex
        @result
      end

      # A Ruby number of any kind arrives as the two doubles the shim reads.
      # `Complex()` is what Ruby itself converts with, so an Integer and a
      # Float are taken where a Complex is asked for, as they are in Ruby.
      def pack_complex (value, type)
        number = begin
                   Complex(value)
                 rescue TypeError, ArgumentError
                   raise Unsupported,
                         "`#{type.text}` takes a number, got #{value.class}"
                 end
        String.new([number.real.to_f, number.imaginary.to_f].pack("dd"))
      end

      # @return [String] the function's name.
      def to_s
        text = "#{@return_type.text} #{@name}" \
               "(#{@parameters.map(&:text).join(', ')})"
        @origin ? "#{text} at #{@origin}" : text
      end

      # @return [String] the prototype this was named by.
      def inspect
        "#<CArray::JIT::CFunction #{self}>"
      end

      # The window a caller opens when it hands the address out.
      #
      # `#call` is one call, and answers for it before it returns.  A library
      # given `#pointer` calls whenever it likes, as often as it likes, and
      # what wants an answer is the whole of that -- so the flag is put down
      # once, the address is lent for as long as the block runs, and what
      # happened is asked for once at the end.  It is the arrangement a kernel
      # already keeps with its own slot, which is cleared before a sweep and
      # read after it, never per cell.
      #
      #   f.watching do
      #     Integration.qags(f.pointer, 0.0, 1.0)
      #   end
      #
      # A failure inside the block outranks whatever the library made of it.
      # A body that fails returns a stand-in, so the library is the first to
      # complain -- that the endpoints do not straddle, that the iteration did
      # not converge -- and those complaints are the failure's consequences,
      # not what happened.  So the flag is read before that exception is let
      # through, and only where nothing stands does the library's own story
      # get to be the story.
      #
      # Windows nest, and a call made inside one leaves it armed: both borrow
      # the flag and put it back as they found it, so an inner window answers
      # for its own block and no other.
      def watching
        outer = error_code
        write_error(0)
        code = 0
        begin
          result = yield
          code = error_code
        rescue StandardError
          raise_for(error_code)
          raise
        ensure
          write_error(outer)
        end
        raise_for(code)
        result
      end

      # Put the flag down, before lending the address to something that will
      # call it more than once.  `#watching` is this and #report_error with
      # the lending in between, and is what to reach for where the window is a
      # block; these two are here for a window that is not -- one opened in
      # one method and closed in another, or one whose block belongs to
      # somebody else.
      def clear_error
        write_error(0)
      end

      # What the kernel raises for the same code, since it is the same thing
      # that happened: `6 % 0` is a ZeroDivisionError wherever it is written,
      # and the compiled body cannot raise it itself.  A caller reaching the
      # address from C sees the stand-in the helper returned and the flag
      # standing, which is C's own arrangement for a function that has to
      # return something whatever happened.
      #
      # Quiet where nothing stands, so that a caller may ask having no idea
      # whether anything failed -- which is the position a caller is in after
      # handing the address to a library.  Asking does not put the flag down:
      # it reads, and the window that put it down is what picks it up.
      def report_error
        raise_for(error_code)
      end

      private

      # 0 where the body cannot fail at all: one that neither divides nor
      # raises is compiled without a flag to read, and has no failure to
      # report rather than an unread one.
      def error_code
        @error ? @error[0, 4].unpack1("l") : 0
      end

      def write_error (code)
        @error[0, 4] = [code].pack("l") if @error
      end

      def raise_for (code)
        case code
        when 0 then nil
        when 1 then raise ZeroDivisionError, "divided by 0"
        when 2 then raise IndexError, "index out of range"
        when 3 then raise ArgumentError,
                            "min argument must be less than or equal to " \
                            "max argument"
        when 4 then raise ArgumentError,
                            "comparison with a NaN failed, so `clamp` has " \
                            "no answer"
        when 5 then raise Math::DomainError,
                            "Numerical argument is out of domain - gamma"
        else
          # `raise "..."` in the body.  The message did not come back through
          # the C -- it was registered when this was compiled -- so it is
          # looked up here, and a kernel that pasted the same body looks the
          # same message up under the same code.
          message = @raise_messages[code]
          raise Error, "#{@name} reported #{code}, which is no failure it " \
                       "was compiled to report" unless message
          raise RuntimeError, message
        end
      end

      # What a pointer parameter will accept, and what has to be true of it.
      # The length is checked only where the declaration carried one: C's own
      # rule is that an unsized pointer is the caller's responsibility, and
      # writing `coef[3]` is how the caller asks to be checked.
      def check_array (array, type)
        wanted = CDeclaration::DATA_TYPES.fetch(type.element.fiddle)
        unless array.data_type_name == wanted.to_s
          raise Unsupported,
                "`#{type.text}` takes a #{wanted} array, and this one is " \
                "#{array.data_type_name}"
        end
        if type.sized? && array.elements < type.array
          raise Unsupported,
                "`#{type.text}` reads #{type.array} " \
                "#{type.array == 1 ? 'element' : 'elements'}, and this array " \
                "has #{array.elements}"
        end
        if array.has_mask?
          # The same thing the kernel refuses when it hands one of its arrays
          # over: a masked cell's bytes are out of contract, and a C function
          # has no mask to consult, so it would read whatever is underneath.
          # Refusing it here as well is what keeps `f.call` and `f.block.call`
          # the same body run two ways -- the block reaches an UNDEF and says
          # so, and the C would have quietly used the number beneath it.
          raise Unsupported,
                "`#{type.text}` is handed an array carrying a mask, and a " \
                "C function has no mask to read; the values under a mask are " \
                "not values, so `#strip_mask(fill)` is what says what the C " \
                "should see there"
        end
        # A pointer is reached contiguously -- `p[i]` with no stride -- and
        # only an entity is laid out that way, so a view is packed into one
        # for the call and copied back afterwards if the C may write to it.
        #
        # `#to_ca` is not the way to pack one: it answers self for a view as
        # well as for an entity, so reaching for it here handed the C a
        # view's base pointer to walk contiguously, which wrote over its
        # neighbours without a word.  `#copy` is the one that always makes an
        # entity.
        Access.classify(array)[:entity] ? array : array.copy
      end

      def computation_of (type, role)
        return type.computation unless type.opaque?
        raise Unsupported,
              "`#{@name}` #{role} `#{type.text}`, which is a slot in the " \
              "signature rather than a value a kernel can compute with"
      end

    end

    # Reads the subset of C declarations a signature may be written in.
    #
    # Fiddle's parser is used for what it is good at -- deciding the ABI code
    # of a type -- and this decides what that parser throws away: whether a
    # parameter is a pointer, and what it was a pointer to.  Between them a
    # prototype yields both what is needed to call a function and what is
    # needed to write one.
    # @private
    module CDeclaration

      PARSER = ::Object.new.extend(Fiddle::CParser)
      private_constant :PARSER

      # The words a type may be spelled with.  `<stdint.h>`'s exact-width
      # names are here because Fiddle knows them; there is no `float64_t`
      # because C has no such type -- its integer types have exact-width
      # aliases and its floating types are `float` and `double`.
      KEYWORDS = %w[
        const unsigned signed void char short int long float double
        _Complex complex
        int8_t int16_t int32_t int64_t
        uint8_t uint16_t uint32_t uint64_t
        size_t ssize_t ptrdiff_t intptr_t uintptr_t
      ].freeze

      # Fiddle has no code for a C99 complex -- its parser does not know the
      # word and the ABI it answers for has nowhere to put one -- so these
      # stand where a Fiddle code stands elsewhere.  Symbols rather than
      # numbers, so that one reaching Fiddle by mistake is a TypeError there
      # and not a silently wrong width.
      COMPLEX_CODES = { "double" => :double_complex,
                        "float"  => :float_complex }.freeze

      # `double complex` is `<complex.h>`'s spelling of `double _Complex`,
      # and both are written; which words a declaration used says nothing
      # about what it declared.
      COMPLEX_WORDS = %w[_Complex complex].freeze

      # Fiddle answers `long double` with the code for `long`, silently, so it
      # is refused by name rather than trusted.
      REFUSED = {
        "long double" => "`long double` is not a type this reads: Fiddle " \
                         "reports it as `long`, which would be the wrong " \
                         "width without saying so",
        "long double _Complex" =>
          "`long double _Complex` is not a type this reads: there is no " \
          "long double here to make one of",
      }.freeze

      # The CArray data type a pointer parameter takes, by the code Fiddle
      # gave its element.  This is the table CGenerator::STORAGE_C_TYPES
      # already holds, read the other way round -- nothing new is decided
      # here about how a C type and a CArray type correspond.
      DATA_TYPES = {
        :double_complex        => :cmplx128,
        :float_complex         => :cmplx64,
        Fiddle::TYPE_DOUBLE    => :float64,
        Fiddle::TYPE_FLOAT     => :float32,
        Fiddle::TYPE_CHAR      => :int8,
        Fiddle::TYPE_UCHAR     => :uint8,
        Fiddle::TYPE_SHORT     => :int16,
        Fiddle::TYPE_USHORT    => :uint16,
        Fiddle::TYPE_INT       => :int32,
        Fiddle::TYPE_UINT      => :uint32,
        Fiddle::TYPE_LONG       => :int64,
        Fiddle::TYPE_LONG_LONG  => :int64,
        # `unsigned long` and `size_t` arrive as the same code, and
        # `uint64_t` as the other one.
        Fiddle::TYPE_ULONG      => :uint64,
        Fiddle::TYPE_ULONG_LONG => :uint64,
      }.freeze

      # Codes Fiddle may return, mapped to what a kernel computes them in.
      # Absent means the type may be written down but holds no value a body
      # can compute with -- `void`, and a pointer to it.
      COMPUTATION = {
        # A `float _Complex` computes in double complex, as a `float`
        # computes in double: the declaration says what the signature is,
        # and the body works in what Ruby would have worked in.
        :double_complex         => :complex,
        :float_complex          => :complex,
        Fiddle::TYPE_DOUBLE     => :double,
        Fiddle::TYPE_FLOAT      => :double,
        Fiddle::TYPE_CHAR       => :int64,
        Fiddle::TYPE_UCHAR      => :int64,
        Fiddle::TYPE_SHORT      => :int64,
        Fiddle::TYPE_USHORT     => :int64,
        Fiddle::TYPE_INT        => :int64,
        Fiddle::TYPE_UINT       => :int64,
        Fiddle::TYPE_LONG       => :int64,
        Fiddle::TYPE_LONG_LONG  => :int64,
        # uint64 is a computation type of its own, precisely because int64
        # cannot carry what it holds; CArray has the array to match.
        Fiddle::TYPE_ULONG      => :uint64,
        Fiddle::TYPE_ULONG_LONG => :uint64,
      }.freeze

      module_function

      # Splits a prototype into [name, return CType, parameter CTypes].  The
      # name is nil for the anonymous form, `double (*)(double)` -- the
      # spelling C already has for the type of a function pointer, which is
      # what this hands out.
      def parse (prototype)
        unless prototype.is_a?(String)
          raise Unsupported,
                "a C prototype is expected, as in `\"double j0(double)\"`; " \
                "got #{prototype.class}"
        end
        text = prototype.strip.sub(/;\z/, "")
        name, return_text, parameter_text = split(text, prototype)
        parameters = split_parameters(parameter_text).map { |part|
          read_type(part, prototype)
        }
        # `f(void)` takes nothing, which is not the same as taking a void.
        parameters = [] if parameters.size == 1 &&
                           parameters.first.text == "void"
        [name, read_type(return_text, prototype), parameters]
      end

      def split (text, prototype)
        if (match = /\A(.+?)\(\s*\*\s*\)\s*\((.*)\)\z/m.match(text))
          [nil, match[1], match[2]]
        elsif (match = /\A(.+?[\s\*])([A-Za-z_]\w*)\s*\((.*)\)\z/m.match(text))
          [match[2], match[1], match[3]]
        else
          raise Unsupported,
                "`#{prototype}` does not read as a C prototype; write it as " \
                "`double j0(double)` to bind one, or `double (*)(double)` " \
                "for one with no name"
        end
      end

      # Top-level commas only.  Nothing in the supported subset nests, so this
      # is a split -- written out so that admitting something that does nest
      # is a change in one place.
      def split_parameters (text)
        return [] if text.strip.empty?
        text.split(",").map(&:strip)
      end

      # `[const] <keywords> [*] [name] [[]]` is the whole grammar there is.
      # A parameter's own name is dropped: nothing reads it for a bound
      # function, and a compiled one uses the block's parameter names.
      def read_type (text, prototype)
        array = nil
        stripped = text.strip.sub(/\[\s*(\d*)\s*\]\s*\z/) {
          array = $1.empty? ? :unsized : $1.to_i
          ""
        }
        words = stripped.split(/\s+|(?=\*)|(?<=\*)/).reject(&:empty?)
        keywords = []
        keywords << words.shift while words.first && KEYWORDS.include?(words.first)
        pointer = false
        while words.first == "*"
          words.shift
          pointer = true
        end
        # Whatever is left can only be the parameter's own name.
        words.shift if words.first&.match?(/\A[A-Za-z_]\w*\z/)
        if keywords.empty? || !words.empty?
          raise Unsupported,
                "`#{text.strip}` in `#{prototype}` is not a type this reads; " \
                "it takes C's own spellings -- `double`, `int32_t`, " \
                "`const double *` and the like"
        end
        build_type(keywords, pointer, array, text, prototype)
      end

      def build_type (keywords, pointer, array, text, prototype)
        spelling = keywords.reject { |word| word == "const" }.join(" ")
        if (reason = REFUSED[spelling])
          raise Unsupported, "#{reason} (in `#{prototype}`)"
        end
        # A parameter written as an array is a pointer at the ABI, whatever
        # its declarator says.
        pointer ||= !array.nil?
        written = keywords.join(" ")
        written += if array
                     " [#{array if array.is_a?(Integer)}]"
                   elsif pointer
                     " *"
                   else
                     ""
                   end
        code = if !pointer && (complex = complex_code(spelling))
                 complex
               else
                 fiddle_code(pointer ? "void *" : spelling, text, prototype)
               end
        # What it points at, for a pointer that points at numbers.  `void *`
        # has no element, which is what keeps it a slot.
        element = nil
        if pointer && spelling != "void"
          element_code = complex_code(spelling) ||
                         fiddle_code(spelling, text, prototype)
          if COMPUTATION[element_code]
            element = CType.new(spelling, element_code,
                                COMPUTATION[element_code], false, nil, nil,
                                false)
          end
        end
        CType.new(written, code, pointer ? nil : COMPUTATION[code], pointer,
                  array, element, keywords.include?("const"))
      end

      # The code for a complex spelling, or nil for anything else.  `float
      # _Complex`, `complex float`, `float complex` -- the word may sit on
      # either side, as C allows.
      def complex_code (spelling)
        words = spelling.split(/\s+/)
        return nil unless (words & COMPLEX_WORDS).any?
        COMPLEX_CODES[(words - COMPLEX_WORDS).join(" ")]
      end

      def fiddle_code (spelling, text, prototype)
        PARSER.parse_ctype(spelling)
      rescue StandardError
        raise Unsupported,
              "`#{text.strip}` in `#{prototype}` is not a type Fiddle knows. " \
              "C's own spellings are what this takes, and `float64_t` is not " \
              "one of them -- C's integer types have exact-width names, its " \
              "floating types are `float` and `double`"
      end

    end

    class << self

      # A C function someone else compiled, reached by quoting its
      # declaration:
      #
      #   j0 = CArray.jit_extern("double j0(double)", from: "libgsl")
      #
      # `from` is where to look -- a path or library name, a Fiddle::Handle,
      # or nothing at all, which searches what the process has already loaded.
      #
      # `extern` is C's own word for a body that lives elsewhere, and that is
      # all this does: it asks Fiddle where the function is.  Nothing is
      # compiled here, which is the difference from `jit_function` and the
      # reason the two are not one method with a branch in it.
      #
      # The declaration is C rather than a vocabulary of this compiler's own,
      # because what is declared is a C function and the types it has to meet
      # belong to whatever will call it.  `void *params` is the point of the
      # exercise, not an edge of it.
      def extern (prototype, from: nil, &block)
        if block
          raise Unsupported,
                "`jit_extern` finds a function already compiled, so a body " \
                "here would be dropped; compile one with `CArray.jit_function`"
        end
        name, return_type, parameters = CDeclaration.parse(prototype)
        unless name
          raise Unsupported,
                "`#{prototype}` names no function to find; give the name, as " \
                "in `double j0(double)` -- or write the body and compile it " \
                "with `CArray.jit_function`"
        end
        bind_c_function(prototype, name, return_type, parameters, from)
      end

      # A C function of your own, written in Ruby and compiled here:
      #
      #   square = CArray.jit_function("double (*)(double)") { |x| x * x + 1 }
      #
      # `double (*)(double)` is the spelling C already has for the type of a
      # function pointer, which is what this hands out.  There is no name
      # because nothing links by name -- the address is what travels -- so a
      # name would have been invented to be looked at once.  Writing one
      # anyway is allowed, and becomes the symbol in the compiled object.
      #
      # What comes back is the same object `jit_extern` hands out, so a kernel
      # calls either without knowing which it has; `compiled?` is where the
      # difference is still visible, along with the block, which it keeps.
      def function (prototype, &block)
        unless block
          raise Unsupported,
                "a function is compiled from a block, and none was given -- " \
                "or find one already compiled with " \
                "`CArray.jit_extern(#{prototype.inspect})`"
        end
        name, return_type, parameters = CDeclaration.parse(prototype)
        compile_c_function(prototype, name, return_type, parameters, block)
      end

      private

      def bind_c_function (prototype, name, return_type, parameters, from)
        handle = library_handle(from)
        begin
          pointer = handle[name.to_s]
        rescue Fiddle::DLError => error
          raise Unsupported,
                "`#{name}` was not found in " \
                "#{from ? from.inspect : "the loaded libraries"} " \
                "(#{error.message}); pass `from:` to say which library it is in"
        end
        CFunction.new(name, prototype, return_type, parameters, pointer)
      end

      # The one function a compiled object holds.  Nothing looks it up by name
      # -- the address is what travels -- but a profiler and a backtrace print
      # it, and a program handing several of these to a solver would otherwise
      # see one name for all of them.  So an anonymous one carries its own
      # digest, and a named one carries the name it was given.
      #
      # Always behind a prefix, though, and that is not tidiness.  A name the
      # C already knows is the dangerous case, and the dangerous case is the
      # one that does *not* fail: `double sin(double)` matches math.h's
      # declaration, so the generated file defines libm's `sin` and the
      # shared object exports it -- where symbols are interposable, that
      # replaces sine for whatever loads it later.  A mismatched signature is
      # a compile error and would have been noticed; this one would not.
      PREFIX = "carray_jit_"

      def function_symbol (name, key)
        digest = Digest::SHA256.hexdigest(key.inspect)[0, 12]
        "#{PREFIX}#{name || "function"}_#{digest}"
      end

      def compile_c_function (prototype, name, return_type, parameters, block)
        node, source, origin = read_block(block)
        # A function this body calls is pasted into it, so which one it is
        # belongs in the key beside the body's own text.  Two blocks spelled
        # the same that reach different functions are different functions,
        # and without this the first compiled would be handed back for the
        # second -- quietly, since nothing about them differs to look at.
        # `kernel_key` is what a kernel already keys a pasted body by: the
        # signature and the symbol, which carries the digest of the body.  A
        # symbol rather than an address, so the key means the same thing in
        # the next process as in this one.
        called = called_functions(source, node, block, name)
        key = [source, return_type.text, parameters.map(&:text), name,
               called.values.map(&:kernel_key)]
        found = function_registry[key]
        return found if found
        function_registry[key] =
          build_c_function(prototype, name, return_type, parameters,
                      source, node, origin, block, function_symbol(name, key),
                      called)
      end

      # The compiled functions the block reaches for, by the name it reaches
      # them by.  Only these: everything else it closes over is refused, and
      # `refuse_captures` is where that is said.  This runs before the
      # registry is consulted, because the key cannot be built without it.
      def called_functions (source, node, block, own_name)
        names = capture_names(source, node) - block.parameters.map(&:last)
        names -= [own_name.to_sym] if own_name
        binding = binding_of(block)
        names.each_with_object({}) do |captured, found|
          value = captured_value(captured, binding)
          found[captured] = value if value.is_a?(CFunction) && value.pasted?
        end
      end

      # What a name held where the block was written, or nil for one that
      # held nothing.  A constant is looked up as well as a local, because a
      # method body closes over nothing: a `def` that compiles a function
      # reaches the one it calls by a constant or not at all.
      def captured_value (name, binding)
        if name.to_s.start_with?(/[A-Z]/)
          binding.eval(name.to_s)
        elsif binding.local_variable_defined?(name)
          binding.local_variable_get(name)
        end
      rescue NameError
        nil
      end

      # Whether the name held anything at all, which `captured_value` cannot
      # say: a name holding nil and a name that is not there both come back
      # as nil, and only one of them is worth a different message.
      def captured_name_defined? (name, binding)
        if name.to_s.start_with?(/[A-Z]/)
          binding.eval("defined?(#{name})") ? true : false
        else
          binding.local_variable_defined?(name)
        end
      rescue NameError
        false
      end

      def function_registry
        @function_registry ||= {}
      end

      def build_c_function (prototype, name, return_type, parameters,
                       source, node, origin, block, symbol, called = {})
        # A function is a function of its parameters.  Whatever else the block
        # reaches for is refused, and the reason differs by what it is -- so
        # the captures are looked at before the body is walked, or the body
        # would raise first and say something less useful.
        names = block.parameters.map(&:last)
        unless names.size == parameters.size
          raise Unsupported,
                "`#{prototype}` names #{parameters.size} " \
                "#{parameters.size == 1 ? 'parameter' : 'parameters'}, and " \
                "the block takes #{names.size}"
        end
        refuse_captures(source, node, block, names + called.keys,
                        name && name.to_sym)

        # `void` is a return type a body may have: a function whose work is
        # through its pointer parameters has nothing to hand back, and C says
        # so with the word.  What it cannot be called in is expression
        # position, which is where the value would have been wanted -- that
        # is the same refusal a borrowed `void` function already gets.
        #
        # Every other return type with no computation behind it is a pointer,
        # which a body cannot produce: there is nothing here to take an
        # address of that would outlive the call.
        returns_nothing = return_type.fiddle == Fiddle::TYPE_VOID &&
                          !return_type.pointer
        unless return_type.computation || returns_nothing
          raise Unsupported,
                "`#{prototype}` returns `#{return_type.text}`, which is no " \
                "value a compiled body can produce"
        end

        # A pointer to numbers is indexable, and `const` says whether it may
        # be written through -- which is the whole of the read/write
        # distinction, spelled the way C spells it.
        pointers = names.zip(parameters).select { |_, type| type.pointer }
                        .to_h { |name, type|
                          [name, type.indexable? ? !type.const : nil]
                        }
        pointer_types = names.zip(parameters).select { |_, type| type.indexable? }
                             .to_h { |name, type| [name, type.element.computation] }

        # A declaration that gave a name puts that name in scope inside its
        # own body, as C does, so the body can call itself.  An anonymous one
        # has nothing to call itself by, and gets no recursion.
        analyzer = Analyzer.new(source, node: node, function: true,
                                returns: !returns_nothing,
                                pointers: pointers,
                                c_functions: called,
                                recursion: (name && [name.to_sym, parameters,
                                                     return_type.computation]))
        names = analyzer.parameter_names
        # A pointer is not a value however it is spelled: `void *` cannot be
        # reached at all, and one that points at numbers has to be indexed.
        by_name = names.zip(parameters).to_h
        loose = analyzer.scalar_names.find { |name|
          by_name[name] && by_name[name].pointer
        }
        if loose
          type = by_name.fetch(loose)
          raise Unsupported,
                (if type.indexable?
                   "`#{loose}` is declared `#{type.text}`, which is a pointer; " \
                   "index it, as in `#{loose}[0]`"
                 else
                   "`#{loose}` is declared `#{type.text}`, which is a slot in " \
                   "the signature rather than a value; the body cannot read it"
                 end)
        end
        # A parameter of any computation type the body can work in, uint64
        # included.  A kernel's captures have three buses to travel in and
        # uint64 is not one of them, but these are not captures: they are the
        # parameters of this function's own C signature, and arrive in the
        # type the declaration named.  So `size_t n` is a value the body can
        # be handed, which is the point -- it is how the C that counts bytes
        # is spelled.
        types = names.zip(parameters).reject { |_, type| type.pointer }
                     .to_h { |parameter, type| [parameter, type.computation] }

        assignment = TypeAssignment.new(analyzer.body, {}, {}, called,
                                        scalar_types: types,
                                        pointer_types: pointer_types)
        generator = CGenerator.new(analyzer, {}, assignment.scalar_types,
                                   c_functions: called,
                                   origin: origin, block_source: source,
                                   scalar_parameters: types.keys)
        c_source = generator.generate_function(
          symbol, names, parameters, return_type.text, return_type.computation)
        # A signature carrying a complex by value gets a second entry point
        # for Ruby to reach it by, since Fiddle has no such type to call
        # with.  Only such a signature: everything else is called directly,
        # and pays nothing for a road it does not take.
        shim_symbol = nil
        if return_type.complex? || parameters.any?(&:complex?)
          shim_symbol = "#{symbol}_from_ruby"
          c_source += shim_source(shim_symbol, symbol, names, parameters,
                                  return_type)
        end
        handle, = Compiler.build(c_source, symbol, header: generator.provenance)
        # Where the body can divide by zero or reach outside an array, the
        # object carries a place to say so.  Reading it is what lets a call
        # from Ruby raise what the same expression raises in Ruby.
        error = if generator.uses_error_flag?
                  Fiddle::Pointer.new(handle[CGenerator::ERROR_FLAG], 4)
                end
        # A body that reports failures is generated a second time for pasting,
        # with the flag as a parameter.  A second generator rather than the
        # same one twice: what it emitted is what it holds, and the two forms
        # differ from the first statement that can fail onwards.
        pasted = generator
        if generator.uses_error_flag?
          pasted = CGenerator.new(analyzer, {}, assignment.scalar_types,
                                  c_functions: called,
                                  origin: origin, block_source: source,
                                  scalar_parameters: types.keys)
          pasted.generate_function(symbol, names, parameters, return_type.text,
                                   return_type.computation,
                                   error_parameter: true)
        end
        CFunction.new(symbol, prototype, return_type, parameters, handle[symbol],
                  shim: shim_symbol && handle[shim_symbol],
                  block: block, c_source: generator.provenance + c_source,
                  origin: origin, error: error,
                  definition: pasted.function_definition,
                  helpers: pasted.helper_needs,
                  dependencies: called.values,
                  takes_error: generator.uses_error_flag?,
                  raise_messages: generator.raise_messages)
      end

      # The entry point a call from Ruby takes where the signature carries a
      # complex by value.  Each complex argument arrives as the two doubles
      # C99 lays one out as, and a complex result is written back the same
      # way; every other parameter keeps its own type, so a pointer is still
      # a pointer and an integer is still that integer.
      #
      # It calls the function rather than repeating it, so there is one body
      # and both roads reach it.
      def shim_source (shim_symbol, symbol, names, parameters, return_type)
        declarations = names.zip(parameters).map { |name, type|
          type.complex? ? "const double *#{name}" : type.declare(name)
        }
        passed = names.zip(parameters).map { |name, type|
          next name unless type.complex?
          "#{type.complex_build}(#{name}[0], #{name}[1])"
        }
        call = "#{symbol}(#{passed.join(', ')})"
        if return_type.complex?
          declarations << "double *carray_jit_result"
          body = <<~C
            #{return_type.text} carray_jit_value = #{call};
              carray_jit_result[0] = creal(carray_jit_value);
              carray_jit_result[1] = cimag(carray_jit_value);
          C
          head = "void"
        else
          body = "#{return_type.computation ? 'return ' : ''}#{call};\n"
          head = return_type.text
        end
        <<~C

          /* Fiddle has no type for a C99 complex, so a call from Ruby comes
             through here: the complex arguments arrive as the two doubles
             one is laid out as, and a complex result goes back the same way.
             A kernel calls the function above directly, C to C. */
          #{head}
          #{shim_symbol} (#{declarations.join(', ')})
          {
            #{body.strip}
          }
        C
      end

      # Nothing outside the parameter list may be reached.  A number could in
      # principle be written into the C as a literal, and another c_function's
      # address as a constant -- but both would put something in the compiled
      # object that no key covers, so an object built for one capture would be
      # handed back for another.  The kernel path avoids that by passing
      # captures in buffers at call time; a C function has no buffers, so its
      # parameters are its whole surface.
      #
      # Read the other way round, this is what makes the body's text and the
      # signature a complete key: with nothing captured, they settle which
      # function it is.  And it is what makes the compiled object pure C -- it
      # touches no Ruby value and references no Ruby symbol, so the address is
      # safe to call from a thread that holds no GVL, which is more than a
      # Ruby-defined callback usually manages.
      def refuse_captures (source, node, block, parameters, own_name = nil)
        captured = capture_names(source, node) - parameters
        # The function's own name is not a capture: it is the declarator's,
        # in scope inside the body it heads, exactly as C has it.  What the
        # local holds while the body is being compiled is nothing -- the
        # assignment has not happened yet -- and the compiled call reaches
        # the symbol, not the local.
        captured -= [own_name] if own_name
        return if captured.empty?
        name = captured.first
        value = captured_value(name, binding_of(block))
        if value.is_a?(CFunction)
          # A function compiled here is pasted into this one, so it is no
          # longer a capture at all -- it never reaches the list above.  One
          # borrowed from a library is only an address, and an address is
          # what a compiled object has nowhere to keep: a kernel is handed
          # its own at call time, and a function has no such moment.
          raise Unsupported,
                "this function reaches `#{name}`, which was bound with " \
                "`jit_extern` and so is only an address; a compiled function " \
                "has nowhere to keep one. Take it as a parameter, or compile " \
                "the body here with `CArray.jit_function`"
        end
        unless captured_name_defined?(name, binding_of(block))
          raise Unsupported,
                "`#{name}` is not defined where the block was written"
        end
        kind = value.is_a?(CArray) ? "an array" : "a value"
        raise Unsupported,
              "this function reaches `#{name}`, which is #{kind} outside it; " \
              "a compiled function takes everything it needs through its " \
              "parameters, so name it as one"
      end

      def library_handle (from)
        case from
        when nil            then Fiddle::Handle::DEFAULT
        when Fiddle::Handle then from
        when String         then Fiddle::Handle.new(from)
        else
          raise Unsupported,
                "`from:` takes a library name or a Fiddle::Handle, " \
                "got #{from.class}"
        end
      end

    end

  end
end
