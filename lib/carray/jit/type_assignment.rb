class CArray
  module JIT

    # Assigns a computation type to every node.
    #
    # This is assignment, not inference: each array's dtype and the runtime
    # classes of the captured scalars fix the leaves, and everything else
    # propagates bottom-up.
    #
    # The distinction that matters is between *storage* type and *computation*
    # type: what an array holds, and what a kernel works on a cell of it in.
    # They are not the same -- int8 is computed in int64 -- and the table
    # below is what says which.
    #
    # A narrow float is computed narrow: float32 in `float` and cmplx64 in
    # `float _Complex`, read narrow and stored narrow. That is what CArray's
    # own kernels do, so the two agree; the Ruby evaluator, which would widen
    # to a double, is what they both differ from. See docs/03 and docs/05.
    class TypeAssignment

      STORAGE_COMPUTATION_TYPES = {
        "float64"  => :double,
        "float32"  => :float,
        "int64"    => :int64,
        "int32"    => :int64,
        "int16"    => :int64,
        "int8"     => :int64,
        # The unsigned widths that int64 holds exactly.  uint64 does not --
        # it carries values above 2**63 that int64 cannot represent -- so it
        # computes in a type of its own rather than being quietly wrapped.
        "uint32"   => :int64,
        "uint16"   => :int64,
        "uint8"    => :int64,
        "uint64"   => :uint64,
        "boolean"  => :boolean,
        "cmplx64"  => :float_complex,
        "cmplx128" => :complex,
      }.freeze

      # What each computation type is, which is the one place a new one is
      # added.  Every question a guard asks -- is this an integer, can it be
      # a subscript, will `~` take it -- is asked of the kind rather than of a
      # list of names, so that a type added here is a type every guard already
      # knows about.  A list of names is the shape that goes stale silently:
      # it keeps answering, and answers wrongly, for the type nobody added.
      KINDS = {
        :int64   => :integer,
        :uint64  => :integer,
        :float   => :real,
        :double  => :real,
        :float_complex => :complex,
        :complex => :complex,
        :boolean => :boolean,
      }.freeze

      # The array `jit_map` allocates for a value of each computation type:
      # the storage that holds what was computed without narrowing it.  Here
      # beside KINDS, and not written out where the result is allocated, for
      # the reason KINDS gives: a table of names kept somewhere else keeps
      # answering after a computation type is added, and answers wrongly.
      RESULT_STORAGE_TYPES = {
        :int64         => :int64,
        :uint64        => :uint64,
        :float         => :float32,
        :double        => :float64,
        # cmplx64 is to cmplx128 what float32 is to float64: the value was
        # computed narrow, and cmplx64 holds it without widening or losing it.
        :float_complex => :cmplx64,
        :complex       => :cmplx128,
      }.freeze

      # Raises rather than falling back, because there is no type to fall back
      # to: every candidate narrows something.  A computation type that is not
      # here is one nobody decided a result for, and saying so is the whole
      # point of asking.
      def self.result_storage_type (type)
        RESULT_STORAGE_TYPES.fetch(type) do
          raise Unsupported,
                "a block whose value is #{type} has no array to be collected " \
                "into"
        end
      end

      # Narrowest first: the order is how they widen into one another, which
      # is Ruby's own promotion -- `1 + 1.5` is a Float, `1.5 + 1i` a Complex.
      #
      # This one stays a list because it is an order rather than a set: the
      # sets below are derived from KINDS, but which of two types is the wider
      # is not something a kind can answer.
      #
      # :uint64 sits above :int64 rather than beside it, which is not
      # containment -- neither type holds the other -- but is what CArray
      # answers (`CArray.result_type(:uint64, :int64)` is `:uint64`) and what
      # C's usual arithmetic conversions do with the same pair.  Ruby has no
      # opinion to follow here: its Integer has no width, so it never reaches
      # the case.  Both of the languages that do agree, so the order is
      # theirs.
      NUMERIC_TYPES =
        [:int64, :uint64, :float, :double, :float_complex, :complex].freeze

      # The types a real number can be, which is every place a complex one
      # cannot go: a subscript, a loop bound, an argument to floor.
      REAL_TYPES =
        NUMERIC_TYPES.select { |type| [:integer, :real].include?(KINDS[type]) }
                     .freeze

      # The types whose `/` floors rather than dividing, whose `**` stays
      # exact, and which a bitwise operator will take.  Asking this rather
      # than asking whether a type is :int64 is what lets a second integer
      # type exist at all.
      INTEGER_TYPES =
        NUMERIC_TYPES.select { |type| KINDS[type] == :integer }.freeze

      # The questions the guards ask.  A type KINDS does not know is nothing:
      # every one of these answers false for it, so a guard written as "refuse
      # unless this is a number" refuses it rather than letting it through.
      def self.integer? (type)  = KINDS[type] == :integer
      # A Float, and not an Integer standing on the same line: `nan?` is
      # asked of one and refused by the other, as Ruby refuses it.
      def self.floating? (type) = KINDS[type] == :real
      def self.real? (type)     = REAL_TYPES.include?(type)
      def self.complex? (type)  = KINDS[type] == :complex
      def self.boolean? (type)  = KINDS[type] == :boolean
      def self.numeric? (type)  = NUMERIC_TYPES.include?(type)

      def integer? (type) = self.class.integer?(type)
      def floating? (type) = self.class.floating?(type)
      def real? (type)    = self.class.real?(type)
      def complex? (type) = self.class.complex?(type)
      def boolean? (type) = self.class.boolean?(type)
      def numeric? (type) = self.class.numeric?(type)

      attr_reader :scalar_types

      # Exposed so that the hot path can build a cache key from the capture
      # values without running a full analysis.
      def self.scalar_type (value)
        case value
        when Float   then :double
        when Integer then :int64
        when Complex then :complex
        else
          # A generator captured by name is worth its own answer: it is not a
          # value the kernel could carry, and what to do instead is the same
          # thing `rand` inside the block is told.
          if value.is_a?(Random) || value.equal?(Random) || value.equal?(Kernel)
            raise Unsupported,
                  "a generator draws in an order a kernel does not fix; fill " \
                  "an array with `CArray#random!` and read a cell of it, as " \
                  "the kernel reads any other array"
          end
          raise Unsupported,
                "captured scalars must be Float, Integer or Complex, got " \
                "#{value.class}"
        end
      end

      def self.storage_type (name)
        return STORAGE_COMPUTATION_TYPES[name] if STORAGE_COMPUTATION_TYPES[name]
        raise Unsupported, "unsupported array data type `#{name}`"
      end

      # `scalar_types` is given rather than derived when the leaves are
      # declared instead of captured -- a function's parameters are named in
      # its signature, and there is no value to read a type off.
      def initialize (body, storage_types, scalar_values, c_functions = {},
                      scalar_types: nil, pointer_types: {})
        @body = body
        @c_functions = c_functions
        @pointer_types = pointer_types
        @element_types = storage_types.transform_values { |name|
          self.class.storage_type(name)
        }
        @scalar_types = scalar_types || scalar_values.transform_values { |value|
          self.class.scalar_type(value)
        }
        @bindings = {}
        @binding_counts = Hash.new(0)
        assign
      end

      private

      # Types are settled in one forward pass, because that is how Ruby reads
      # the body: a local holds whatever it was last assigned.
      #
      # That matters when the type changes.  `x = 5; y = x / 2; x = 1.5` is an
      # integer division in Ruby and a float one after, and no single C
      # variable is both, so each type gets a variable of its own.
      def assign
        walk(@body)
        verify(@body)
      end

      def bind (name, type)
        current = @bindings[name]
        return current.last if current && current.first == type
        @binding_counts[name] += 1
        suffix = @binding_counts[name] == 1 ? "" : "__#{@binding_counts[name]}"
        @bindings[name] = [type, :"#{name}#{suffix}"]
        @bindings[name].last
      end

      def walk (node)
        case node
        when KernelBody
          node.statements.each { |statement| walk(statement) }
        when Assignment
          walk(node.expression)
          node.type = node.expression.type
          node.binding_name = bind(node.name, node.type)
        when ElementWrite
          walk_subscripts(write_subscripts(node))
          walk(node.expression)
          node.type = element_type(node.array, node.location)
        when MaskWrite
          walk_subscripts(write_subscripts(node))
          node.type = element_type(node.array, node.location)
        when MaskTest
          walk_subscripts(node.subscripts)
          node.type = :boolean
        when NumericPredicate
          walk(node.operand)
          node.type = :boolean
        when InnerLoop
          walk(node.from)
          walk(node.to)
          entering = @bindings.dup
          node.statements.each { |statement| walk(statement) }
          verify_loop_carries_one_type(entering, node)
        when While
          # The condition first, and that is not only an order: a name the
          # body introduces is not bound yet when the condition is walked, so
          # `while x < 3` over an `x` the body assigns is refused there rather
          # than reading whatever C left in the variable on the first pass.
          walk(node.condition)
          entering = @bindings.dup
          node.statements.each { |statement| walk(statement) }
          verify_loop_carries_one_type(entering, node)
        when Print
          node.arguments.each { |argument| walk(argument) }
        when CallStatement
          # The arguments are typed as they would be anywhere; the result is
          # not, because nothing takes it.  That is what lets a `void`
          # function be called at all: its return type is a slot in the
          # signature, and a slot nobody reads is no obstacle.
          call = node.call
          call.arguments.each { |argument| walk(argument) }
          call.type =
            case call
            when RecursiveCall then call.result_type
            else @c_functions.fetch(call.name).discarded_result_type
            end
          node.type = :void
        when Raise
          # A message, settled when the kernel was compiled.
        when LoopSkip, LoopStop
          # Control flow, carrying no value and so no type.
        when Branch
          # Each arm is typed from the state before the branch, and a local
          # whose type ends up different on the two paths has no single C
          # variable to be, so it does not survive the branch.
          walk(node.condition)
          before = @bindings.dup
          node.consequent.each { |statement| walk(statement) }
          from_consequent = @bindings
          @bindings = before.dup
          node.alternative.each { |statement| walk(statement) }
          @bindings = merge_bindings(from_consequent, @bindings)
        when IntegerLiteral
          node.type = :int64
        when FloatLiteral
          node.type = :double
        when ImaginaryLiteral
          node.type = :complex
        when BooleanLiteral
          node.type = :boolean
        when IndexVariable
          node.type = :int64
        when BoundsValue
          node.type = :int64
        when ZeroLike
          walk(node.reference)
          node.type = node.reference.type
        when ElementRead
          walk_subscripts(node.subscripts)
          node.type = element_type(node.array, node.location)
        when CaptureRead
          type = @scalar_types[node.name]
          unless type
            raise Unsupported.new("no value supplied for `#{node.name}`", node.location)
          end
          node.type = type
        when LocalRead
          current = @bindings[node.name]
          unless current
            raise Unsupported.new("`#{node.name}` is read before it is assigned",
                                  node.location)
          end
          node.type, node.binding_name = current
        when UnaryMinus
          walk(node.operand)
          node.type = node.operand.type
        when AbsoluteValue
          walk(node.operand)
          # `Complex#abs` is the magnitude, and a Float -- unlike the other
          # unary operators, abs does not keep the type it was given.
          node.type = complex?(node.operand.type) ? :double : node.operand.type
        when Conversion
          walk(node.operand)
          # `floor`, `ceil`, `round` and `to_i` name int64 as what they
          # produce, which is the right answer for a Float and the wrong one
          # for a uint64: Ruby's Integer#floor is the number itself, so a
          # width may not be lost on the way through.  An integer operand
          # keeps its own type and the conversion is nothing to emit.
          node.type =
            if node.result_type == :int64 && integer?(node.operand.type)
              node.operand.type
            else
              node.result_type
            end
        when ComplexPart
          walk(node.operand)
          node.type = complex_part_type(node)
        when ComplexBuild
          node.children.each { |child| walk(child) }
          node.type = :complex
        when LogicalOperation
          node.children.each { |child| walk(child) }
          node.type = :boolean
        when LogicalNot
          walk(node.operand)
          node.type = :boolean
        when BitwiseNot
          walk(node.operand)
          node.type = node.operand.type
        when Power
          walk(node.base)
          walk(node.exponent)
          node.type = join_operands(node.base, node.exponent)
        when MathCall
          node.arguments.each { |argument| walk(argument) }
          node.type = math_call_type(node)
        when PointerRead
          walk(node.index)
          # Declared, not inferred: the prototype said what it points at.
          node.type = @pointer_types.fetch(node.name)
        when PointerWrite
          walk(node.index)
          walk(node.expression)
          node.type = @pointer_types.fetch(node.name)
        when ArrayAddress
          # An address is not a value; nothing computes with it, and the only
          # place it may stand is a C function's pointer parameter.
          node.type = :address
        when RecursiveCall
          # The declaration already said, the same way it says for a captured
          # function; there is nothing here to infer from a body that is
          # still being walked.
          node.arguments.each { |argument| walk(argument) }
          if node.result_type.nil?
            raise Unsupported.new(
              "`#{node.name}` returns `void`, which is a slot in the " \
              "signature rather than a value a kernel can compute with; a " \
              "call to it may stand where a statement stands",
              node.location)
          end
          node.type = node.result_type
        when CFunctionCall
          # Nothing is inferred here: the prototype said what the function
          # returns and what it takes, and the arguments are converted to
          # meet it.  That is the same rule the rest of this file follows --
          # types are assigned from the leaves, not solved for.
          node.arguments.each { |argument| walk(argument) }
          function = @c_functions.fetch(node.name)
          # Named by the local the block reached it by rather than by the
          # symbol it compiled to, which is the name a reader of the block
          # can look for.
          if function.discarded_result_type == :void
            raise Unsupported.new(
              "`#{node.name}` returns `void`, which is a slot in the " \
              "signature rather than a value a kernel can compute with; a " \
              "call to it may stand where a statement stands",
              node.location)
          end
          node.type = function.result_type
        when Conditional
          node.children.each { |child| walk(child) }
          node.type = join_operands(node.consequent, node.alternative)
        when BinaryOperation
          walk(node.left)
          walk(node.right)
          node.type =
            if Analyzer::COMPARISON_OPERATORS.include?(node.operator)
              :boolean
            elsif [:<<, :>>].include?(node.operator)
              # A shift takes its count as a number and keeps the type of the
              # thing being shifted.
              node.left.type
            else
              join_operands(node.left, node.right)
            end
        else
          raise Error, "type assignment reached #{node.class}"
        end
      end

      # A local that is carried across a loop's back edge has to be the same
      # type on the way round as it was on the way in.  The forward pass reads
      # the body once, the way Ruby reads it -- but Ruby reads it again on the
      # next pass, with whatever the body left behind, and `x = 2` outside a
      # loop with `x = 1.5` inside it means an integer division on the first
      # pass and a float one after.  One C variable cannot be both, and this
      # is not the branch case where the local simply does not survive: the
      # value goes round the loop.
      def verify_loop_carries_one_type (entering, node)
        entering.each do |name, (type, _)|
          now = @bindings[name]
          next if now.nil? || now.first == type
          raise Unsupported.new(
            "`#{name}` enters this loop as #{article(type)} and comes back " \
            "round as #{article(now.first)}; the value carried to the next " \
            "pass would change type, and one C variable is one type -- give " \
            "it one type before the loop",
            node.location)
        end
      end

      # What to call a type in a message.  These are Ruby's names where Ruby
      # has one; :uint64 keeps CArray's, because the thing that distinguishes
      # it from :int64 is a width, and Ruby's Integer has none -- a message
      # that called both of them "an Integer" would be saying the two types in
      # a mismatch are the same type.
      NAMES = { :int64 => "Integer", :uint64 => "uint64", :double => "Float",
                :float => "float32", :complex => "Complex",
                :float_complex => "cmplx64" }.freeze

      def self.name_of (type)
        NAMES.fetch(type, type.to_s)
      end

      def article (type)
        type == :int64 ? "an Integer" : "a #{self.class.name_of(type)}"
      end

      # The parts of a real number, which Ruby answers rather than refusing:
      # `1.5.real` is 1.5 and `1.5.imaginary` is an Integer zero.
      #
      # `arg` is the one that does not settle: Ruby hands back an Integer zero
      # for a number that is not negative and Math::PI for one that is, so its
      # class depends on the value.  One C variable is one type, so it is a
      # Float throughout -- the same number either way, since the zero is a
      # zero whichever class carries it.
      # The real width that goes with a complex one: the parts of a cmplx64
      # are float32s, as CArray's own `real`, `imag`, `abs` and `arg` say.
      REAL_PART_TYPES = { :complex => :double, :float_complex => :float }.freeze

      def complex_part_type (node)
        if complex?(node.operand.type)
          return node.operand.type if node.name == :conjugate
          return REAL_PART_TYPES.fetch(node.operand.type)
        end
        case node.name
        when :real, :conjugate then node.operand.type
        when :imaginary        then :int64
        else                        :double
        end
      end

      # A math function of a complex argument is complex, and the ones with
      # no complex form say so rather than silently taking the real part --
      # which is what C would do if the call were emitted as it stands.
      def math_call_type (node)
        unless node.arguments.any? { |a| complex?(a.type) }
          # The width the arguments agree on.  An integer has none to offer --
          # `Math.sqrt(2)` is a Float in Ruby -- so it widens to double, and a
          # float32 argument keeps float32, which is the width CArray computes
          # the same call at.
          joined = node.arguments.map(&:type).reduce { |a, b| join(a, b) }
          return integer?(joined) ? :double : joined
        end
        if node.arguments.size > 1
          raise Unsupported.new(
            "`#{node.name}` takes two real numbers; a complex number is " \
            "already the plane it is asking about", node.location)
        end
        unless Analyzer::COMPLEX_MATH_FUNCTIONS.key?(node.name)
          raise Unsupported.new(
            "`#{node.name}` has no complex form -- C99 has none and a " \
            "complex CArray refuses it too", node.location)
        end
        # As wide as the argument, and reached at that width: CArray computes
        # a cmplx64 through the f-suffixed complex library rather than through
        # double, so a kernel does too.
        node.arguments.find { |a| complex?(a.type) }.type
      end

      # A write into the cell the loop is on has no subscripts of its own.
      def write_subscripts (node)
        node.respond_to?(:subscripts) && node.subscripts ? node.subscripts : []
      end

      # A subscript's expression sits beside the tree rather than in it: the
      # position a pinned axis is held at, or the offset a walked one is read
      # away from.
      def walk_subscripts (subscripts)
        subscripts.each do |_index, offset|
          next unless offset.is_a?(Node)
          walk(offset)
          next if integer?(offset.type)
          raise Unsupported.new(
            "a subscript is an integer; this one is #{offset.type}",
            offset.location)
        end
      end

      def element_type (array, location)
        @element_types[array] or
          raise Unsupported.new("no array supplied for `#{array}`", location)
      end

      def merge_bindings (left, right)
        (left.keys & right.keys).each_with_object({}) do |name, merged|
          merged[name] = left[name] if left[name] == right[name]
        end
      end

      # Integer and Float mix to Float, as in Ruby.
      # `&`, `|` and `^` join two integers or two booleans, and a shift moves
      # an integer -- which is what they do in Ruby, where `1.5 & 1` raises.
      def verify_bitwise (node)
        left, right = node.left.type, node.right.type
        if [:&, :|, :^].include?(node.operator) &&
           boolean?(left) && boolean?(right)
          return
        end
        return if integer?(left) && integer?(right)
        raise Unsupported.new(
          "`#{node.operator}` joins two integers#{
            [:&, :|, :^].include?(node.operator) ? ' or two booleans' : ''
          }, as in Ruby, and got #{left} and #{right}",
          node.location)
      end

      # `true` and `false` compare with each other and with nothing else.
      #
      # `flags[i] == 1` is the one worth a message of its own: Ruby answers it
      # rather than raising, and the answer is always false, so compiling it
      # would be compiling a bug into C.  It is an easy one to write -- the
      # reference implementation this project started from had it, and its
      # results were all NaN because of it.
      def verify_comparable (node)
        left, right = node.left.type, node.right.type
        if (complex?(left) || complex?(right)) &&
           ![:==, :!=].include?(node.operator)
          raise Unsupported.new(
            "`#{node.operator}` does not order Complex numbers, in Ruby " \
            "either; compare `.abs` or `.real`", node.location)
        end
        return unless boolean?(left) || boolean?(right)
        if boolean?(left) && boolean?(right)
          return if [:==, :!=].include?(node.operator)
          raise Unsupported.new(
            "`true` and `false` do not compare with `#{node.operator}`, in " \
            "Ruby either", node.location)
        end
        if [:==, :!=].include?(node.operator)
          raise Unsupported.new(
            "a boolean cell compares with `true` and `false`, not with a " \
            "number: in Ruby `flags[i] == 1` is false whatever the cell " \
            "holds. Write `if flags[i]` or `flags[i] == true`",
            node.location)
        end
        raise Unsupported.new(
          "a boolean cell does not compare with a number, in Ruby either",
          node.location)
      end

      # A boolean array holds true and false, and a numeric one holds numbers.
      # Ruby says the same: `flags[i] = 1.0` raises, and `values[i] = true`
      # raises too.  The one crossing Ruby does allow is `flags[i] = 1`, which
      # CArray takes for true -- and only 0 and 1, which is why it has to be a
      # literal here.
      def verify_storable (node)
        wanted = @element_types.fetch(node.array, nil)
        given = node.expression.type
        return if boolean?(wanted) && boolean?(given)
        # A Complex does not fit in a real cell, and Ruby says so: assigning
        # one into a float64 CArray raises rather than dropping the imaginary
        # part.  The other direction is fine -- a real number is a Complex
        # whose imaginary part is zero.
        if complex?(given) && real?(wanted)
          raise Unsupported.new(
            "`#{node.array}` holds real numbers, and the value stored into " \
            "it is a Complex; storing one into a real CArray raises in Ruby " \
            "too. Store `.real`, `.imag` or `.abs`",
            node.location)
        end
        return if !boolean?(wanted) && numeric?(given)
        if boolean?(wanted) && node.expression.is_a?(IntegerLiteral) &&
           [0, 1].include?(node.expression.value)
          return
        end
        if boolean?(wanted)
          raise Unsupported.new(
            "`#{node.array}` is a boolean array, so it holds `true` and " \
            "`false`; storing #{given} into it is what Ruby refuses too",
            node.location)
        end
        raise Unsupported.new(
          "the value stored into `#{node.array}` is " \
          "#{given || 'undetermined'}, not a number",
          node.location)
      end

      # The nodes that arrive without a data type of their own: a literal and
      # a captured Ruby Numeric.  A CScalar is not one of them -- it is a
      # one-cell array, so it has a dtype and says what it is.
      WEAK_NODES = [IntegerLiteral, FloatLiteral, ImaginaryLiteral,
                    CaptureRead].freeze

      # Integer < Float < Complex, which is the order a Ruby Numeric's class
      # sits in and the only thing about a bare one that is settled.
      KIND_RANK = { :integer => 0, :real => 1, :complex => 2 }.freeze

      def weak? (node)
        WEAK_NODES.any? { |kind| node.is_a?(kind) }
      end

      # Two operands meeting, where one of them may be a bare Numeric.
      #
      # CArray has two rules here and they are not the same rule.  Array
      # against array is `CArray.result_type`, which is what #join spells out
      # as an order.  A bare Numeric against an array is absorption: the
      # scalar takes the array's dtype rather than the array widening to meet
      # it, so `f32 * 2.0` is float32 where the order alone would say double.
      #
      # What the array gives the scalar is a width, never a kind, so the two
      # have to be the same kind for anything to be given.  `i32 * 2.0` is a
      # float64 and `f32 * 1i` a cmplx128 -- the scalar\'s own Ruby type, since
      # the array has no narrower one of that kind to offer.  And a real
      # scalar against a complex array stays real, which is not a width
      # question at all: Ruby\'s `z + x` adds to the real part and leaves the
      # imaginary one alone, sign included, and that is a different operation
      # from adding a complex number that happens to have a zero in it.
      def join_operands (left, right)
        return join(left.type, right.type) if weak?(left) == weak?(right)
        scalar, typed = weak?(left) ? [left, right] : [right, left]
        scalar_kind, typed_kind = KINDS[scalar.type], KINDS[typed.type]
        unless KIND_RANK.key?(scalar_kind) && KIND_RANK.key?(typed_kind)
          return join(left.type, right.type)
        end
        # The wider kind wins, as it does between two arrays.  What absorption
        # settles is the tie: at the same kind the scalar takes the other
        # side's width rather than the other side widening to Ruby's.
        return scalar.type if KIND_RANK[scalar_kind] > KIND_RANK[typed_kind]
        if scalar_kind == typed_kind
          # The scalar becomes that type rather than being widened to meet it,
          # and says so: a literal emitted as a double would take the C
          # expression back to double however this node is typed.
          scalar.type = typed.type
        end
        typed.type
      end

      def join (left, right)
        return right if left.nil?
        return left if right.nil?
        return left if left == right
        if numeric?(left) && numeric?(right)
          return NUMERIC_TYPES[
            [NUMERIC_TYPES.index(left), NUMERIC_TYPES.index(right)].max]
        end
        # `true` is not a number in Ruby either: `flags[i] + 1` raises, even
        # though the array-level `flags + 1` promotes.  A kernel is the cell
        # loop, so the cell's answer is the one it has to give.
        raise Unsupported, "cannot combine types #{left} and #{right}"
      end

      def verify (node)
        case node
        when Print
          node.arguments.each { |argument| verify(argument) }
        when CallStatement
          node.call.arguments.each { |argument| verify(argument) }
        when Raise
          # Nothing to check: no value is computed.
        when MaskWrite
          # Nothing to check: no value is computed.
        when MaskTest
          # Nothing to check: it reads a mask byte.
        when NumericPredicate
          verify(node.operand)
          unless numeric?(node.operand.type)
            raise Unsupported.new("`#{node.name}` asks about a number",
                                  node.location)
          end
          # `nan?` is Float's alone: an Integer has no NaN to be and a
          # Complex has no such method, and both raise NoMethodError in Ruby
          # rather than answering false.  `finite?` is on all three.
          if node.name == :nan? && !floating?(node.operand.type)
            raise Unsupported.new(
              "`nan?` is a Float's question -- " \
              "#{complex?(node.operand.type) ? 'a Complex' : 'an Integer'} " \
              "has no method by that name and raises NoMethodError in Ruby",
              node.location)
          end
        when While
          verify(node.condition)
          unless boolean?(node.condition.type)
            raise Unsupported.new("a condition must be a comparison",
                                  node.condition.location)
          end
          node.statements.each { |statement| verify(statement) }
        when InnerLoop
          [node.from, node.to].each do |bound|
            verify(bound)
            unless integer?(bound.type)
              raise Unsupported.new("an inner loop's range must be integers",
                                    bound.location)
            end
          end
          node.statements.each { |statement| verify(statement) }
        when Branch
          unless boolean?(node.condition.type)
            raise Unsupported.new("a condition must be a comparison",
                                  node.condition.location)
          end
          node.children.each { |child| verify(child) }
        when ElementWrite
          verify(node.expression)
          verify_storable(node)
        when LocalRead
          unless node.type
            raise Unsupported.new("`#{node.name}` is read before it is assigned",
                                  node.location)
          end
        when Conditional
          unless boolean?(node.condition.type)
            raise Unsupported.new("a condition must be a comparison",
                                  node.condition.location)
          end
          node.children.each { |child| verify(child) }
        when LogicalOperation, LogicalNot
          node.children.each { |child| verify(child) }
          unless node.children.all? { |child| boolean?(child.type) }
            raise Unsupported.new(
              "`#{node.is_a?(LogicalNot) ? '!' : node.operator}` combines " \
              "comparisons, not numbers",
              node.location)
          end
        when AbsoluteValue
          verify(node.operand)
          unless numeric?(node.operand.type)
            raise Unsupported.new("`AbsoluteValue` needs a number",
                                  node.location)
          end
        when Conversion
          verify(node.operand)
          unless numeric?(node.operand.type)
            raise Unsupported.new("`Conversion` needs a number", node.location)
          end
          # `Complex(1,2).floor` and `.to_f` raise in Ruby -- a complex number
          # has no place on the line these round to.
          if complex?(node.operand.type)
            raise Unsupported.new(
              "`#{node.name || 'to_f'}` has no meaning for a Complex, and " \
              "raises in Ruby; take `.real` or `.abs` first", node.location)
          end
        when ComplexBuild
          node.children.each { |child| verify(child) }
          unless node.children.all? { |child| real?(child.type) }
            raise Unsupported.new(
              "the parts of a Complex are real numbers", node.location)
          end
        when ComplexPart
          verify(node.operand)
          unless numeric?(node.operand.type)
            raise Unsupported.new(
              "`#{node.ruby_name}` is asked of a number; this one is " \
              "#{article(node.operand.type)}", node.location)
          end
        when BinaryOperation
          node.children.each { |child| verify(child) }
          verify_comparable(node) if
            Analyzer::COMPARISON_OPERATORS.include?(node.operator)
          verify_bitwise(node) if
            Analyzer::BIT_OPERATORS.include?(node.operator)
          # `Complex(1,2) % 2` is a NoMethodError in Ruby: a floored
          # remainder needs an order, and the plane has none.
          if node.operator == :% && complex?(node.type)
            raise Unsupported.new(
              "`%` has no meaning for a Complex, and raises in Ruby",
              node.location)
          end
        when BitwiseNot
          verify(node.operand)
          unless integer?(node.operand.type)
            raise Unsupported.new("`~` needs an integer, as in Ruby",
                                  node.location)
          end
        when Power
          node.children.each { |child| verify(child) }
          unless numeric?(node.type)
            raise Unsupported.new("`**` operands must be numbers", node.location)
          end
          if integer?(node.type) &&
             !node.exponent.is_a?(IntegerLiteral)
            raise Unsupported.new(
              "an integer raised to a variable power overflows int64 where " \
              "Ruby would not; make one of them a Float",
              node.location)
          end
        when BinaryOperation
          node.children.each { |child| verify(child) }
          if Analyzer::COMPARISON_OPERATORS.include?(node.operator)
            unless numeric?(node.left.type) &&
                   numeric?(node.right.type)
              raise Unsupported.new("comparison operands must be numbers",
                                    node.location)
            end
          else
            unless numeric?(node.type)
              raise Unsupported.new("`#{node.operator}` operands must be numbers",
                                    node.location)
            end
          end
        else
          node.children.each { |child| verify(child) }
        end
      end

    end

  end
end
