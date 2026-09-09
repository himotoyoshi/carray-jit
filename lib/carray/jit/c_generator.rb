require "digest"

class CArray
  module JIT

    # Emits C for a typed kernel body.
    #
    # The output is meant to be read: real indentation, the same variable
    # names the block used, and casts only where a type actually changes.
    # `CARRAY_JIT_DUMP=1` prints it.
    #
    # Every kernel has the same C signature, so one Fiddle::Function shape
    # serves all of them; the per-kernel detail is unpacked into named locals
    # at the top of the body, where it also reads better.
    class CGenerator

      STORAGE_C_TYPES = {
        "float64" => "double",
        "float32" => "float",
        "int64"   => "int64_t",
        "int32"   => "int32_t",
        "int16"   => "int16_t",
        "int8"    => "int8_t",
        "uint64"  => "uint64_t",
        "uint32"  => "uint32_t",
        "uint16"  => "uint16_t",
        "uint8"   => "uint8_t",
        "boolean" => "uint8_t",
        # C99 lays a complex out as two reals in order, which is what CArray
        # stores, so a cell is read in place rather than assembled.
        "cmplx64"  => "float _Complex",
        "cmplx128" => "double _Complex",
      }.freeze

      COMPUTATION_C_TYPES = {
        :double  => "double",
        :float   => "float",
        :int64   => "int64_t",
        :uint64  => "uint64_t",
        :complex => "double _Complex",
        :float_complex => "float _Complex",
        :boolean => "int",
      }.freeze

      # How far each numeric type has to be widened to reach another, taken
      # from the order they widen in.  Only widening is ever emitted: nothing
      # narrows a complex back to a real without the block having asked for
      # it by name.
      NUMERIC_RANK =
        TypeAssignment::NUMERIC_TYPES.each_with_index.to_h.freeze

      FUNCTION_NAME = "carray_jit_kernel"

      # The frame's own entry point.  Same signature, same statements, and
      # the reads carry the border rule; the caller walks it over the boxes
      # the interior left, so nothing here has to know which cell is which.
      BORDER_NAME = "carray_jit_border"

      # `functions` carries the address of each C function the block called,
      # beside the captured scalars: the kernel is not linked against them, so
      # a compiled kernel does not depend on where they came from.
      # `functions` carries the address of each C function the block called and
      # `data` the address of each array it handed to one whole.  Both sit
      # beside the captured scalars for the same reason: they do not vary with
      # the cell, and the kernel is not linked against either.
      SIGNATURE =
        "(char **pointers, int64_t *strides, int64_t *bounds, " \
        "double *reals, int64_t *integers, void **functions, void **data, " \
        "char **mask_pointers, int64_t *mask_strides, int32_t *error)".freeze

      # Names an index may not take, because the C it becomes is written with
      # them: the kernel's own parameters above, and the words C keeps for
      # itself.  A name from either list compiles to something else or to
      # nothing, and the compiler's complaint is about a source the block's
      # author did not write.
      RESERVED_NAMES =
        (SIGNATURE.scan(/\*?(\w+)[,)]/).flatten +
         %w[auto break case char const continue default do double else enum
            extern float for goto if inline int long register restrict return
            short signed sizeof static struct switch typedef union unsigned
            void volatile while]).map(&:to_sym).freeze

      ARGUMENTS =
        "pointers, strides, bounds, reals, integers, functions, data, " \
        "mask_pointers, mask_strides, error".freeze

      # Higher binds tighter.  Used to parenthesize only where C would
      # otherwise regroup the expression.
      # C's precedence, not Ruby's: the tree comes from Prism, and what this
      # table decides is where the parentheses go on the way out.
      PRECEDENCE = {
        :*    => 80, :/ => 80,
        :+    => 70, :- => 70,
        :<<   => 65, :>> => 65,
        :<    => 60, :<= => 60, :> => 60, :>= => 60,
        :==   => 55, :!= => 55,
        :&    => 52,
        :^    => 50,
        :|    => 48,
        :"&&" => 40,
        :"||" => 35,
      }.freeze

      LEAF_PRECEDENCE  = 100
      UNARY_PRECEDENCE = 90

      # cmplx64's helpers are the same helpers in the narrower width, so they
      # are written once and spelled twice rather than kept in step by hand.
      # The substitution is textual and the order matters -- `double _Complex`
      # before `double` -- which is why it is a list and not a hash.
      NARROW_COMPLEX_SPELLING = [
        ["double _Complex", "float _Complex"],
        ["carray_jit_", "carray_jit_f_"],
        ["creal", "crealf"], ["cimag", "cimagf"],
        ["CMPLX(", "CMPLXF("], ["fabs(", "fabsf("],
        ["double", "float"], ["1.0", "1.0f"], ["0.0", "0.0f"],
      ].freeze

      def self.narrowed_complex_helper (text)
        NARROW_COMPLEX_SPELLING.reduce(text) { |source, (wide, narrow)|
          source.gsub(wide, narrow)
        }
      end

      # The complex operations Ruby does not compute the way C's operators
      # would.  Only the ones a kernel actually uses are emitted, and the
      # reason each exists is at emit_complex_binary.
      COMPLEX_HELPERS = {
        "complex_add_real" => <<~C,
          /* Ruby leaves the imaginary part of `z + x` exactly as it was,
             rather than adding the real operand's zero to it. */
          static inline double _Complex
          carray_jit_complex_add_real (double _Complex z, double x)
          {
            return CMPLX(creal(z) + x, cimag(z));
          }
        C
        "real_add_complex" => <<~C,
          /* And the same the other way round: `x + z` leaves it alone too. */
          static inline double _Complex
          carray_jit_real_add_complex (double x, double _Complex z)
          {
            return CMPLX(x + creal(z), cimag(z));
          }
        C
        "complex_add_imaginary" => <<~C,
          /* `z + 2i` adds to one part and leaves the other, for the same
             reason: the literal's real part is an exact zero. */
          static inline double _Complex
          carray_jit_complex_add_imaginary (double _Complex z, double y)
          {
            return CMPLX(creal(z), cimag(z) + y);
          }
        C
        "imaginary_add_complex" => <<~C,
          static inline double _Complex
          carray_jit_imaginary_add_complex (double y, double _Complex z)
          {
            return CMPLX(creal(z), y + cimag(z));
          }
        C
        "complex_mul_real" => <<~C,
          /* `z * x` scales each part.  `x * z` does not -- Ruby coerces the
             x and multiplies in full -- so it is left to C's operator. */
          static inline double _Complex
          carray_jit_complex_mul_real (double _Complex z, double x)
          {
            return CMPLX(creal(z) * x, cimag(z) * x);
          }
        C
        "complex_div_real" => <<~C,
          static inline double _Complex
          carray_jit_complex_div_real (double _Complex z, double x)
          {
            return CMPLX(creal(z) / x, cimag(z) / x);
          }
        C
        "complex_divide" => <<~C,
          /* Ruby divides one Complex by another with Smith's method, and so
             does this -- in the order complex.c writes it, because the last
             bit of the answer depends on that order and the C library's own
             __divdc3 arrives at a different one. */
          static inline double _Complex
          carray_jit_complex_divide (double _Complex a, double _Complex b)
          {
            double are = creal(a), aim = cimag(a);
            double bre = creal(b), bim = cimag(b);
            double r, n;
            if ( fabs(bre) > fabs(bim) ) {
              r = bim / bre;
              n = bre * (1.0 + r * r);
              return CMPLX((are + aim * r) / n, (aim - are * r) / n);
            }
            r = bre / bim;
            n = bim * (1.0 + r * r);
            return CMPLX((are * r + aim) / n, (aim * r - are) / n);
          }
        C
        "real_divide_complex" => <<~C,
          /* The same method for a real numerator, which Ruby coerces to a
             Complex whose imaginary part is an exact Integer zero.  That
             zero multiplies like a float -- `0 * r` carries r's sign -- but
             adds like an exact one, which f_add returns the other operand
             for.  So `+ 0.0 * r` appears on one branch and not on the other,
             and the signs of the zeros in the answer depend on it. */
          static inline double _Complex
          carray_jit_real_divide_complex (double a, double _Complex b)
          {
            double bre = creal(b), bim = cimag(b);
            double r, n;
            if ( fabs(bre) > fabs(bim) ) {
              r = bim / bre;
              n = bre * (1.0 + r * r);
              return CMPLX((a + 0.0 * r) / n, (0.0 - a * r) / n);
            }
            r = bre / bim;
            n = bim * (1.0 + r * r);
            return CMPLX(a * r / n, (0.0 * r - a) / n);
          }
        C
      }.freeze

      # What an accumulator starts from, per computation type.  A complex sum
      # starts from a complex zero: CMPLX carries the sign of both zeros,
      # which a plain 0.0 widened to complex would not.
      ZEROES = {
        :int64   => "INT64_C(0)",
        :float   => "0.0f",
        :uint64  => "UINT64_C(0)",
        :double  => "0.0",
        :complex => "CMPLX(0.0, 0.0)",
        :float_complex => "CMPLXF(0.0f, 0.0f)",
      }.freeze

      # What a product accumulator starts from, for the same reason.
      ONES = {
        :int64   => "INT64_C(1)",
        :float   => "1.0f",
        :uint64  => "UINT64_C(1)",
        :double  => "1.0",
        :complex => "CMPLX(1.0, 0.0)",
        :float_complex => "CMPLXF(1.0f, 0.0f)",
      }.freeze

      # How many partial accumulators a licensed reduction runs.  A serial
      # accumulator is one dependent chain of additions and waits out the
      # latency of each; eight of them fill it.  Measured over row sums and a
      # matrix multiply, eight is where the gain stops growing.
      #
      # The number is here, and the order it implies is written into the C,
      # rather than left to the compiler's unroller: this gem compiles on the
      # machine it runs on, so a schedule chosen by the compiler would vary
      # with the machine and with nothing in the source saying so.
      PARTIAL_ACCUMULATORS = 8

      BORDER_RULES = [:zero, :clamp, :wrap].freeze

      def initialize (analyzer, storage_types, scalar_types, c_functions: {},
                      masked: false, reassociate: false,
                      steps: nil, origin: nil, block_source: nil, border: nil)
        @masked = masked
        # What a window read gets where it falls off the array.  Nil for every
        # kernel but a stencil's, and for a stencil whose border is the frame
        # rather than a rule -- `:mask` and `:skip` are cells the loop never
        # reaches, and a cell not reached needs no C.
        @border = border
        # True while the border body is being emitted, which is the same
        # statements as the interior with the rule woven into the reads.
        @bordering = false
        @reassociate = reassociate
        @steps = steps || Array.new(analyzer.rank, 1)
        @analyzer = analyzer
        @storage_types = storage_types
        @scalar_types = scalar_types
        @arrays = analyzer.arrays_used.sort
        # Arrays no longer share a rank, so each one's strides start where the
        # previous one's left off.
        @stride_offsets = {}
        position = 0
        @arrays.each do |array|
          @stride_offsets[array] = position
          position += analyzer.array_ranks.fetch(array, analyzer.rank)
        end
        @array_ranks = analyzer.array_ranks
        @reals = analyzer.scalar_names.select { |name| scalar_types[name] == :double }.sort
        @integers = analyzer.scalar_names.select { |name| scalar_types[name] == :int64 }.sort
        # A captured Complex rides in the reals buffer as its two parts, so
        # that the kernel signature stays the one shape every kernel has.
        @complexes = analyzer.scalar_names.select { |name| scalar_types[name] == :complex }.sort
        # Three buses and no fourth: a capture whose type is none of these
        # would be packed into nothing and read as whatever the slot held, so
        # it is caught here rather than at the cell it computes wrongly.
        carried = @reals.size + @integers.size + @complexes.size
        unless carried == analyzer.scalar_names.size
          missing = analyzer.scalar_names - @reals - @integers - @complexes
          raise Error,
                "captured #{missing.join(", ")} travel in none of the kernel's " \
                "three scalar buses; a computation type was added without a " \
                "way to hand a value of it to the C"
        end
        # Only the ones the block actually called, in a fixed order, because
        # the caller packs the addresses into `functions` by this order.
        @c_functions = analyzer.c_function_names.sort.to_h { |name| [name, c_functions.fetch(name)] }
        # A function written here is pasted into this kernel and called by its
        # symbol; a borrowed one arrives as an address.  Only the second kind
        # takes a slot in `functions`, so it is that hash the caller packs by.
        pasted, addressed = @c_functions.partition { |_, function| function.pasted? }
        @pasted_functions = pasted.to_h
        @address_functions = addressed.to_h
        # Arrays handed to a C function whole, in a fixed order, because the
        # caller packs their addresses into `data` by this order.
        @address_arrays = analyzer.address_arrays.sort
        @address_parameters = analyzer.address_parameters
        @rank = analyzer.rank
        # Every axis some array is read at a computed index.  Each needs its
        # extent inside the kernel, to check the index against as it is
        # reached; they ride in after the captured integers.
        @extent_slots = @arrays.flat_map { |array|
          axes = analyzer.dynamic_axes(array)
          # A border rule is applied against the extent, so a windowed array
          # needs every one of its axes here -- the same slots a computed
          # subscript already rides in, asked for by a different question.
          if @border && analyzer.windows.include?(array)
            axes |= (0...array_rank_of(analyzer, array)).to_a
          end
          axes.sort.map { |axis| [array, axis] }
        }
        @uses_index_check = false
        @body_reports = false
        @uses_clamp = false
        @uses_wrap = false
        @uses_real_arg = false
        @complex_helpers = []
        @uses_floor_divide = false
        @uses_floor_modulo = false
        @uses_integer_power = false
        @uses_unsigned_divide = false
        @uses_unsigned_modulo = false
        @uses_unsigned_power = false
        @uses_floor_modulo_float = false
        @contiguous = false
        @in_function = false
        @uses_error_flag = false
        @error_parameter = false
        @masked_flag = nil
        @carried_masks = []
        # What `raise` in the block said, by the code a cell writes into the
        # error slot to say which one it was -- and what the bodies pasted in
        # here can say, since their codes come back through the same slot and
        # this kernel is what answers for them.  The codes agree because they
        # are taken from the messages, not counted off.
        @raise_messages = {}
        pasted_closure.each do |function|
          (function.raise_messages || {}).each do |code, message|
            register_raise(code, message)
          end
        end
        @position_temporaries = {}.compare_by_identity
        @origin = origin
        @block_source = block_source
      end

      attr_reader :arrays, :reals, :integers, :complexes, :masked, :extent_slots,
                  :c_functions, :pasted_functions, :address_functions,
                  :address_arrays, :address_parameters,
                  # The messages `raise` in the block gave, by the code a cell
                  # writes into the error slot to say which one it was.
                  :raise_messages

      # Whether the compiled function reports through the flag, so the caller
      # knows whether to look the symbol up.
      def uses_error_flag?
        @uses_error_flag
      end

      def generate
        strided = build_body(false)
        contiguous = build_body(true)
        # The frame is walked strided, whatever the operands are: it is a
        # handful of boxes cut out of the array, and the innermost of them is
        # not the run of cells the contiguous path is for.
        border = @border ? bordered_body : nil
        preamble +
          "static void\ncarray_jit_strided #{SIGNATURE}\n" + strided + "\n" +
          "static void\ncarray_jit_contiguous #{SIGNATURE}\n" + contiguous + "\n" +
          dispatcher +
          (border ? "\nvoid\n#{BORDER_NAME} #{SIGNATURE}\n" + border : "")
      end

      # The same tree a third time.  `generate` already emits it twice, for
      # the contiguous and strided ways of reaching a cell; the border is the
      # third way, and differs only in what a read that falls off the array
      # gives.  Nothing about the loop changes -- the caller says which cells.
      def bordered_body
        @bordering = true
        build_body(false)
      ensure
        @bordering = false
      end

      # A scalar C function: no buffers, no loop, no dispatcher.  The body is
      # the same statements the kernel path emits -- what differs is only what
      # surrounds them, which is why the expression emitter below is shared
      # rather than written twice.
      # `error_parameter` generates the form a kernel pastes: the flag arrives
      # as a trailing `int32_t *` rather than standing in the file, so the body
      # reports into whatever the caller is watching.  The standalone object
      # keeps the other form -- it is what `CFunction#call` reads, and what a
      # library handed the address calls without knowing about any of this.
      def generate_function (name, parameter_names, parameter_c_types,
                             return_c_type, return_type, error_parameter: false)
        @own_symbol = name
        @in_function = true
        @error_parameter = error_parameter
        @contiguous = true
        @declared_locals = {}
        @temporary_count = 0
        @carried_masks = []
        statements = @analyzer.body.statements
        # A `void` body has no last expression to return: every statement in
        # it is a statement, and what it did is where its pointers pointed.
        @returns_nothing = return_type.nil?
        held = @returns_nothing ? statements : statements[0..-2]
        lines = held.map { |statement| emit_statement(statement, "  ") }.join
        value = @returns_nothing ? nil : emit(statements.last, return_type)
        parameters = parameter_names.zip(parameter_c_types)
                       .map { |parameter, type| type.declare(parameter) }
        # Passed whether or not the body turned out to use it, so that a
        # recursive call emitted before the first division still passes the
        # same argument list the definition ends up declaring.
        parameters << "int32_t *#{ERROR_FLAG}" if error_parameter
        parameters = ["void"] if parameters.empty?
        flag = @uses_error_flag && !error_parameter ? error_flag_declaration : ""
        # Kept apart from the file it is compiled in: the definition alone is
        # what a kernel pastes into its own translation unit, where the
        # includes are already written and the helpers are shared.
        @function_definition =
          "#{return_c_type}\n#{name} (#{parameters.join(', ')})\n{\n" +
          lines + (@returns_nothing ? "}\n" : "  return #{value};\n}\n")
        preamble + flag + @function_definition
      end

      attr_reader :function_definition

      # What the body took from the preamble, so that a definition pasted
      # somewhere else can be given the same helpers.  Only the ones a pasted
      # function can want are here: the rest -- the index check, the two
      # flooring helpers -- report through the error flag, and a function that
      # touches the flag is not pasted at all.
      def helper_needs
        { :integer_power => @uses_integer_power,
          :unsigned_divide => @uses_unsigned_divide,
          :unsigned_modulo => @uses_unsigned_modulo,
          :unsigned_power => @uses_unsigned_power,
          :floor_modulo_float => @uses_floor_modulo_float,
          :real_arg => @uses_real_arg,
          :complex => @complex_helpers.dup,
          :index_check => @uses_index_check,
          :floor_divide => @uses_floor_divide,
          :floor_modulo => @uses_floor_modulo }
      end

      # One per compiled object, so two functions never share it, and zeroed
      # by whoever is about to look -- the same discipline the kernel's own
      # error slot keeps.  It is written only where the value returned is
      # already a stand-in, so a caller that never looks is no worse off than
      # C leaves it.
      def error_flag_declaration
        "/* Standing at 1 when a division had no divisor, and at the code of\n" \
        "   a `raise` in the body where one was reached -- the numbers a\n" \
        "   kernel reports through its own slot, with the same meanings.  A\n" \
        "   subscript on a pointer parameter is not checked here and does not\n" \
        "   appear: it is the caller's business, as it is in C. */\n" \
        "int32_t #{ERROR_FLAG} = 0;\n\n"
      end

      # The same kernel, wrapped so carray can drive it.
      #
      # `ca_call_cslab_N` hands a callback one chunk at a time -- base and
      # stride per operand and a cell count -- which is what this kernel's
      # first three arguments already are, with the bounds of a flat sweep.
      # So the wrapper is a call, not a second code generator: the loop, the
      # arithmetic and the contiguous/strided split are the ones above.
      #
      # The mask is carray's here.  It ORs the inputs' masks, propagates the
      # result to the output, and hands the chunk's slice over -- which this
      # ignores, computing every cell as the kernel does anyway, because the
      # bytes under a mask are out of contract and a branchless loop is the
      # point.  What carray cannot express is a body that *asks* about a
      # mask, so those do not come this way.
      SLAB_SIGNATURE =
        "(char **base, int64_t *stride, int64_t n, " \
        "const uint8_t *m0, void *userdata)".freeze

      def generate_slab (name)
        generate + <<~C

          /* What the sweep cannot carry: the captured values, the C functions
             and the arrays handed to one whole.  carray passes one pointer
             through untouched, so they travel behind it. */
          struct carray_jit_slab_context {
            double  *reals;
            int64_t *integers;
            void   **functions;
            void   **data;
            char   **mask_pointers;
            int64_t *mask_strides;
            int32_t *error;
          };

          void
          #{name} #{SLAB_SIGNATURE}
          {
            const struct carray_jit_slab_context *const context = userdata;
            int64_t bounds[3];
            (void) m0;
            bounds[0] = 0;
            bounds[1] = n;
            bounds[2] = 1;
            #{FUNCTION_NAME}(base, stride, bounds,
                             context->reals, context->integers,
                             context->functions, context->data,
                             context->mask_pointers, context->mask_strides,
                             context->error);
          }
        C
      end

      # Where this came from.  A generated file that says only what it does is
      # hard to place months later; the block it was written from is short, so
      # it goes in whole, above the C it turned into.
      def provenance
        return "" unless @origin || @block_source
        text = +"/*\n *  Generated by carray-jit #{VERSION}.\n"
        text << " *\n *  #{@origin}\n" if @origin
        if @block_source
          text << " *\n"
          @block_source.lines.each { |line| text << " *    #{line.rstrip}\n" }
        end
        text << " */\n\n"
        text
      end

      private

      def preamble
        # A pasted body wants the same helpers here that it had in its own
        # file, and it is emitted below them, so this is asked before any of
        # them is written out.
        pasted_closure.each do |function|
          needs = function.helpers || {}
          @uses_integer_power ||= needs[:integer_power]
          @uses_unsigned_divide ||= needs[:unsigned_divide]
          @uses_unsigned_modulo ||= needs[:unsigned_modulo]
          @uses_unsigned_power ||= needs[:unsigned_power]
          @uses_floor_modulo_float ||= needs[:floor_modulo_float]
          @uses_real_arg ||= needs[:real_arg]
          @complex_helpers |= needs[:complex] || []
          @uses_index_check ||= needs[:index_check]
          @uses_floor_divide ||= needs[:floor_divide]
          @uses_floor_modulo ||= needs[:floor_modulo]
        end
        text = +"#include <stdint.h>\n#include <math.h>\n#include <complex.h>\n" \
                "#include <stdio.h>\n\n"
        unless @address_functions.empty?
          text << "/* The C functions the block called.  They arrive as\n" \
                  "   addresses rather than by linkage, so nothing here says\n" \
                  "   which library they came from. */\n"
          @address_functions.each_key do |name|
            text << @address_functions.fetch(name).c_declaration(c_function_type_name(name)) << "\n"
          end
          text << "\n"
        end
        if @masked
          text << <<~C
            /* A plain CArray has no mask at all -- one is created only when a
               cell is actually marked -- so an unmasked operand is pointed at
               this single zero byte with a stride of zero.  Reading it costs
               a load the compiler hoists, and saves a branch per cell. */
            static const uint8_t carray_jit_present = 0;

          C
        end
        if @uses_floor_modulo_float
          text << <<~C
            /* The float twin of carray_jit_floor_modulo_real.  Going through
               the double one and rounding back would not give the same answer:
               a remainder is the tail of a subtraction, so it is exactly where
               computing wide and narrowing afterwards stops agreeing with
               computing narrow. */
            static inline float
            carray_jit_floor_modulo_float (float numerator, float denominator)
            {
              float remainder = fmodf(numerator, denominator);
              if ( remainder != 0 ) {
                if ( (remainder < 0) != (denominator < 0) ) remainder += denominator;
              }
              else {
                remainder = copysignf(0.0f, denominator);
              }
              return remainder;
            }

          C
        end
        if @uses_unsigned_power
          text << <<~C
            /* The unsigned twin of carray_jit_integer_power.  Squaring in
               uint64_t keeps the wrap CArray's own uint64 operators have,
               where int64_t would take the value through a signed type it
               may not fit. */
            static inline uint64_t
            carray_jit_unsigned_power (uint64_t base, uint64_t exponent)
            {
              uint64_t result = 1;
              while ( exponent ) {
                if ( exponent & 1 ) result *= base;
                base *= base;
                exponent >>= 1;
              }
              return result;
            }

          C
        end
        if @uses_unsigned_divide
          text << <<~C
            /* An unsigned operand cannot be negative, so C's truncation
               already floors and there is no quotient to correct -- what is
               left of carray_jit_floor_divide is the zero divisor, which is
               reported through *error the same way. */
            static inline uint64_t
            carray_jit_unsigned_divide (uint64_t numerator, uint64_t denominator, int32_t *error)
            {
              if ( denominator == 0 ) {
                if ( error ) *error = 1;
                return 0;
              }
              return numerator / denominator;
            }

          C
        end
        if @uses_unsigned_modulo
          text << <<~C
            /* Likewise the remainder: with no sign to disagree about, Ruby's
               floored `%` and C's are the same operation. */
            static inline uint64_t
            carray_jit_unsigned_modulo (uint64_t numerator, uint64_t denominator, int32_t *error)
            {
              if ( denominator == 0 ) {
                if ( error ) *error = 1;
                return 0;
              }
              return numerator % denominator;
            }

          C
        end
        if @uses_integer_power
          text << <<~C
            /* Exponentiation by squaring, so that an integer power is the
               exact integer Ruby would give rather than pow's double.  The
               exponent is known non-negative: a negative one gives a Rational
               in Ruby, and is refused. */
            static inline int64_t
            carray_jit_integer_power (int64_t base, int64_t exponent)
            {
              int64_t result = 1;
              while ( exponent > 0 ) {
                if ( exponent & 1 ) result *= base;
                base *= base;
                exponent >>= 1;
              }
              return result;
            }

          C
        end
        COMPLEX_HELPERS.each do |name, definition|
          [false, true].each do |narrow|
            next unless @complex_helpers.include?([name, narrow])
            text << (narrow ? self.class.narrowed_complex_helper(definition)
                            : definition) << "\n"
          end
        end
        if @uses_real_arg
          text << <<~C
            /* The argument of a real number, which Ruby reads off the sign
               bit rather than from a comparison: `-0.0.arg` is pi, where
               `-0.0 < 0` is false.  A NaN is its own argument. */
            static inline double
            carray_jit_real_arg (double x)
            {
              if ( isnan(x) ) return x;
              return signbit(x) ? M_PI : 0.0;
            }

          C
        end
        if @uses_clamp
          text << <<~C
            /* A window that falls off the array reads the nearest cell it
               has: `border: :clamp`.  Written as two comparisons rather
               than min/max of a difference, because the extent is what
               decides and it is right there. */
            static inline int64_t
            carray_jit_clamp (int64_t position, int64_t extent)
            {
              if ( position < 0 ) return 0;
              if ( position >= extent ) return extent - 1;
              return position;
            }

          C
        end
        if @uses_wrap
          text << <<~C
            /* A window that falls off the array comes back on the other
               side: `border: :wrap`.  C's `%` truncates toward zero, so a
               negative position needs the extent added back -- the same
               correction the flooring helpers make, for the same reason. */
            static inline int64_t
            carray_jit_wrap (int64_t position, int64_t extent)
            {
              int64_t folded = position % extent;
              return folded < 0 ? folded + extent : folded;
            }

          C
        end
        if @uses_index_check
          text << <<~C
            /* A subscript the kernel computes is checked as it is reached --
               the one thing about a kernel that cannot be settled before it
               runs.  Out of range it reports through *error, which the Ruby
               side turns into the IndexError CArray would have raised, and
               reads cell 0 so that nothing is read outside the array in the
               meantime. */
            static inline int64_t
            carray_jit_index (int64_t position, int64_t extent, int32_t *error)
            {
              if ( position < 0 || position >= extent ) {
                if ( error ) *error = 2;
                return 0;
              }
              return position;
            }

          C
        end
        if @uses_floor_modulo
          text << <<~C
            /* Ruby's `%` floors with its division: the remainder carries the
               sign of the divisor, where C's `%` and fmod carry the sign of
               the dividend.  So add the divisor back when the remainder is
               non-zero and disagrees with it in sign -- and, for floats,
               give a zero remainder the divisor's sign, so the rule holds
               without exception.  This mirrors CArray's own `:mod` kernel in
               `ext/mkkernel.rb`. */
            static inline int64_t
            carray_jit_floor_modulo (int64_t numerator, int64_t denominator, int32_t *error)
            {
              if ( denominator == 0 ) {
                if ( error ) *error = 1;
                return 0;
              }
              int64_t remainder = numerator % denominator;
              if ( remainder != 0 && ((remainder < 0) != (denominator < 0)) ) {
                remainder += denominator;
              }
              return remainder;
            }

            static inline double
            carray_jit_floor_modulo_real (double numerator, double denominator)
            {
              double remainder = fmod(numerator, denominator);
              if ( remainder != 0 ) {
                if ( (remainder < 0) != (denominator < 0) ) remainder += denominator;
              }
              else {
                remainder = copysign(0.0, denominator);
              }
              return remainder;
            }

          C
        end
        if @uses_floor_divide
          text << <<~C
            /* Ruby and CArray floor integer division and give the remainder the
               sign of the divisor; C truncates toward zero.  Correct the C
               quotient by one when the division is inexact and the operands
               disagree in sign.  Division by zero cannot raise from here, so it
               is reported through *error and checked on the Ruby side. */
            static inline int64_t
            carray_jit_floor_divide (int64_t numerator, int64_t denominator, int32_t *error)
            {
              if ( denominator == 0 ) {
                /* error is null when the cell being written is masked: the
                   value there is out of contract, so a zero that only ever
                   feeds a masked cell is not a division by zero the caller
                   asked about. */
                if ( error ) *error = 1;
                return 0;
              }
              int64_t quotient = numerator / denominator;
              if ( numerator % denominator != 0 && ((numerator < 0) != (denominator < 0)) ) {
                quotient -= 1;
              }
              return quotient;
            }

          C
        end
        text << pasted_definitions
      end

      # The bodies of the functions written with `jit_function`, put in this
      # translation unit as statics and called by name.  An address the
      # compiler cannot see through is a call it cannot inline, and the loop
      # around it is one it will not vectorise -- so a function the block
      # named is compiled into the kernel as if the expression had been
      # written out where it is called.
      #
      # `static` because the symbol belongs to this kernel: the same body may
      # already stand in its own object, and in another kernel beside this
      # one.  The name carries the digest of the body, so two of them are the
      # same function, and one is pasted once however many names the block
      # reached it by.
      # Every function whose definition ends up in this file: the ones the
      # block named, and the ones those call.  Helpers and raise messages
      # are asked of all of them, since a body pasted three deep reports
      # through the same slot and wants the same preamble.
      def pasted_closure
        found = {}
        walk = lambda do |function|
          next if found[function.name]
          found[function.name] = function
          (function.dependencies || []).each { |called| walk.call(called) }
        end
        @pasted_functions.each_value { |function| walk.call(function) }
        found.values
      end

      # A pasted body may itself call a function compiled here, which it
      # reaches by symbol -- so that one is pasted too, and ahead of it, or
      # the call would be to a name this file has not defined yet.  The same
      # `seen` covers both: one definition per symbol however many ways it
      # was reached.
      def pasted_definitions
        seen = {}
        text = +""
        @pasted_functions.each_value do |function|
          text << paste_definition(function, seen)
        end
        text
      end

      def paste_definition (function, seen)
        return "" if seen[function.name]
        seen[function.name] = true
        text = +""
        (function.dependencies || []).each do |called|
          text << paste_definition(called, seen)
        end
        text << "/* #{function} */\n" \
                "static #{function.definition}\n"
      end

      # One compiled object holds both loops and picks between them once,
      # outside the loop.  The contiguous form indexes a typed pointer along
      # the innermost axis, which the compiler can vectorise; the strided form
      # cannot be, and is what lets a view run without being copied first.
      def dispatcher
        tests = @arrays.map { |array|
          "strides[#{@stride_offsets.fetch(array) + array_rank(array) - 1}] == " \
          "(int64_t) sizeof(#{storage_c_type(array)})"
        }
        # A kernel reaching no array cell has nothing to be contiguous about
        # -- it can only be one whose work is a call, the arrays it touches
        # arriving whole as addresses.  There is one loop then, and asking
        # which to take would be an `if` with nothing in it.
        if tests.empty?
          return <<~C
            void
            #{FUNCTION_NAME} #{SIGNATURE}
            {
              carray_jit_contiguous(#{ARGUMENTS});
            }
          C
        end
        <<~C
          void
          #{FUNCTION_NAME} #{SIGNATURE}
          {
            if ( #{tests.join("\n         && ")} ) {
              carray_jit_contiguous(#{ARGUMENTS});
            } else {
              carray_jit_strided(#{ARGUMENTS});
            }
          }
        C
      end

      def build_body (contiguous)
        @contiguous = contiguous
        @declared_locals = {}
        @temporary_count = 0
        @carried_masks = []
        # Whether this body has a way to report -- asked of the statements
        # themselves rather than of what rides in beside them.  A windowed
        # kernel carries every extent of its arrays so the border rule has
        # them, which says nothing about whether a cell can fail.
        @body_reports = false
        statements = @analyzer.body.statements.map { |statement|
          emit_statement(statement, "  " + "  " * @rank)
        }.join
        "{\n" + declarations + loop_open + statements + loop_close + "}\n"
      end

      def array_rank (array)
        @array_ranks.fetch(array, @rank)
      end

      def array_rank_of (analyzer, array)
        analyzer.array_ranks.fetch(array, analyzer.rank)
      end

      def declarations
        lines = []
        @arrays.each_with_index do |array, index|
          base = @stride_offsets.fetch(array)
          lines << "  char *const #{pointer_name(array)} = pointers[#{index}];\n"
          array_rank(array).times do |axis|
            lines << "  const int64_t #{stride_name(array, axis)} = " \
                     "strides[#{base + axis}];\n"
          end
          next unless @masked
          given = "mask_pointers[#{index}]"
          if @analyzer.written_arrays.include?(array)
            # An array the kernel writes always has a mask by the time it gets
            # here: the caller creates one when any operand carries one.
            lines << "  uint8_t *const #{mask_pointer_name(array)} = " \
                     "(uint8_t *) #{given};\n"
            array_rank(array).times do |axis|
              lines << "  const int64_t #{mask_stride_name(array, axis)} = " \
                       "mask_strides[#{base + axis}];\n"
            end
          else
            lines << "  const uint8_t *const #{mask_pointer_name(array)} = " \
                     "#{given} ? (const uint8_t *) #{given} : &carray_jit_present;\n"
            array_rank(array).times do |axis|
              lines << "  const int64_t #{mask_stride_name(array, axis)} = " \
                       "#{given} ? mask_strides[#{base + axis}] : 0;\n"
            end
          end
        end
        @reals.each_with_index do |name, index|
          lines << "  const double #{c_name(name)} = reals[#{index}];\n"
        end
        @complexes.each_with_index do |name, index|
          slot = @reals.size + 2 * index
          lines << "  const double _Complex #{c_name(name)} = " \
                   "CMPLX(reals[#{slot}], reals[#{slot + 1}]);\n"
        end
        @integers.each_with_index do |name, index|
          lines << "  const int64_t #{c_name(name)} = integers[#{index}];\n"
        end
        @extent_slots.each_with_index do |(array, axis), slot|
          lines << "  const int64_t #{extent_name(array, axis)} = " \
                   "integers[#{@integers.size + slot}];\n"
        end
        @address_functions.each_key.with_index do |name, index|
          lines << "  const #{c_function_type_name(name)} #{c_name(name)} = " \
                   "(#{c_function_type_name(name)}) functions[#{index}];\n"
        end
        @address_arrays.each_with_index do |array, index|
          # Typed by the array rather than by the parameter it will be passed
          # to: the caller has already checked that the two agree, and the
          # array is the one that owns the memory.
          lines << "  #{storage_c_type(array)} *const #{c_name(array)} = " \
                   "(#{storage_c_type(array)} *) data[#{index}];\n"
        end
        lines.empty? ? "" : lines.join + "\n"
      end

      # Which way each axis runs is derived, not chosen: reading a cell the
      # kernel will later write means that cell has to be reached in one
      # particular order, and any other order would read what was never
      # written.
      # Each axis carries a start, a limit and a step.  The step is a compiled
      # constant when it is one, because `i++` is what lets the loop vectorise
      # and that is the case nearly every kernel is in.
      def loop_open
        @rank.times.map { |axis|
          indent = "  " + "  " * axis
          index = @analyzer.index_names[axis]
          # A kernel that can fail at a cell -- a computed index off the
          # end, a division with no divisor, a `raise` -- stops there, as the
          # Ruby loop it stands for does.  So each loop leaves as soon as one
          # has: the flag is already in cache, and a kernel whose body has no
          # way to report does not pay for the test at all.
          guard = @body_reports ? "#{indent}  if ( *error ) break;\n" : ""
          start = "bounds[#{3 * axis}]"
          limit = "bounds[#{3 * axis + 1}]"
          step = @steps[axis]
          if step && step.negative?
            advance = step == -1 ? "#{index}--" : "#{index} += bounds[#{3 * axis + 2}]"
            "#{indent}for (int64_t #{index} = #{start}; #{index} > #{limit}; " \
            "#{advance}) {\n#{guard}"
          else
            advance = step == 1 ? "#{index}++" : "#{index} += bounds[#{3 * axis + 2}]"
            "#{indent}for (int64_t #{index} = #{start}; #{index} < #{limit}; " \
            "#{advance}) {\n#{guard}"
          end
        }.join
      end

      def loop_close
        @rank.downto(1).map { |depth| "  " + "  " * (depth - 1) + "}\n" }.join
      end

      def emit_statement (statement, indent)
        case statement
        when Assignment    then emit_assignment(statement, indent)
        when ElementWrite  then guarded(statement, indent) { |inner|
                                  emit_element_write(statement, inner) }
        when MaskWrite     then guarded(statement, indent) { |inner|
                                  emit_mask_only_write(statement, inner) }
        when PointerWrite  then
          "#{indent}#{statement.name}[#{emit(statement.index, :int64)}] = " \
          "#{emit(statement.expression, statement.type)};\n"
        when InnerLoop     then emit_inner_loop(statement, indent)
        when While         then emit_while(statement, indent)
        when Branch        then emit_branch(statement, indent)
        when CallStatement then emit_call_statement(statement, indent)
        when Print         then emit_print(statement, indent)
        when Raise         then emit_raise(statement, indent)
        when LoopSkip      then "#{indent}continue;\n"
        when LoopStop      then "#{indent}break;\n"
        else
          raise Error, "code generation reached #{statement.class}"
        end
      end

      # 1 and 2 are the divisor that was not there and the subscript that ran
      # off its array.  A `raise` in the block takes a code from here up.
      RAISE_CODE_FLOOR = 3

      # The code is taken from the message rather than counted off as messages
      # are met.  Counting would number the same block differently depending
      # on what else had been compiled, and a kernel is cached on disk under
      # the C it generated: a number that means one string today and another
      # tomorrow would raise the wrong message, quietly, out of a cache hit.
      # From the message, one string is one code in every process.
      def raise_code (message)
        span = 2**31 - RAISE_CODE_FLOOR
        RAISE_CODE_FLOOR +
          Digest::SHA256.hexdigest(message)[0, 16].to_i(16) % span
      end

      # The cell reports and the loop stops; the Ruby side raises when it has
      # control back.  Stopping is what `raise` means -- the cells after this
      # one are not computed, and neither is the rest of this one.
      #
      # Nothing is reported from a cell that is missing.  `raise "x" if a < 0`
      # under a mask was decided by bytes that mean nothing -- the rule an
      # `if` in a masked kernel already keeps for what it writes -- so the
      # masks carried in gate the report, and a null error slot gates it
      # again where the raise stands inside a masked write.
      #
      # The first report wins.  A sweep hands the kernel one chunk at a time,
      # so a later chunk still runs after a cell has raised in this one.
      def emit_raise (node, indent)
        code = raise_code(node.message)
        register_raise(code, node.message)
        slot = error_argument
        tests = []
        unless @carried_masks.empty?
          mask = combine_masks(@carried_masks)
          tests << "!#{mask}" unless mask == "0"
        end
        # A body standing on its own reports into the flag beside it, which is
        # there to be reported into: there is nothing to ask about, and asking
        # would read as though there were.
        if @in_function && !@error_parameter
          tests << "!#{ERROR_FLAG}"
          report = "#{ERROR_FLAG} = #{code};"
        else
          tests << "#{slot} && !*#{slot}"
          report = "*#{slot} = #{code};"
        end
        # A function returns whatever it returns, whatever happened -- the
        # arrangement its C caller is left with, and the one the division
        # helper already keeps by returning zero from a divide it refused.
        # The value is not the answer; the flag says so.
        leaving = @in_function && !@returns_nothing ? "return 0;" : "return;"
        "#{indent}if ( #{tests.join(' && ')} ) {\n" \
        "#{indent}  #{report}\n" \
        "#{indent}  #{leaving}\n" \
        "#{indent}}\n"
      end

      # One message per code.  Two that collided would be one string raised
      # where the other was written, so it is worth the check even though the
      # code is 64 bits of digest folded down and this cannot really happen.
      def register_raise (code, message)
        held = @raise_messages[code]
        if held && held != message
          raise Error, "two raise messages share a code: " \
                       "#{held.inspect} and #{message.inspect}"
        end
        @raise_messages[code] = message
      end

      # A conversion as Ruby writes it: flags, width, precision, and the
      # letter that says what is being printed.
      CONVERSION = /%([-+ 0#]*)(\d*)((?:\.\d+)?)([a-zA-Z%])/

      INTEGER_CONVERSIONS = %w[d i u x X o].freeze
      REAL_CONVERSIONS    = %w[e E f F g G a A].freeze

      # The format is rewritten rather than passed through, because the same
      # directive does not mean the same thing in both languages: Ruby's `%d`
      # takes any Integer, and C's takes an `int`, which is not what a cell
      # holds.  What each argument is, is known here, so the directive is
      # settled here too.
      # A call whose value is dropped.  The cast says the dropping was meant,
      # which is what a reader of the generated C would want to know and what
      # a compiler warning would otherwise ask about.
      #
      # Under a mask the call does not happen at all.  Every other statement
      # can run on bytes that mean nothing and mark what it wrote; a call
      # cannot be taken back, so this follows `raise` rather than the
      # arithmetic: a cell whose arguments are missing is a cell the function
      # is not told about.
      def emit_call_statement (statement, indent)
        text = emit_raw(statement.call).first
        return "#{indent}(void) #{text};\n" unless @masked
        mask = combine_masks(@carried_masks + [emit_mask(statement.call)])
        return "#{indent}(void) #{text};\n" if mask == "0"
        "#{indent}if ( ! #{mask} ) {\n" \
        "#{indent}  (void) #{text};\n" \
        "#{indent}}\n"
      end

      def emit_print (print, indent)
        arguments = print.arguments.dup
        text = +""
        rest = print.template
        until rest.empty?
          match = CONVERSION.match(rest)
          unless match
            text << c_string(rest)
            break
          end
          text << c_string(match.pre_match)
          rest = match.post_match
          if match[4] == "%"
            text << "%%"
            next
          end
          argument = arguments.shift
          unless argument
            raise Unsupported.new(
              "printf's format asks for more values than were given",
              print.location)
          end
          text << conversion_for(argument, match, print)
        end
        unless arguments.empty?
          raise Unsupported.new(
            "printf was given more values than its format asks for",
            print.location)
        end
        values = print.arguments.flat_map { |argument| printed_values(argument) }
        # Flushed at once: C's buffer is not Ruby's, so without this the
        # kernel's output arrives after everything the program printed
        # around it, which is no use for seeing where you are.
        "#{indent}printf(\"#{text}\"#{values.map { |v| ", #{v}" }.join});\n" \
        "#{indent}fflush(stdout);\n"
      end

      def conversion_for (argument, match, print)
        flags, width, precision, letter = match[1], match[2], match[3], match[4]
        case argument.type
        when :int64
          unless INTEGER_CONVERSIONS.include?(letter)
            raise Unsupported.new(
              "this value is an integer, so `%#{letter}` does not print it; " \
              "write `%d`",
              argument.location || print.location)
          end
          # `l`, because a cell holds an int64_t and C's `%d` is an int.
          "%#{flags}#{width}#{precision}l#{letter}"
        when :uint64
          unless INTEGER_CONVERSIONS.include?(letter)
            raise Unsupported.new(
              "this value is an integer, so `%#{letter}` does not print it; " \
              "write `%d`",
              argument.location || print.location)
          end
          # `%d` of a uint64_t above 2**63 would print a negative number, and
          # the value Ruby prints is the one the cell holds -- so the signed
          # conversions become their unsigned twin.  The rest (`%x`, `%o`) are
          # unsigned already.
          "%#{flags}#{width}#{precision}l#{letter == "i" ? "u" : letter.sub("d", "u")}"
        when :double
          unless REAL_CONVERSIONS.include?(letter)
            raise Unsupported.new(
              "this value is a real, so `%#{letter}` does not print it; " \
              "write `%g`",
              argument.location || print.location)
          end
          "%#{flags}#{width}#{precision}#{letter}"
        when :complex
          # C has no directive for a complex, so it is printed as the two
          # numbers it is, with the sign of the imaginary part always shown.
          unless REAL_CONVERSIONS.include?(letter)
            raise Unsupported.new(
              "this value is complex, so `%#{letter}` does not print it; " \
              "write `%g`",
              argument.location || print.location)
          end
          "%#{flags}#{width}#{precision}#{letter}" \
          "%+#{width}#{precision}#{letter}i"
        when :boolean
          "%#{flags}#{width}#{precision}d"
        else
          raise Unsupported.new("printf cannot print this value",
                                argument.location || print.location)
        end
      end

      def printed_values (argument)
        case argument.type
        when :complex
          ["creal(#{emit(argument, :complex)})", "cimag(#{emit(argument, :complex)})"]
        when :boolean
          ["(int) (#{emit(argument, :boolean)})"]
        else
          [emit(argument, argument.type)]
        end
      end

      # The literal parts of the format, spelled the way C spells a string.
      def c_string (text)
        text.gsub(/[\\"\n\t\r\e\0]/,
                  "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n",
                  "\t" => "\\t", "\r" => "\\r", "\e" => "\\033",
                  "\0" => "\\0")
      end

      # Reading outside an array can be made harmless -- read cell zero and
      # report -- but writing outside it cannot: the report would arrive after
      # the damage.  So a scatter works its positions out first, and writes
      # only if every one of them is inside.
      def guarded (write, indent)
        positions = scattered_positions(write)
        return yield(indent) if positions.empty?

        lines = "#{indent}{\n"
        positions.each do |temporary, node, array, axis|
          lines << "#{indent}  const int64_t #{temporary} = #{emit(node, :int64)};\n"
          @position_temporaries[node] = temporary
        end
        test = positions.map { |temporary, _, array, axis|
          "#{temporary} >= 0 && #{temporary} < #{extent_name(array, axis)}"
        }.join(" && ")
        lines << "#{indent}  if ( #{test} ) {\n"
        lines << yield("#{indent}    ")
        lines << "#{indent}  } else {\n"
        lines << "#{indent}    if ( #{error_argument} ) *#{error_argument} = 2;\n"
        lines << "#{indent}  }\n"
        lines << "#{indent}}\n"
        positions.each { |_, node, _, _| @position_temporaries.delete(node) }
        lines
      end

      def scattered_positions (write)
        subscripts = write_subscripts(write)
        subscripts.each_with_index.filter_map { |(index, offset), axis|
          next unless index.nil? && offset.is_a?(Node) &&
                      !Analyzer.fixed_subscript?(offset)
          [next_temporary("position"), offset, write.array, axis]
        }
      end

      # `out[i] = UNDEF` marks the cell missing.  The bytes underneath are out
      # of contract, so there is nothing to store into them.
      def emit_mask_only_write (write, indent)
        "#{indent}#{cell_reference(write.array, write_subscripts(write), :mask)} = 1;\n"
      end

      # The loop a reduction runs in, inside one cell of the outer loops.
      def inner_loop_guard (indent)
        @body_reports ? "#{indent}  if ( *error ) break;\n" : ""
      end

      # The same shape the bounded loop gets, minus the counter -- including
      # the guard, so a `raise` inside a `while` stops it at the pass that
      # raised rather than running the condition once more.
      def emit_while (loop_node, indent)
        # A loop entered on a value read from a missing cell is in the same
        # position a branch taken on one is: it was decided by bytes that mean
        # nothing, so what it writes inherits that.  The carrying is the
        # branch's, spelled the same way, because it is the same rule.
        #
        # What is not the same is what running on those bytes can cost.  A
        # branch on garbage takes the wrong arm and finishes; a `while` on
        # garbage can fail to finish at all, since the garbage is what decides
        # how many passes there are.  Skipping the loop instead was the other
        # candidate and is worse: the locals would keep their pre-loop values
        # and a write after the loop carries no mask, so a missing cell would
        # buy a wrong answer quietly rather than a slow one loudly.  A kernel
        # over masked data whose loop bound comes from a cell should say so --
        # `if a[i] == UNDEF` -- which is the same advice masked arithmetic
        # already gets.
        outer = @carried_masks
        @carried_masks =
          @masked ? (outer + [emit_mask(loop_node.condition)]).uniq : outer

        text = "#{indent}while (#{emit(loop_node.condition, :boolean)}) {\n" +
               inner_loop_guard(indent)
        text += loop_node.statements.map { |statement|
          emit_statement(statement, indent + "  ")
        }.join
        @carried_masks = outer
        text + "#{indent}}\n"
      end

      def emit_inner_loop (loop_node, indent)
        accumulation = reduction_accumulation(loop_node)
        return emit_split_reduction(loop_node, accumulation, indent) if accumulation

        index = loop_node.index
        step = loop_node.step
        text = "#{indent}for (int64_t #{index} = #{emit(loop_node.from, :int64)}; " \
               "#{index} #{step.positive? ? '<' : '>'} " \
               "#{emit(loop_node.to, :int64)}; #{stride_step(index, step)}) {\n" +
               inner_loop_guard(indent)
        text += loop_node.statements.map { |statement|
          emit_statement(statement, indent + "  ")
        }.join
        text + "#{indent}}\n"
      end

      # The loop is a reduction when its whole body is one local folding a
      # term into itself with an associative operator, and that local was
      # already live when the loop began.  Anything else -- a second
      # statement, a branch, a term that reads the accumulator twice -- is not
      # a fold and keeps the serial loop.
      #
      # Returns [accumulator, operator, term], or nil.
      def reduction_accumulation (loop_node)
        return nil unless @reassociate
        # A masked accumulator carries a mask beside its value, and a partial
        # sum would need one each.  Left out rather than half-done.
        return nil if @masked
        # The split walks the index a round at a time from one end, so it is
        # written for a loop that counts by one.  A stride or a downward
        # sweep keeps the serial loop -- which costs nothing that was there
        # before, those loops having been unwritable until now.
        return nil unless loop_node.step == 1
        return nil unless loop_node.statements.size == 1

        assignment = loop_node.statements.first
        return nil unless assignment.is_a?(Assignment)
        name = assignment.binding_name
        # Declared before this loop, at this type, so the fold continues a
        # value rather than starting one.
        return nil unless @declared_locals[name] == assignment.type

        expression = assignment.expression
        return nil unless expression.is_a?(BinaryOperation)
        operator = expression.operator
        return nil unless licensed_fold?(operator, assignment.type)

        # Short of one full round the chains never run, and their setup is
        # all the loop would pay for them.  Where the extent is written out,
        # that is known here and costs nothing to act on; where it is a value
        # the kernel is handed, it is not, and a runtime test for it was
        # measured and bought less than it cost.
        return nil if literal_extent(loop_node)&.<(PARTIAL_ACCUMULATORS)

        left, right = expression.left, expression.right
        if accumulator?(left, name) && !mentions_local?(right, name)
          [assignment, operator]
        elsif accumulator?(right, name) && !mentions_local?(left, name)
          [assignment, operator]
        end
      end

      def literal_extent (loop_node)
        from, to = loop_node.from, loop_node.to
        return nil unless from.is_a?(IntegerLiteral) && to.is_a?(IntegerLiteral)
        to.value - from.value
      end

      # Addition is taken in double and in complex; a complex sum is
      # componentwise in both Ruby and C, so partial sums add the same way.
      # Multiplication is taken in double only -- Ruby multiplies two
      # Complexes its own way, and combining partial products would have to
      # go through that rather than through C's operator.
      def licensed_fold? (operator, type)
        case operator
        when :+ then type == :double || type == :complex
        when :* then type == :double
        end
      end

      def accumulator? (node, name)
        node.is_a?(LocalRead) && node.binding_name == name
      end

      def mentions_local? (node, name)
        return true if accumulator?(node, name)
        node.children.any? { |child| mentions_local?(child, name) }
      end

      # The fold, run as PARTIAL_ACCUMULATORS chains instead of one, with the
      # cells that do not fill a round left to a serial tail.
      #
      # The incoming value rides in the first chain and the rest start from
      # the operator's identity, so it is folded in exactly once.  Each chain
      # keeps the term's own operand order -- what is licensed here is the
      # order the *iterations* are grouped in, not the order within one.
      # `k++`, `k--`, or the stride written out.
      def stride_step (index, step)
        case step
        when 1  then "#{index}++"
        when -1 then "#{index}--"
        else step.positive? ? "#{index} += #{step}" : "#{index} -= #{-step}"
        end
      end

      def emit_split_reduction (loop_node, accumulation, indent)
        assignment, operator = accumulation
        name  = assignment.binding_name
        type  = assignment.type
        index = loop_node.index
        base  = "#{index}__base"
        limit = "#{index}__end"
        lanes = (0...PARTIAL_ACCUMULATORS).map { |lane| "#{name}__p#{lane}" }
        identity = (operator == :* ? ONES : ZEROES).fetch(type)

        inner = indent + "  "
        text  = "#{indent}{\n"
        text += "#{inner}int64_t #{base} = #{emit(loop_node.from, :int64)};\n"
        text += "#{inner}const int64_t #{limit} = #{emit(loop_node.to, :int64)};\n"
        text += "#{inner}#{COMPUTATION_C_TYPES.fetch(type)} #{lanes.first} = #{name}" +
                lanes.drop(1).map { |lane| ", #{lane} = #{identity}" }.join + ";\n"
        text += "#{inner}for (; #{base} + #{PARTIAL_ACCUMULATORS} <= #{limit}; " \
                "#{base} += #{PARTIAL_ACCUMULATORS}) {\n"
        text += inner_loop_guard(inner)
        lanes.each_with_index do |lane, offset|
          term = lane_expression(assignment.expression, name, lane)
          text += "#{inner}  {\n"
          text += "#{inner}    const int64_t #{index} = #{base} + #{offset};\n"
          text += "#{inner}    #{lane} = #{emit(term, type)};\n"
          text += "#{inner}  }\n"
        end
        text += "#{inner}}\n"
        text += "#{inner}#{name} = #{combine_partials(lanes, operator)};\n"
        text += "#{inner}for (int64_t #{index} = #{base}; #{index} < #{limit}; " \
                "#{index}++) {\n"
        text += inner_loop_guard(inner)
        text += emit_statement(assignment, inner + "  ")
        text += "#{inner}}\n"
        text + "#{indent}}\n"
      end

      # The same term, folding into one chain instead of into the
      # accumulator.  The accumulator appears once and at the top, which is
      # what reduction_accumulation checked, so only that operand moves.
      def lane_expression (expression, name, lane)
        operands = [expression.left, expression.right].map { |operand|
          next operand unless accumulator?(operand, name)
          read = LocalRead.new(operand.name, operand.location)
          read.binding_name = lane
          read.type = operand.type
          read
        }
        term = BinaryOperation.new(expression.operator, *operands,
                                   expression.location)
        term.type = expression.type
        term
      end

      # Pairwise, so that the chains meet in a tree rather than in a line.
      def combine_partials (lanes, operator)
        terms = lanes
        while terms.size > 1
          terms = terms.each_slice(2).map { |left, right|
            right ? "(#{left} #{operator} #{right})" : left
          }
        end
        terms.first
      end

      # `if` in statement position.  A branch not taken writes nothing, so the
      # cell keeps both its value and its mask -- which is what the same `if`
      # would do in Ruby.
      def emit_branch (branch, indent)
        # A branch taken on a value read from a missing cell was decided by
        # bytes that mean nothing, so what it writes inherits that.  A branch
        # taken on `a[i] == UNDEF` was not.
        outer = @carried_masks
        @carried_masks = @masked ? (outer + [emit_mask(branch.condition)]).uniq : outer

        text = "#{indent}if ( #{emit(branch.condition, :boolean)} ) {\n"
        text += branch.consequent.map { |statement|
          emit_statement(statement, indent + "  ")
        }.join
        unless branch.alternative.empty?
          text += "#{indent}} else {\n"
          text += branch.alternative.map { |statement|
            emit_statement(statement, indent + "  ")
          }.join
        end
        @carried_masks = outer
        text + "#{indent}}\n"
      end

      def emit_assignment (assignment, indent)
        name = assignment.binding_name
        type = assignment.type
        declared = @declared_locals.key?(name)
        @declared_locals[name] = type

        # A local carries a mask alongside its value, so that reading it later
        # is the same as reading what it was computed from.
        mask = if @masked
                 "#{indent}#{declared ? '' : 'uint8_t '}" \
                 "#{local_mask_name(name)} = #{emit_mask(assignment.expression)};\n"
               else
                 ""
               end

        if assignment.expression.is_a?(Conditional)
          lines = declared ? "" : "#{indent}#{COMPUTATION_C_TYPES.fetch(type)} #{name};\n"
          lines + emit_conditional_statement(assignment.expression, name, type, indent) + mask
        else
          prefix = declared ? "" : "#{COMPUTATION_C_TYPES.fetch(type)} "
          "#{indent}#{prefix}#{name} = #{emit(assignment.expression, type)};\n" + mask
        end
      end

      # Masked data is out of contract -- a kernel may compute anything into a
      # masked cell -- so the value is computed for every cell and only the
      # mask is reconciled.  That is what lets the loop stay branchless.
      #
      # The one thing that cannot simply be computed and discarded is an
      # integer division by zero, which would be reported even though the
      # cell it feeds is masked.  So the mask is settled first and gates the
      # report.
      # Where a write lands.  Normally the cell the outer indices are on; a
      # contraction into a fixed cell says so with a constant subscript.
      def write_subscripts (write)
        subscripts = write.subscripts if write.respond_to?(:subscripts)
        subscripts || @analyzer.index_names.map { |name| [name, 0] }
      end

      def emit_element_write (write, indent)
        unless @masked
          @masked_flag = nil
          return emit_value_write(write, indent)
        end

        flag = next_temporary("masked")
        lines = "#{indent}const uint8_t #{flag} = " \
                "#{combine_masks(@carried_masks + [emit_mask(write.expression)])};\n"
        lines += "#{indent}#{cell_reference(write.array, write_subscripts(write), :mask)} = " \
                 "#{flag};\n"
        @masked_flag = flag
        lines += emit_value_write(write, indent)
        @masked_flag = nil
        lines
      end

      # The mask of an expression, built the same shape as the expression.
      #
      # A flat union of everything the expression touches would be wrong for a
      # conditional: `cond ? 0.0 : a[i]` does not read `a[i]` when the
      # condition holds, and Ruby's answer there is not missing.  So the
      # conditional's mask is conditional too.
      def emit_mask (node)
        case node
        when ElementRead
          cell_reference(node.array, node.subscripts, :mask)
        when LocalRead
          local_mask_name(node.binding_name)
        when Conditional
          branches = "#{emit(node.condition, :boolean)} ? " \
                     "#{emit_mask(node.consequent)} : #{emit_mask(node.alternative)}"
          combine_masks([emit_mask(node.condition), "(#{branches})"])
        when IntegerLiteral, FloatLiteral, IndexVariable, CaptureRead, MaskTest,
             BoundsValue, ZeroLike
          "0"
        else
          combine_masks(node.children.map { |child| emit_mask(child) })
        end
      end

      def combine_masks (parts)
        present = parts.reject { |part| part == "0" }.uniq
        return "0" if present.empty?
        present.size == 1 ? present.first : "(#{present.join(' | ')})"
      end

      def local_mask_name (name)
        "#{name}__mask"
      end

      def emit_value_write (write, indent)
        target = cell_reference(write.array, write_subscripts(write))
        expression = write.expression
        if expression.is_a?(Conditional)
          temporary = next_temporary
          type = expression.type
          "#{indent}#{COMPUTATION_C_TYPES.fetch(type)} #{temporary};\n" +
            emit_conditional_statement(expression, temporary, type, indent) +
            "#{indent}#{target} = #{cast_to_storage(temporary, type, write.array)};\n"
        else
          value = cast_to_storage(emit(expression, expression.type),
                                  expression.type, write.array)
          "#{indent}#{target} = #{value};\n"
        end
      end

      # A conditional in statement position becomes if/else rather than a
      # ternary; it reads far better when the branches are long.
      def emit_conditional_statement (node, target, type, indent)
        "#{indent}if ( #{emit(node.condition, :boolean)} ) {\n" \
        "#{indent}  #{target} = #{emit(node.consequent, type)};\n" \
        "#{indent}} else {\n" \
        "#{indent}  #{target} = #{emit(node.alternative, type)};\n" \
        "#{indent}}\n"
      end

      def storage_c_type (array)
        STORAGE_C_TYPES.fetch(@storage_types.fetch(array))
      end

      def cast_to_storage (text, type, array)
        # Storing into a boolean array normalises: CArray's boolean is a byte
        # holding 0 or 1, and a kernel is not the place that invariant stops
        # being true.
        return "(uint8_t)((#{text}) ? 1 : 0)" if boolean_storage?(array)
        target = storage_c_type(array)
        return text if COMPUTATION_C_TYPES.fetch(type) == target
        "(#{target})(#{text})"
      end

      # The cast that takes a stored cell to the type the kernel computes in,
      # or nil where the two already agree.
      def widening_cast (array, type)
        return nil if type == :boolean
        wanted = COMPUTATION_C_TYPES.fetch(type)
        return nil if storage_c_type(array) == wanted
        "(#{wanted})"
      end

      def boolean_storage? (array)
        @storage_types.fetch(array, nil) == "boolean"
      end

      # A Ruby name is not always a C one: `Foo::TABLE` names one thing in
      # Ruby and nothing at all in C, so the qualified part is spelled with
      # underscores.  Every name that reaches the source goes through here.
      def c_name (name)
        name.to_s.gsub("::", "__")
      end

      def pointer_name (array)
        "p_#{c_name(array)}"
      end

      # The block's own name for the function, with the typedef beside it.
      def c_function_type_name (name)
        "#{c_name(name)}_fn_t"
      end

      def extent_name (array, axis)
        "#{c_name(array)}_n#{axis}"
      end

      # An error reported from a cell whose mask is already set is not one the
      # caller asked about: the value there is out of contract.
      # A kernel is handed a place to report through; a compiled function is
      # not, having only the signature its declaration gave it.  So the
      # object carries one of its own -- a single exported int the helpers
      # write the same code into -- and `CFunction#call` reads it and raises
      # what the kernel raises.  Nothing in the C reaches Ruby to do it: the
      # function still returns a number and touches no Ruby value, which is
      # what lets its address be handed to a library, or called off the GVL.
      ERROR_FLAG = "carray_jit_error"

      # A computation type this generator has no C for.  Nothing reaches here
      # today -- every type TypeAssignment can assign is named at each of the
      # sites that calls this -- and that is the point: a type added later
      # stops here rather than falling into whichever branch happened to be
      # last, which for `abs`, `%` and `**` alike was the one for doubles.
      def unhandled_type (node, what)
        raise Error, "`#{what}` has no C for a #{node.type} -- this compiler " \
                     "gained a computation type without gaining the code that " \
                     "emits it"
      end

      def error_argument
        if @in_function
          @uses_error_flag = true
          # A pasted body reports into the kernel's slot, which reaches it as
          # a parameter; a standalone one into the flag in its own object.
          return @error_parameter ? ERROR_FLAG : "&#{ERROR_FLAG}"
        end
        # Asking for the slot is what says this body can report, and every
        # place that can -- a checked subscript, the division helpers, a
        # `raise`, a pasted function that takes the flag -- asks here.  So the
        # loops above learn it from the statements they will hold, which are
        # emitted before the loop is opened.
        @body_reports = true
        @masked_flag ? "(#{@masked_flag} ? (int32_t *) 0 : error)" : "error"
      end


      def stride_name (array, axis)
        "#{c_name(array)}_s#{axis}"
      end

      def mask_pointer_name (array)
        "m_#{c_name(array)}"
      end

      def mask_stride_name (array, axis)
        "#{c_name(array)}_ms#{axis}"
      end

      def index_expression (array, axis, index, offset, reporting: true)
        if index.nil?
          # A pinned axis carries either a plain position or the expression
          # that computes one -- and where that expression is one only the
          # running kernel can work out, the position is checked here.
          return offset.to_s unless offset.is_a?(Node)
          return emit(offset, :int64) if Analyzer.fixed_subscript?(offset)
          # A scatter has already worked this position out and checked it.
          held = @position_temporaries[offset]
          return held if held
          @uses_index_check = true
          return "carray_jit_index(#{emit(offset, :int64)}, " \
                 "#{extent_name(array, axis)}, " \
                 "#{reporting ? error_argument : '(int32_t *) 0'})"
        end
        # A walked one may carry an expression too: `a[i - window]` reads the
        # offset out of the kernel's integer arguments.
        return "#{index} + (#{emit(offset, :int64)})" if offset.is_a?(Node)
        return index.to_s if offset.zero?
        plain = offset.negative? ? "#{index} - #{-offset}" : "#{index} + #{offset}"
        return plain unless bordered_read?(array)
        case @border
        when :clamp
          @uses_clamp = true
          "carray_jit_clamp(#{plain}, #{extent_name(array, axis)})"
        when :wrap
          @uses_wrap = true
          "carray_jit_wrap(#{plain}, #{extent_name(array, axis)})"
        else
          # `:zero` leaves the position alone and answers 0 instead of
          # reading, which is the reference's business rather than the
          # index's -- see cell_reference.
          plain
        end
      end

      # True for a read this body has to answer for: a window's, while the
      # frame is being emitted.  The result array is written at the cell and
      # reaches nowhere, so it is never one of these.
      def bordered_read? (array)
        @bordering && @analyzer.windows.include?(array)
      end

      # Where the window has to be for there to be a cell to read: one test
      # per axis it reaches away from the cell on, and none for an axis it
      # sits still on.
      def inside_tests (array, subscripts)
        subscripts.each_with_index.filter_map { |(index, offset), axis|
          next if index.nil? || !offset.is_a?(Integer) || offset.zero?
          position = index_expression(array, axis, index, offset)
          "(#{position}) >= 0 && (#{position}) < #{extent_name(array, axis)}"
        }
      end

      # Emits with the border set aside, so that the reference inside a guard
      # is the plain one rather than a guard around a guard.
      def with_border (rule)
        held = @border
        @border = rule
        yield
      ensure
        @border = held
      end

      # The address of one cell.  On the contiguous path the innermost axis
      # becomes a typed index, which is the part that decides whether the
      # compiler can vectorise the loop.
      def cell_reference (array, subscripts, kind = :data)
        # `:zero` says a read outside the array gives zero rather than
        # somewhere else's cell, so the position is left alone and the read
        # is asked for only where there is one.  Outside, a value is 0 and a
        # mask byte is 0 too: the cell is not missing, it is not there.
        if @border == :zero && bordered_read?(array)
          inside = inside_tests(array, subscripts)
          unless inside.empty?
            reference = with_border(nil) { cell_reference(array, subscripts, kind) }
            return "(#{inside.join(' && ')} ? #{reference} : 0)"
          end
        end
        count = subscripts.size
        if kind == :mask
          # The mask read does not report an index of its own: it is asked
          # first, before it is known whether the cell being written is
          # masked, and reporting there would raise for a cell whose value is
          # out of contract anyway.  The read of the value asks the same
          # question a moment later, with that known.
          terms = subscripts.each_with_index.map { |(index, offset), axis|
            "(#{index_expression(array, axis, index, offset, reporting: false)}) * " \
            "#{mask_stride_name(array, axis)}"
          }
          return "#{mask_pointer_name(array)}[#{terms.join(' + ')}]"
        end

        type = storage_c_type(array)
        outer = (0...(count - 1)).map { |axis|
          index, offset = subscripts[axis]
          "(#{index_expression(array, axis, index, offset)}) * " \
          "#{stride_name(array, axis)}"
        }
        last = count - 1
        last_index, last_offset = subscripts[last]
        if @contiguous
          base = outer.empty? ? pointer_name(array)
                              : "#{pointer_name(array)} + #{outer.join(' + ')}"
          "((#{type} *)(#{base}))" \
          "[#{index_expression(array, last, last_index, last_offset)}]"
        else
          terms = outer + ["(#{index_expression(array, last, last_index, last_offset)}) * " \
                           "#{stride_name(array, last)}"]
          "*(#{type} *)(#{pointer_name(array)} + #{terms.join(' + ')})"
        end
      end

      # Emits `node` so that its value has type `target`, inserting a cast
      # only where the type actually changes.
      def emit (node, target)
        widen(*emit_raw(node), node.type, target).first
      end

      def emit_operand (node, target, parent_precedence, right_side = false)
        text, precedence = widen(*emit_raw(node), node.type, target)
        parenthesize(text, precedence, right_side ? parent_precedence + 1 : parent_precedence)
      end

      # The cast from one computation type to a wider one.  C would perform
      # most of these on its own, but writing them down is what makes the
      # dumped source say where the type changed -- and `int64_t` to
      # `double _Complex` is a conversion worth seeing.
      def widen (text, precedence, from, to)
        here, there = NUMERIC_RANK[from], NUMERIC_RANK[to]
        return [text, precedence] if here.nil? || there.nil? || there <= here
        ["(#{COMPUTATION_C_TYPES.fetch(to)})" \
         "#{parenthesize(text, precedence, LEAF_PRECEDENCE)}", UNARY_PRECEDENCE]
      end

      def parenthesize (text, precedence, needed)
        precedence < needed ? "(#{text})" : text
      end

      def emit_raw (node)
        case node
        when IntegerLiteral   then [format_integer(node.value), LEAF_PRECEDENCE]
        when FloatLiteral     then [format_float(node.value, node.type), LEAF_PRECEDENCE]
        when ImaginaryLiteral
          real = TypeAssignment::REAL_PART_TYPES.fetch(node.type)
          ["#{complex_build(node.type)}(#{format_float(0.0, real)}, " \
           "#{format_float(node.value.to_f, real)})", LEAF_PRECEDENCE]
        when BooleanLiteral   then [node.value ? "1" : "0", LEAF_PRECEDENCE]
        when BitwiseNot
          ["~#{emit_operand(node.operand, node.type, UNARY_PRECEDENCE)}",
           UNARY_PRECEDENCE]
        when IndexVariable    then [node.name.to_s, LEAF_PRECEDENCE]
        when BoundsValue      then ["bounds[#{node.slot}]", LEAF_PRECEDENCE]
        when ZeroLike
          [ZEROES.fetch(node.type), LEAF_PRECEDENCE]
        when LocalRead        then [node.binding_name.to_s, LEAF_PRECEDENCE]
        when CaptureRead      then [c_name(node.name), LEAF_PRECEDENCE]
        # A read is widened to the type the kernel computes in, because that
        # is the type the Ruby loop computes in: reading a float32 cell in
        # Ruby gives a Float, and reading an int32 cell gives an Integer that
        # does not stop at 2**31.  Left as it lies, C would do the arithmetic
        # in float and in int -- narrower than Ruby on both counts, and
        # undefined rather than merely different when a narrow int overflows.
        #
        # A boolean cell is a byte holding 0 or 1, so it is already the value
        # it stands for.  Keeping it that way on the way out is this kernel's
        # business, and cast_to_storage does it.
        when ElementRead
          cell = cell_reference(node.array, node.subscripts)
          widening = widening_cast(node.array, node.type)
          if widening
            ["#{widening}#{parenthesize(cell, LEAF_PRECEDENCE, UNARY_PRECEDENCE)}",
             UNARY_PRECEDENCE]
          else
            [cell, LEAF_PRECEDENCE]
          end
        when MaskTest         then emit_mask_test(node)
        when UnaryMinus
          operand, precedence = emit_raw(node.operand)
          ["-#{parenthesize(operand, precedence, UNARY_PRECEDENCE)}", UNARY_PRECEDENCE]
        when LogicalNot
          operand, precedence = emit_raw(node.operand)
          ["! #{parenthesize(operand, precedence, UNARY_PRECEDENCE)}", UNARY_PRECEDENCE]
        when LogicalOperation
          precedence = PRECEDENCE.fetch(node.operator)
          ["#{emit_operand(node.left, :boolean, precedence)} #{node.operator} " \
           "#{emit_operand(node.right, :boolean, precedence)}", precedence]
        when AbsoluteValue then emit_absolute_value(node)
        when Conversion   then emit_conversion(node)
        when ComplexPart  then emit_complex_part(node)
        when ComplexBuild
          real = TypeAssignment::REAL_PART_TYPES.fetch(node.type)
          ["#{complex_build(node.type)}(#{emit(node.real, real)}, " \
           "#{emit(node.imaginary, real)})", LEAF_PRECEDENCE]
        when Power        then emit_power(node)
        when MathCall then emit_math_call(node)
        when ArrayAddress
          [c_name(node.array), LEAF_PRECEDENCE]
        when PointerRead
          # A pointer parameter is reached the way C reaches it: contiguous,
          # from the address it was handed.  No base, no stride, no bounds --
          # a subscript here is the caller's business, as it is in C.
          ["#{node.name}[#{emit(node.index, :int64)}]", LEAF_PRECEDENCE]
        when RecursiveCall
          # The function calls itself by the symbol it is being defined
          # under, not by the name the declaration spelled: that name is
          # unqualified and would reach whatever else in the process answers
          # to it.  A captured function travels as a pointer beside the
          # scalars; this one is right here, so the call is direct.
          arguments = node.arguments.zip(node.parameters)
                          .map { |argument, parameter|
                            if argument.is_a?(ArrayAddress)
                              emit(argument, :address)
                            else
                              emit(argument, parameter.computation)
                            end
                          }
          arguments << ERROR_FLAG if @error_parameter
          ["#{@own_symbol}(#{arguments.join(', ')})", LEAF_PRECEDENCE]
        when CFunctionCall
          c_function = @c_functions.fetch(node.name)
          arguments = node.arguments.zip(c_function.parameters)
                          .map { |argument, parameter|
                            if argument.is_a?(ArrayAddress)
                              emit(argument, :address)
                            else
                              emit(argument, parameter.computation)
                            end
                          }
          # A pasted body is reached by its symbol; an address by the local
          # the declarations bound it to.
          called = c_function.pasted? ? c_function.name : c_name(node.name)
          # And one that can report a failure is handed the slot this kernel
          # is watching -- null under a masked cell, where the value written
          # is out of contract and a division by zero there was not asked
          # about.  The helpers it calls check for that, as the kernel's own
          # do.
          arguments << error_argument if c_function.pasted_takes_error?
          ["#{called}(#{arguments.join(', ')})", LEAF_PRECEDENCE]
        when Conditional      then emit_ternary(node)
        when BinaryOperation  then emit_binary(node)
        else
          raise Error, "code generation reached #{node.class}"
        end
      end

      # `a[i] == UNDEF` reads the mask byte, never the value.
      def emit_mask_test (node)
        cell = cell_reference(node.array, node.subscripts, :mask)
        node.negated ? ["! #{cell}", UNARY_PRECEDENCE] : [cell, LEAF_PRECEDENCE]
      end

      # Float#floor and friends hand back an Integer in Ruby, so the C rounds
      # and then narrows.  An Integer receiver is already there.
      def emit_conversion (node)
        if TypeAssignment::INTEGER_TYPES.include?(node.operand.type)
          if node.type == node.operand.type
            return [emit(node.operand, node.operand.type), LEAF_PRECEDENCE]
          end
          return ["(double)#{parenthesize(*emit_raw(node.operand), LEAF_PRECEDENCE)}",
                  UNARY_PRECEDENCE]
        end
        return [emit(node.operand, :double), LEAF_PRECEDENCE] if node.result_type == :double
        ["(int64_t)#{node.name}(#{emit(node.operand, :double)})", UNARY_PRECEDENCE]
      end

      # creal and cimag are the way out of the complex type; conj stays in it.
      #
      # A real number answers all four in Ruby, and three of them without
      # computing anything: it is its own real part and its own conjugate,
      # and its imaginary part is a zero.
      def emit_complex_part (node)
        if complex_type?(node.operand.type)
          function = { :real => "creal", :imaginary => "cimag",
                       :conjugate => "conj", :arg => "carg" }.fetch(node.name)
          function += "f" if node.operand.type == :float_complex
          return ["#{function}(#{emit(node.operand, node.operand.type)})",
                  LEAF_PRECEDENCE]
        end
        case node.name
        when :real, :conjugate then emit_raw(node.operand)
        when :imaginary        then [ZEROES.fetch(:int64), LEAF_PRECEDENCE]
        else
          @uses_real_arg = true
          ["carray_jit_real_arg(#{emit(node.operand, :double)})", LEAF_PRECEDENCE]
        end
      end

      # An integer power is squared out rather than sent through pow, whose
      # double result would not be the exact integer Ruby gives.
      #
      # A complex power is the one place in this compiler where the answer is
      # not the Ruby loop's to the last bit.  Ruby raises a Complex to a power
      # by binary powering, with exact answers along the axes; cpow goes round
      # through exp and log.  They agree to within an ulp, and that is
      # accepted here rather than reproducing complex.c's algorithm -- which
      # has changed between Ruby versions, so reproducing it would tie a
      # compiled kernel to the interpreter that compiled it.
      def emit_power (node)
        if complex_type?(node.type)
          text = "cpow(#{emit(node.base, :complex)}, " \
                 "#{emit(node.exponent, :complex)})"
          return [text, LEAF_PRECEDENCE] if node.type == :complex
          return ["(float _Complex)#{text}", UNARY_PRECEDENCE]
        end
        if node.type == :uint64
          @uses_unsigned_power = true
          return ["carray_jit_unsigned_power(#{emit(node.base, :uint64)}, " \
                  "#{emit(node.exponent, :uint64)})", LEAF_PRECEDENCE]
        end
        if node.type == :int64
          @uses_integer_power = true
          return ["carray_jit_integer_power(#{emit(node.base, :int64)}, " \
                  "#{emit(node.exponent, :int64)})", LEAF_PRECEDENCE]
        end
        if node.type == :float
          return ["powf(#{emit(node.base, :float)}, " \
                  "#{emit(node.exponent, :float)})", LEAF_PRECEDENCE]
        end
        unhandled_type(node, "**") unless node.type == :double
        ["pow(#{emit(node.base, :double)}, #{emit(node.exponent, :double)})",
         LEAF_PRECEDENCE]
      end

      # cabs, fabs and llabs are three functions rather than one because C has
      # no generic for them, so this names each type instead of letting one of
      # them be what a type it has not heard of falls into.
      def emit_absolute_value (node)
        # The complex case is asked of the operand rather than of the result:
        # the magnitude of a complex number is a real one, so node.type is
        # already :double by the time we are here.
        if complex_type?(node.operand.type)
          function = node.operand.type == :float_complex ? "cabsf" : "cabs"
          return ["#{function}(#{emit(node.operand, node.operand.type)})",
                  LEAF_PRECEDENCE]
        end
        case node.type
        when :double  then ["fabs(#{emit(node.operand, :double)})", LEAF_PRECEDENCE]
        when :float   then ["fabsf(#{emit(node.operand, :float)})", LEAF_PRECEDENCE]
        when :int64   then ["llabs(#{emit(node.operand, :int64)})", LEAF_PRECEDENCE]
        # An unsigned number is its own magnitude, and llabs would take it
        # through a signed type on the way.
        when :uint64  then [emit(node.operand, :uint64), LEAF_PRECEDENCE]
        else unhandled_type(node, "abs")
        end
      end

      def emit_ternary (node)
        ["#{emit(node.condition, :boolean)} ? " \
         "#{emit(node.consequent, node.type)} : " \
         "#{emit(node.alternative, node.type)}", 10]
      end

      def emit_binary (node)
        return emit_integer_division(node) if node.operator == :/ &&
                                             TypeAssignment::INTEGER_TYPES.include?(node.type)
        return emit_modulo(node) if node.operator == :%
        return emit_complex_binary(node) if complex_type?(node.type)

        operand_type =
          if Analyzer::COMPARISON_OPERATORS.include?(node.operator)
            # Both sides are brought to the wider of the two, which is the
            # only way `z == 1` asks what Ruby asks.
            [node.left.type, node.right.type]
              .max_by { |type| NUMERIC_RANK.fetch(type, -1) }
          else
            node.type
          end

        precedence = PRECEDENCE.fetch(node.operator)
        left = emit_operand(node.left, operand_type, precedence)
        # Every operator here groups to the left, so a right operand of the
        # same precedence needs parentheses whatever the operator is.  Not
        # because C would compute a different number for integers -- it would
        # not -- but because floating-point arithmetic does not associate:
        # `a + (b + c)` regrouped as `(a + b) + c` is a different sum, and
        # this compiler's whole claim is that it computes what the same
        # expression computes in Ruby.  `-` and `/` were handled and `+` and
        # `*` were not, on the reasoning that they associate.  They associate
        # in arithmetic; doubles are not arithmetic.
        right = emit_operand(node.right, operand_type, precedence, true)
        ["#{left} #{node.operator} #{right}", precedence]
      end

      # Ruby's Complex arithmetic is not C's, in three places that matter.
      #
      # A Complex added to a real number is added component by component, and
      # the imaginary part comes through untouched rather than having a zero
      # added to it: Ruby's `f_add` returns the other operand as it stands
      # when one of them is the exact Integer zero a real operand carries.
      # So `Complex(1.0, -0.0) + 2.0` is `3.0-0.0i`, where widening the 2.0
      # to a complex first would give `3.0+0.0i`, because `-0.0 + 0.0` is
      # `+0.0`.  Multiplying by a real scales each part for the same reason,
      # and dividing by one divides each part.
      #
      # Subtraction is the exception: there the zero really is subtracted, in
      # Ruby as in C, so `z - x` and `x - z` are C's own operator.  So is
      # `x * z`, which Ruby coerces and multiplies out in full -- which is
      # why `2.0 * Complex(1.0, -0.0)` and `Complex(1.0, -0.0) * 2.0` do not
      # agree with each other, and each is reproduced its own way.
      #
      # And a complex division is Smith's method as complex.c writes it,
      # which is not what the C library's __divdc3 computes.
      #
      # Each of these goes through a function rather than being written out,
      # so that the operand is named once: spelling `CMPLX(creal(z) + x,
      # cimag(z))` inline would emit the whole of z twice, and twice again
      # for the operation outside it.
      def emit_complex_binary (node)
        complex_type = node.type
        # Multiplying and dividing two complex numbers are the operations
        # that cancel: `(ac - bd)` and Smith's method both subtract numbers of
        # the same size, so the narrow width loses the answer rather than the
        # last bit of it.  Both are reached in double and rounded once, which
        # is what Ruby does and what CArray settled on.  Adding and
        # subtracting do not cancel past the one rounding a store makes
        # anyway, so they stay narrow.
        if complex_type == :float_complex &&
           [:*, :/].include?(node.operator) &&
           complex_type?(node.left.type) && complex_type?(node.right.type)
          helper = mixed_helper(node, :complex)
          if helper
            text, = emit_helper_call(*helper, false)
          else
            precedence = PRECEDENCE.fetch(node.operator)
            # Parenthesised, because the cast binds tighter than the operator:
            # without them it would narrow the left operand and leave the
            # multiplication to be worked out around it.
            text = "(#{emit_operand(node.left, :complex, precedence)} " \
                   "#{node.operator} " \
                   "#{emit_operand(node.right, :complex, precedence)})"
          end
          return ["(float _Complex)#{text}", UNARY_PRECEDENCE]
        end
        narrow = complex_type == :float_complex
        helper = mixed_helper(node, complex_type)
        return emit_helper_call(*helper, narrow) if helper
        precedence = PRECEDENCE.fetch(node.operator)
        ["#{emit_operand(node.left, complex_type, precedence)} #{node.operator} " \
         "#{emit_operand(node.right, complex_type, precedence, node.operator == :-)}",
         precedence]
      end

      def emit_helper_call (name, arguments, narrow)
        @complex_helpers |= [[name, narrow]]
        prefix = narrow ? "carray_jit_f_" : "carray_jit_"
        ["#{prefix}#{name}(#{arguments.join(', ')})", LEAF_PRECEDENCE]
      end

      # Which helper an operation carrying a complex operand needs, and what
      # to pass it -- or nil where C's own operator is what Ruby computes.
      def mixed_helper (node, ctype)
        rtype = TypeAssignment::REAL_PART_TYPES.fetch(ctype)
        left, right, operator = node.left, node.right, node.operator
        case operator
        when :/
          return ["complex_div_real", [emit(left, ctype), emit(right, rtype)]] if
            real_type?(right)
          return ["real_divide_complex", [emit(left, rtype), emit(right, ctype)]] if
            real_type?(left)
          ["complex_divide", [emit(left, ctype), emit(right, ctype)]]
        when :+
          if imaginary_literal?(right)
            ["complex_add_imaginary", [emit(left, ctype), format_float(right.value.to_f, rtype)]]
          elsif imaginary_literal?(left)
            ["imaginary_add_complex", [format_float(left.value.to_f, rtype), emit(right, ctype)]]
          elsif real_type?(right)
            ["complex_add_real", [emit(left, ctype), emit(right, rtype)]]
          elsif real_type?(left)
            ["real_add_complex", [emit(left, rtype), emit(right, ctype)]]
          end
        when :*
          if real_type?(right)
            ["complex_mul_real", [emit(left, ctype), emit(right, rtype)]]
          end
        end
      end

      def complex_type? (type)
        TypeAssignment.complex?(type)
      end

      # CMPLX and CMPLXF, which carry the sign of both zeros where writing
      # `re + im * I` would not.
      def complex_build (type)
        type == :float_complex ? "CMPLXF" : "CMPLX"
      end

      # The complex functions that are safe to reach at the narrow width, and
      # they are a list rather than a rule because the reason is inside the
      # library.  A libm transcendental is written to complete at its own
      # width, so `csinf` is a float32 answer to a float32 question.  What is
      # not safe is a function that builds something out of the operand
      # before the transcendental starts: `clog(z)` needs `log|z|`, and on the
      # unit circle that is the difference of two numbers near one.  Computed
      # in float, |z| rounds to exactly one and the real part of the answer
      # becomes zero -- measured here on four thousand points of the unit
      # circle, the error is 3.2e-08 where the answer itself is 3.7e-08.
      #
      # `**` is the same fault at one remove, `cpow` being `cexp(z * clog(a))`,
      # so it is emitted wide in emit_power and is not on this list either.
      NARROW_COMPLEX_MATH = %w[
        csqrt cexp csin ccos ctan casin catan csinh ccosh ctanh
      ].freeze

      # A math function is reached at the width its argument claims, where
      # that is safe: `sinf` for a float32 cell, `csqrtf` for a cmplx64 one.
      # That is what CArray computes, and agreeing with it by construction is
      # worth more than agreeing because this platform happens to implement
      # `sinf` through `sin`.
      #
      # The real functions are all safe: `log(x)` reads its argument rather
      # than building one, so `logf` does not lose what `clogf` loses.
      def emit_math_call (node)
        if complex_type?(node.type)
          function = Analyzer::COMPLEX_MATH_FUNCTIONS.fetch(node.name)
          narrow = node.type == :float_complex &&
                   NARROW_COMPLEX_MATH.include?(function)
          type = narrow ? :float_complex : :complex
          function += "f" if narrow
          arguments = node.arguments.map { |argument| emit(argument, type) }
          text = "#{function}(#{arguments.join(', ')})"
          return [text, LEAF_PRECEDENCE] if narrow || node.type == :complex
          return ["(float _Complex)#{text}", UNARY_PRECEDENCE]
        end
        function = node.name.to_s
        function += "f" if node.type == :float
        arguments = node.arguments.map { |argument| emit(argument, node.type) }
        ["#{function}(#{arguments.join(', ')})", LEAF_PRECEDENCE]
      end

      def real_type? (node)
        TypeAssignment::REAL_TYPES.include?(node.type)
      end

      def imaginary_literal? (node)
        node.is_a?(ImaginaryLiteral)
      end

      # Integer `/` is floored to agree with Ruby and with CArray's own
      # kernels.  A positive power-of-two divisor needs no correction at all:
      # an arithmetic shift already floors, and is cheaper than the truncating
      # divide the C operator would emit.
      def emit_integer_division (node)
        type = node.type
        shift = power_of_two_shift(node.right)
        if shift
          return ["#{emit_operand(node.left, type, 85)} >> #{shift}", 50]
        end
        # An unsigned operand cannot be negative, so C's truncation already
        # floors and only the zero divisor has to be caught.
        if type == :uint64
          @uses_unsigned_divide = true
          return ["carray_jit_unsigned_divide(#{emit(node.left, :uint64)}, " \
                  "#{emit(node.right, :uint64)}, #{error_argument})",
                  LEAF_PRECEDENCE]
        end
        @uses_floor_divide = true
        ["carray_jit_floor_divide(#{emit(node.left, :int64)}, " \
         "#{emit(node.right, :int64)}, #{error_argument})", LEAF_PRECEDENCE]
      end

      # `%` floors, so it is not C's `%` -- see the helper above.
      def emit_modulo (node)
        if node.type == :uint64
          @uses_unsigned_modulo = true
          return ["carray_jit_unsigned_modulo(#{emit(node.left, :uint64)}, " \
                  "#{emit(node.right, :uint64)}, #{error_argument})",
                  LEAF_PRECEDENCE]
        end
        @uses_floor_modulo = true
        if node.type == :int64
          return ["carray_jit_floor_modulo(#{emit(node.left, :int64)}, " \
                  "#{emit(node.right, :int64)}, #{error_argument})", LEAF_PRECEDENCE]
        end
        if node.type == :float
          @uses_floor_modulo_float = true
          return ["carray_jit_floor_modulo_float(#{emit(node.left, :float)}, " \
                  "#{emit(node.right, :float)})", LEAF_PRECEDENCE]
        end
        unhandled_type(node, "%") unless node.type == :double
        ["carray_jit_floor_modulo_real(#{emit(node.left, :double)}, " \
         "#{emit(node.right, :double)})", LEAF_PRECEDENCE]
      end

      def power_of_two_shift (node)
        return nil unless node.is_a?(IntegerLiteral)
        value = node.value
        return nil unless value > 0 && (value & (value - 1)).zero?
        Math.log2(value).to_i
      end

      def format_integer (value)
        "INT64_C(#{value})"
      end

      def format_float (value, type = :double)
        # A float literal without the suffix is a double, and one double in an
        # expression takes the whole expression with it -- so the suffix is
        # what keeps a float32 kernel computing in float.
        if type == :float
          # 9 significant digits round-trips a float exactly.
          text = format("%.9g", value)
          text << ".0" unless text.match?(/[.eEn]/)
          return text << "f"
        end
        # 17 significant digits round-trips a double exactly.
        text = format("%.17g", value)
        text << ".0" unless text.match?(/[.eEn]/)
        text
      end

      def next_temporary (prefix = "result")
        @temporary_count += 1
        "#{prefix}#{@temporary_count}"
      end

    end

  end
end
