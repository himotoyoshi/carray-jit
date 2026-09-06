require "prism"

class CArray
  module JIT

    # Turns the source of a kernel block into an untyped IR tree, rejecting
    # anything outside the recognized subset.
    #
    # The block's parameters are the loop indices and nothing else; arrays and
    # scalars alike are reached as variables the block closed over.  Which of
    # those names are arrays has to be settled before the tree can be built,
    # so the caller passes them in -- it knows, because it has the values.
    class Analyzer

      # Ruby Math methods that correspond 1:1 to a math.h function.
      #
      # Deliberately excludes anything whose C counterpart disagrees on
      # semantics.  `%` is the cautionary case: CArray floors it to agree with
      # Ruby, while C's fmod truncates, so `%` is NOT lowered to fmod.
      MATH_FUNCTIONS = {
        :sqrt  => "sqrt",
        :cbrt  => "cbrt",
        :exp   => "exp",
        :log   => "log",
        :log2  => "log2",
        :log10 => "log10",
        :sin   => "sin",
        :cos   => "cos",
        :tan   => "tan",
        :asin  => "asin",
        :acos  => "acos",
        :atan  => "atan",
        :atan2 => "atan2",
        :sinh  => "sinh",
        :cosh  => "cosh",
        :tanh  => "tanh",
        :hypot => "hypot",
        :asinh => "asinh",
        :acosh => "acosh",
        :atanh => "atanh",
      }.freeze

      # The C99 complex form of each math.h function that has one, by the
      # real name this IR carries.  Which functions appear here is not a
      # choice made here: it is the set CArray itself computes on a complex
      # array, so that a formula gives the same answer whether it is applied
      # to the array or compiled cell by cell.
      #
      # Absent, because a complex CArray raises CArray::DataTypeError for
      # them: log10 and log2 (C99 has no clog10 or clog2), cbrt (no ccbrt),
      # and the two-argument atan2 and hypot, which are about the plane a
      # complex number already lives in.
      COMPLEX_MATH_FUNCTIONS = {
        "sqrt"  => "csqrt",
        "exp"   => "cexp",
        "log"   => "clog",
        "sin"   => "csin",
        "cos"   => "ccos",
        "tan"   => "ctan",
        "asin"  => "casin",
        "acos"  => "cacos",
        "atan"  => "catan",
        "sinh"  => "csinh",
        "cosh"  => "ccosh",
        "tanh"  => "ctanh",
        "asinh" => "casinh",
        "acosh" => "cacosh",
        "atanh" => "catanh",
      }.freeze

      # The postfix spelling `x.sqrt`, which CArray::CoreExtensions puts on
      # Float and Integer so that one formula reads the same whether it is
      # applied to a scalar or to a whole array.  A per-cell kernel works on
      # scalars pulled out of arrays, so a formula already written that way
      # should not have to be rewritten to be compiled.
      #
      # Only the names that are 1:1 with math.h; the rest of the refinement
      # is refused by name below.
      POSTFIX_NAMES = %i[sqrt exp log log10 sin cos tan sinh cosh tanh
                         asin acos atan asinh acosh atanh].freeze

      # Names the same refinement provides that are NOT 1:1 with math.h.
      # `expm1` and `log1p` are the ones worth naming: C has functions by
      # those names, and they exist precisely because `exp(x) - 1` and
      # `log(1 + x)` lose precision for small x -- which is what the Ruby
      # side computes.  Lowering them to the C functions would silently
      # produce different numbers.
      REFUSED_POSTFIX = {
        :expm1   => "the refinement computes exp(x) - 1, which is not what " \
                    "C's expm1 computes",
        :log1p   => "the refinement computes log(1 + x), which is not what " \
                    "C's log1p computes",
        :rad     => "write the multiplication out",
        :deg     => "write the multiplication out",
        :square  => "write x * x",
        :rsqrt   => "write 1.0 / Math.sqrt(x)",
        :signbit => "write x < 0",
        :deg_360 => "no math.h counterpart",
        :deg_180 => "no math.h counterpart",
        :rad_2pi => "no math.h counterpart",
        :rad_pi  => "no math.h counterpart",
      }.freeze

      ARITHMETIC_OPERATORS = [:+, :-, :*, :/, :%].freeze
      # Ruby's bit operators on Integers, which C has too.  What they do at
      # the edges is C's answer rather than Ruby's -- a shift wraps and takes
      # its count modulo the width, because CArray's own `<<` compiles to the
      # same C shift (`ext/mkkernel.rb`, :bit_lshift) and this has to agree
      # with CArray.
      BIT_OPERATORS = [:&, :|, :^, :<<, :>>].freeze

      # Methods whose result type is a property of the method: Float#floor and
      # friends hand back an Integer in Ruby, and so must here.
      CONVERSIONS = {
        :floor    => [:int64,  "floor"],
        :ceil     => [:int64,  "ceil"],
        :round    => [:int64,  "round"],
        :truncate => [:int64,  "trunc"],
        :to_i     => [:int64,  "trunc"],
        :to_int   => [:int64,  "trunc"],
        :to_f     => [:double, nil],
      }.freeze

      # The parts of a complex number, by every spelling Ruby gives them.
      # `imaginary` and `imag` are one method in Ruby and one node here.
      COMPLEX_PARTS = {
        :real      => :real,
        :imaginary => :imaginary,
        :imag      => :imaginary,
        :conjugate => :conjugate,
        :conj      => :conjugate,
        :arg       => :arg,
        :angle     => :arg,
        :phase     => :arg,
      }.freeze

      # Constants under Math, emitted as literals so that the C sees exactly
      # the double Ruby would have used.
      MATH_CONSTANTS = { :PI => Math::PI, :E => Math::E }.freeze
      COMPARISON_OPERATORS = [:<, :<=, :>, :>=, :==, :!=].freeze

      attr_reader :parameter_names, :pointer_names, :address_arrays,
                  :address_parameters
      # An offset that is an integer here rather than when the kernel runs.
      # A literal is one; so is arithmetic over literals, which is the same
      # number written a way that says where it came from -- `w[-RADIUS-1]`
      # cannot be written, but `w[-2-1]` can, and a stencil drawn from a
      # formula is usually written the second way.
      #
      # Nothing that reads a value: a captured integer arrives with the call,
      # and one kernel serves every value of it, so a window built from one
      # would have a radius the compiled loop does not know.  The radius is
      # what lets the interior be walked without asking, cell by cell,
      # whether it is still inside.
      LITERAL_OPERATORS = { :+ => true, :- => true, :* => true }.freeze

      def literal_integer (node)
        node = unwrap(node)
        case node
        when Prism::IntegerNode
          node.value
        when Prism::CallNode
          return nil unless node.receiver
          value = literal_integer(node.receiver)
          return nil unless value
          arguments = node.arguments&.arguments || []
          if arguments.empty?
            return -value if node.name == :-@
            return value if node.name == :+@
            return nil
          end
          return nil unless arguments.size == 1 && LITERAL_OPERATORS[node.name]
          right = literal_integer(arguments.first)
          right && value.public_send(node.name, right)
        end
      end

      # How far the windows reach on each axis, as [lowest, highest] -- the
      # radius, kept per side because a window need not be symmetric.  It is
      # what the caller walks the interior by.
      attr_reader :window_reach
      # The names the block gave its windows, which are the arrays a border
      # rule applies to: the ones the block reaches away from the cell in.
      attr_reader :windows
      attr_reader :index_names, :array_names, :scalar_names, :c_function_names, :body,
                  :written_arrays, :array_ranks, :subscripts, :inner_ranges,
                  :contracted_names

      # A kernel that mentions UNDEF is a masked kernel whatever its arrays
      # happen to carry: it asks about masks, or makes them.
      def uses_undef?
        @uses_undef
      end

      # Collects the names a block reaches for without assigning them, so the
      # caller can look up their values and say which are arrays.
      # Whether the source names UNDEF anywhere, which decides that the kernel
      # is a masked one before anything else is known about it.
      def self.mentions_undef? (source, node: nil)
        analyzer = allocate
        block = node || analyzer.send(:parse_block, source)
        analyzer.send(:names_constants, block).include?(:UNDEF)
      end

      # The names the block reaches for, and the names it assigns.  The
      # second set is not a subset of the first -- a name the block assigns
      # is not free in it -- but in the whole-array spelling an assignment
      # may still land in an array outside, so the caller looks both up.
      def self.free_names (source, node: nil)
        allocate.send(:scan_free_names, source, node).first
      end

      def self.free_and_assigned_names (source, node: nil)
        allocate.send(:scan_free_names, source, node)
      end

      # `rank` is given only for a block that takes no parameters and writes
      # `out[] = a[] + b[]`.  There the rank is a property of the arrays
      # rather than of the block, so it arrives from the caller and the loop
      # indices are named here.
      # `steps` is the stride each outer index advances by, which decides
      # whether an offset is a dependency at all: with a step of two, reading
      # `a[i-1]` touches a cell this loop never writes.
      # `contract` puts the block in the contraction convention: every parameter
      # is an index, the ones that do not appear on the left are summed over, and
      # every extent comes from the arrays' own shapes.
      # `contract` is true for a contraction, or :probe to stop before the
      # rewrite -- which is how the returned form learns the summand's type
      # and the free indices' extents before it has an array to put them in.
      # `result` names the array a returned contraction writes into.
      # `function` puts the block in the third mode: its parameters are values
      # rather than loop indices, its body is an expression whose value is
      # returned, and it reaches no array.  It is the smallest of the three --
      # with no cell to address there is no extent, no direction and no mask,
      # so most of what follows never runs.
      def initialize (source, node: nil, array_names: [], c_functions: {}, rank: nil,
                      steps: nil, contract: false, result: nil, function: false,
                      pointers: {}, map: false, cell_names: [],
                      recursion: nil, windows: [], returns: true)
        @source = source
        @node = node
        @array_names = array_names
        # Arrays with one cell and no axis to walk -- a CScalar.  There is no
        # index to write for one, which is the whole of what distinguishes it
        # from the one-cell CArray it otherwise is, so it is spelled `s[]` or
        # named bare and the loop reads its cell at every iteration.
        @cell_names = cell_names
        # `jit_stencil`: the block's parameters are windows onto the arrays it
        # was given, rather than the loop's indices.  `a[-1, 1]` is then an
        # offset from the cell the loop is on -- the same reach `a[i-1, j+1]`
        # writes with the indices named, which is what it becomes here.  The
        # indices are this analyzer's, as they are for a block that names
        # none, because a window has nowhere to write one.
        @windows = windows
        @c_functions = c_functions
        @function = function
        # A function declared `void` ends in a statement like any other; one
        # that returns ends in the expression it returns.  Which it is comes
        # from the declaration, as everything else about a signature does.
        @returns = returns
        # `map` is jit_map rather than jit_each: the same block, read the
        # same way, except that its last statement is a value and every cell
        # of the result gets it.  An assignment may be that statement, since
        # in Ruby an assignment has the value it assigned.
        @map = map
        # In a function, a parameter declared `const double *` is reached the
        # way C reaches it.  The value says what may be done with it: true to
        # read and write, false to read only (= const), nil for one that
        # points at nothing in particular and so cannot be reached at all.
        @pointers = pointers
        # What the function being compiled is called, what it takes and what
        # it returns -- so its own body can call it.  C puts a declarator's
        # name in scope inside the body it heads, and this is that.  Nil for
        # a kernel, and for a function declared without a name, which has
        # nothing to call itself by.
        @recursion = recursion
        @whole_array = false
        # How far the windows reach on each axis, filled in as they are read.
        @window_reach = Array.new(rank.to_i) { [0, 0] }
        @uses_undef = false
        @calls_for_effect = false
        @outer_names = []
        @inner_names = []
        # How many loops the statement being built stands inside.  `break`
        # needs a loop to leave and does not care which kind: an inner loop
        # brings an index and a `while` brings none, but both are loops in C
        # and in the Ruby they stand for.
        @loop_depth = 0
        @inner_names_seen = []
        @array_ranks = {}
        @inner_ranges = {}
        @subscripts = Hash.new { |hash, key| hash[key] = [] }
        @given_rank = rank
        @steps = steps
        @contract = contract
        @result = result
        @contracted_names = []
        @free_names = []
        @index_names = []
        @local_names = []
        @assigned_names = []
        @scalar_names = []
        @c_function_names = []
        @parameter_names = []
        @pointer_names = []
        @address_arrays = []
        @address_parameters = {}
        @read_offsets = Hash.new { |hash, key| hash[key] = [] }
        @written_arrays = []
        analyze
      end

      def rank
        @index_names.size
      end

      # For one axis of one array: which indices walk it and how far the kernel
      # reaches along it with each, plus any fixed positions it is also read
      # at.  Returns [[[index, minimum, maximum], ...], constants].
      #
      # An axis may be walked by more than one index, which is how a covariance
      # is written -- `c[p,a] * c[p,b]` reads the same axis at two independent
      # positions.  A fixed subscript sits alongside them, so a kernel may read
      # `a[i, 0]` and `a[i, j]` on the same axis too.
      #
      # This holds for an array the kernel writes as well.  In `v[a,b] =
      # v[a,a]` the cell being read is one this loop also writes, at b == a,
      # so cells reached before that read the old value and cells reached
      # after it read the new one -- and the answer depends on the order.  It
      # is not an ambiguity, though: the extent states the order, so the
      # kernel runs the order it was given and means what the same Ruby loop
      # means.  What is lost is only the check, since there is no fixed offset
      # here to derive a direction from and compare the extent against.
      def axis_use (array, axis)
        uses = @subscripts[array].map { |per_axis| per_axis[axis] }.compact
        walked = uses.reject { |index, _| index.nil? }
        constants = uses.select { |index, _| index.nil? }.map(&:last)
                         .select { |node|
                           !node.is_a?(Node) || Analyzer.fixed_subscript?(node)
                         }
        names = walked.map(&:first).uniq
        walkers = names.map { |name|
          [name, walked.select { |index, _| index == name }.map(&:last)]
        }
        [walkers, constants]
      end

      # Per array: the axes it is read at an index only the running kernel
      # knows.  Those axes are bounds-checked as they are reached.
      def dynamic_axes (array)
        axes = []
        @subscripts[array].each do |per_axis|
          per_axis.each_with_index do |(index, offset), axis|
            next unless index.nil? && offset.is_a?(Node)
            axes << axis unless Analyzer.fixed_subscript?(offset)
          end
        end
        axes.uniq.sort
      end

      # A write is addressed the way a read is: every axis either walks with an
      # outer index, at whatever offset, or is pinned at a position known
      # before the first cell.
      #
      # Two iterations may land on the same cell -- `box[0]` puts every one of
      # them there -- and that is not an ambiguity: the extent states the
      # order, so what the array holds afterwards is what the same Ruby loop
      # would leave in it.  An inner loop already rests on exactly that, an
      # accumulator being one cell written once per pass.
      def walking_subscripts? (subscripts)
        subscripts.all? { |index, offset|
          if index
            @outer_names.include?(index)
          else
            !offset.is_a?(Node) || Analyzer.fixed_subscript?(offset)
          end
        }
      end

      # A write is a scatter when some axis of it is addressed by a value only
      # the running kernel knows.  The axes that are not may still be the
      # loop's own indices.
      def computed_subscripts? (subscripts)
        subscripts.any? { |index, offset|
          index.nil? && offset.is_a?(Node) && !Analyzer.fixed_subscript?(offset)
        } && subscripts.all? { |index, offset|
          (index && offset.zero?) ||
            (index.nil? && offset.is_a?(Node) && !Analyzer.fixed_subscript?(offset))
        }
      end

      def arrays_used
        (@subscripts.keys + @written_arrays).uniq
      end

      def inner_index? (name)
        @inner_names.include?(name)
      end

      private

      def scan_free_names (source, node)
        block = node || parse_block(source)
        parameters = block.parameters
        list = parameters && parameters.parameters
        indices = list ? list.requireds.map(&:name) : []
        assigned = collect_assigned_names(block.body)
        # An inner loop names an index too, and it is no more a captured
        # variable than the outer ones are.
        inner = collect_block_parameters(block.body)
        constants = names_constants(block.body).reject { |name| resolved_here?(name) }
        free = (collect_names(block.body) + constants).uniq -
               indices - assigned - inner
        [free, assigned.uniq - indices - inner]
      end

      # Names this analyzer answers for itself, so they are never captured:
      # UNDEF is a mark rather than a value, and `Math` is written out in C
      # (see build_math_call and build_constant_path).
      NAMES_RESOLVED_HERE = [:UNDEF, :Math].freeze

      # `Math::PI` and the rest are written out in C, so they are not among
      # the names captured either.
      def resolved_here? (name)
        NAMES_RESOLVED_HERE.include?(name) || name.to_s.start_with?("Math::")
      end

      # `raise "..."` says what it says: the class is not named and the
      # message is a literal, so nothing under it is a name the block reached
      # for.  Both scans stop here, or `raise ArgumentError, "x"` would be
      # refused for capturing a Class and never reach the reason it is
      # actually refused for.
      def raise_call? (node)
        node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :raise
      end

      def names_constants (node)
        return [] unless node
        return [] if raise_call?(node)
        # `Foo::TABLE` names one thing, and `Foo` on its own names none of
        # it, so a path is read whole and not descended into.
        return [node.slice.to_sym] if node.is_a?(Prism::ConstantPathNode)
        names = []
        names << node.name if node.is_a?(Prism::ConstantReadNode)
        node.compact_child_nodes.each { |child| names.concat(names_constants(child)) }
        names
      end

      def collect_block_parameters (node)
        return [] unless node
        names = []
        if node.is_a?(Prism::BlockParametersNode) && node.parameters
          names.concat(node.parameters.requireds.map(&:name))
        end
        node.compact_child_nodes.each do |child|
          names.concat(collect_block_parameters(child))
        end
        names
      end

      def collect_names (node)
        return [] unless node
        return [] if raise_call?(node)
        names = []
        case node
        when Prism::LocalVariableReadNode
          names << node.name
        when Prism::CallNode
          if node.receiver.nil? && node.arguments.nil? && node.block.nil?
            names << node.name
          end
        end
        node.compact_child_nodes.each { |child| names.concat(collect_names(child)) }
        names
      end

      def analyze
        block = @node || parse_block(@source)
        read_parameters(block)

        statements = block.body ? block.body.body : []
        if statements.empty?
          raise Unsupported.new("kernel body is empty")
        end
        @assigned_names = collect_assigned_names(block.body)

        # A contraction may end in a bare expression rather than an
        # assignment; that is the form that allocates its result and returns.
        # A function always ends in one -- that expression is what it returns.
        last = statements.last
        # A block that ends in an assignment still has that assignment's
        # value, which is what Ruby says it has -- so jit_map keeps the
        # statement and reads the cell back for the value.
        map_assignment = @map && last.is_a?(Prism::LocalVariableWriteNode)
        returns_value = (@function && @returns) || (@map && !map_assignment) ||
                        (@contract &&
                         !(last.is_a?(Prism::CallNode) && last.name == :[]=))
        built = statements[0..-2].map { |node| build_statement(node) }
        if map_assignment
          built << build_statement(last)
          @map_value = build_name_read(last.name, last.location)
        else
          built << (returns_value ? build(last) : build_statement(last))
          @map_value = built.last if @map
        end
        @body = KernelBody.new(built)

        return if @contract == :probe || @map == :probe
        return if @function

        map_body if @map
        contract_body if @contract
        verify_written_arrays_are_not_read_through_inner_indices

        # A kernel that only calls a C function still does something: what
        # it did is wherever the addresses it handed over pointed.  Only a
        # kernel that neither wrote nor called has put its work nowhere.
        if @written_arrays.empty? && !@calls_for_effect
          raise Unsupported.new(
            @whole_array ?
              "this block computes a value and puts it nowhere; assign it to " \
              "an array, as in `out = ...`, or ask for the value back with " \
              "`CArray.jit_map`" :
              "the kernel writes to no array; assign to one, as in " \
              "`out[i] = ...`")
        end
      end

      # An array the kernel writes is written once per outer cell; reading it
      # through an inner index would reach cells other outer iterations own,
      # and no evaluation order settles that.
      def verify_written_arrays_are_not_read_through_inner_indices
        @written_arrays.each do |array|
          @subscripts[array].each do |per_axis|
            per_axis.each do |index, _|
              next unless @inner_names_seen.include?(index)
              raise Unsupported.new(
                "`#{array}` is written by this kernel, so it cannot also be " \
                "read through the inner index `#{index}`")
            end
          end
        end
      end

      # Turns `c[i,j] = a[i,k] * b[k,j]` into the loops it stands for.
      #
      # Which indices are summed is not the assignment's business: an index
      # that appears twice in the term is summed, and that repetition is the
      # notation -- it is what stands in for the sigma.  An index appearing
      # once is free.  The left-hand side says where the result goes and in
      # what order its axes lie; it cannot make an index disappear.
      # The block's value is what every cell of the result gets, so the last
      # expression becomes a write into the result at the cell the loop is on.
      # jit_map writes its value into a result of its own, at the cell the
      # loop is on, and that array is what comes back.  Where the block ended
      # in an assignment the assignment stays, and the value is the cell it
      # just wrote -- which is the value Ruby gives that statement.
      def map_body
        statements = @body.statements
        statements = statements[0..-2] if statements.last.equal?(@map_value)
        subscripts = @outer_names.map { |name| [name, 0] }
        write = ElementWrite.new(@result, @map_value, @map_value.location,
                                 subscripts)
        @body = KernelBody.new(statements + [write])
        record_array_rank(@result, subscripts.size)
        record_subscripts(@result, subscripts)
        @written_arrays << @result unless @written_arrays.include?(@result)
      end

      def contract_body
        statements = @body.statements
        writes = statements.grep(ElementWrite)
        unless writes.size <= 1 && (writes.empty? || statements.last.equal?(writes.first))
          raise Unsupported.new(
            "a contraction is one expression, optionally assigned into an " \
            "array of your own")
        end

        write = writes.first
        unless write
          # The returned form: the free indices, in the order the block named
          # them, are the result's axes.
          _, summed = classify_indices(statements, statements.last)
          free = @index_names - summed
          # With every index summed the result is a single number, which lives
          # in a one-cell array at a fixed subscript.
          subscripts = free.empty? ? [[nil, 0]] : free.map { |name| [name, 0] }
          write = ElementWrite.new(@result, statements.last, statements.last.location,
                                   subscripts)
          statements = statements[0..-2] + [write]
          @body = KernelBody.new(statements)
          record_array_rank(@result, subscripts.size)
          record_subscripts(@result, subscripts)
          @written_arrays << @result
        end

        written = write.subscripts.reject { |index, _| index.nil? }.map(&:first)
        if written.uniq.size != written.size
          raise Unsupported.new(
            "the left-hand side names #{written.join(', ')}; an index can walk " \
            "one of its axes only")
        end
        unless write.subscripts.all? { |index, offset| index.nil? || offset.zero? }
          raise Unsupported.new(
            "a contraction writes the cell it is on, with no offset")
        end
        if @subscripts[write.array].size > 1
          raise Unsupported.new(
            "`#{write.array}` is both written and read here, which is a " \
            "recurrence rather than a contraction; write it with jit_for")
        end

        free, summed = classify_indices(statements, write)
        unless written.sort == free.sort
          raise Unsupported.new(describe_index_mismatch(written, free, summed))
        end

        @free_names = free
        @contracted_names = summed
        @outer_names = written
        @index_names = written

        accumulator = free_local_name
        summand = statements[0..-2] + [Assignment.new(accumulator,
                                                      BinaryOperation.new(:+,
                                                        LocalRead.new(accumulator),
                                                        write.expression))]
        inner = @contracted_names.each_with_index.reverse_each.inject(summand) {
          |body, (name, position)|
          slot = @outer_names.size + position
          from = BoundsValue.new(3 * slot)
          to = BoundsValue.new(3 * slot + 1)
          @inner_ranges[name] = [from, to]
          [InnerLoop.new(name, from, to, body)]
        }

        @body = KernelBody.new(
          [Assignment.new(accumulator, zero_for(write))] + inner +
          [ElementWrite.new(write.array, LocalRead.new(accumulator), write.location,
                            write.subscripts)])
      end

      # Counts where each index sits on a tensor, on the right-hand side only.
      # Once is free, twice is summed, and more than twice is not the
      # convention -- it says nothing about which pair to sum.
      def classify_indices (statements, write)
        counts = Hash.new(0)
        subscripts_of(statements, write).each { |index, _| counts[index] += 1 }

        missing = @index_names - counts.keys
        unless missing.empty?
          raise Unsupported.new(
            "#{missing.map { |name| "`#{name}`" }.join(', ')} " \
            "#{missing.size == 1 ? 'names no axis' : 'name no axis'} here")
        end
        crowded = counts.select { |_, count| count > 2 }.keys
        unless crowded.empty?
          raise Unsupported.new(
            "#{crowded.map { |name| "`#{name}`" }.join(', ')} appears more " \
            "than twice; a contraction sums a pair, and there is no pair to " \
            "choose")
        end

        [@index_names.select { |name| counts[name] == 1 },
         @index_names.select { |name| counts[name] == 2 }]
      end

      # Every subscript on the right-hand side: the summand, and whatever the
      # locals before it read.
      def subscripts_of (statements, write)
        summand = write.is_a?(ElementWrite) ? write.expression : write
        collected = []
        walk = lambda do |node|
          return unless node.is_a?(Node)
          collected.concat(node.subscripts) if node.is_a?(ElementRead)
          collected.concat(node.subscripts) if node.is_a?(MaskTest)
          node.children.each { |child| walk.call(child) }
        end
        statements[0..-2].each { |statement| walk.call(statement) }
        walk.call(summand)
        collected.reject { |index, _| index.nil? }
      end

      def describe_index_mismatch (written, free, summed)
        summed_on_left = written & summed
        unless summed_on_left.empty?
          return "#{summed_on_left.map { |name| "`#{name}`" }.join(', ')} " \
                 "#{summed_on_left.size == 1 ? 'appears' : 'appear'} twice on " \
                 "the right, so #{summed_on_left.size == 1 ? 'it is' : 'they are'} " \
                 "summed over and cannot also be free"
        end
        dropped = free - written
        "#{dropped.map { |name| "`#{name}`" }.join(', ')} " \
        "#{dropped.size == 1 ? 'appears' : 'appear'} once, so " \
        "#{dropped.size == 1 ? 'it is' : 'they are'} free and must be on the " \
        "left. A contraction sums the indices that appear twice; to sum one " \
        "that does not, write the loop with jit_for, or use sum(axis:)"
      end

      # The sum starts from zero of whatever the summand is; which zero that
      # is falls out of the type assignment.
      def zero_for (write)
        ZeroLike.new(write.expression, write.location)
      end

      public

      # For the returned form, before the rewrite: which indices stay free, so
      # the caller can size the result.
      def probe_free_names
        _, summed = classify_indices(@body.statements, @body.statements.last)
        @index_names - summed
      end

      private

      def free_local_name
        name = :contraction
        name = :"#{name}_" while @local_names.include?(name)
        name
      end

      def parse_block (source)
        result = Prism.parse(source)
        unless result.success?
          message = result.errors.map { |error| error.message }.join("; ")
          raise Unsupported.new("kernel source does not parse: #{message}")
        end
        extract_block(result.value)
      end

      def collect_assigned_names (node)
        return [] unless node
        names = []
        names << node.name if node.is_a?(Prism::LocalVariableWriteNode)
        node.compact_child_nodes.each do |child|
          names.concat(collect_assigned_names(child))
        end
        names.uniq
      end

      # Accepts `->(i) { ... }`, `proc { |i| ... }` and `lambda { |i| ... }`.
      def extract_block (program)
        statements = program.statements.body
        unless statements.size == 1
          raise Unsupported.new("kernel source must be a single block literal, " \
                                "got #{statements.size} statements")
        end
        node = statements.first

        case node
        when Prism::LambdaNode
          node
        when Prism::CallNode
          unless [:proc, :lambda].include?(node.name) && node.block
            raise Unsupported.new("expected a block literal", node.location)
          end
          node.block
        else
          raise Unsupported.new("expected a block literal such as `{ |i| ... }`, " \
                                "got #{node_name(node)}", node.location)
        end
      end

      def read_parameters (block)
        parameters = block.parameters
        list = parameters && parameters.parameters
        requireds = list ? list.requireds : []
        if list && (list.optionals.any? || list.rest || list.keywords.any? || list.block)
          raise Unsupported.new("the kernel block takes only required parameters")
        end

        if @function
          @parameter_names = requireds.map(&:name)
          @index_names = []
          @outer_names = []
          return
        end

        if @windows.any?
          # The parameters were read before this analyzer was built -- the
          # caller had to, to know which array each window is onto -- so what
          # is left here is to check that the block agrees with what it was
          # given, and to name the indices it does not name.
          unless requireds.map(&:name) == @windows
            raise Unsupported.new(
              "the block's parameters are the windows onto the arrays it was " \
              "given, in that order")
          end
          @index_names = Array.new(@given_rank) { |axis| :"index#{axis}" }
        elsif requireds.empty?
          unless @given_rank
            raise Unsupported.new("the kernel block takes the loop indices as " \
                                  "its parameters, and was given none")
          end
          @whole_array = true
          @index_names = Array.new(@given_rank) { |axis| :"index#{axis}" }
        else
          @index_names = requireds.map(&:name)
        end
        @outer_names = @index_names.dup
      end

      # `printf` writes to the terminal from inside the loop, which is what
      # it is for: the kernel is otherwise silent until it finishes.  The
      # format has to be a literal, since C reads it at compile time.
      def build_print (node)
        arguments = node.arguments ? node.arguments.arguments : []
        template = arguments.first
        unless template.is_a?(Prism::StringNode)
          raise Unsupported.new(
            "printf's format has to be written out, as in " \
            "`printf(\"x = %g\\n\", x)`",
            node.location)
        end
        Print.new(template.unescaped,
                  arguments.drop(1).map { |argument| build(argument) },
                  node.location)
      end

      # `raise "the message"`, and nothing else in that shape: the class is
      # not named -- what comes back is the RuntimeError `raise "..."` gives
      # in Ruby -- and the message is a literal, because it is registered when
      # the body is compiled and only its code travels out of a cell.
      #
      # A compiled function may raise as a kernel may.  It reports into the
      # flag it already reports a division by zero into -- its own when it
      # stands alone, the caller's when it is pasted into a kernel -- and the
      # message behind the code travels with the function, so whichever way
      # the body is reached, the same line raises the same thing.
      def build_raise (node)
        arguments = node.arguments ? node.arguments.arguments : []
        if arguments.size != 1
          raise Unsupported.new(
            arguments.empty? ?
              "`raise` in a kernel takes the message, as in `raise \"x is 0\"`" :
              "`raise` in a kernel takes the message alone; the class is not " \
              "named, and what comes back is a RuntimeError",
            node.location)
        end
        message = arguments.first
        unless message.is_a?(Prism::StringNode)
          raise Unsupported.new(
            "a kernel's `raise` message is written out rather than built: it " \
            "is registered when the kernel is compiled, and the cell reports " \
            "which one it was",
            node.location)
        end
        Raise.new(message.unescaped, node.location)
      end

      def build_statement (node)
        case node
        when Prism::LocalVariableWriteNode
          # `out = UNDEF` marks the cell missing, the same as `out[i] = UNDEF`
          # does where the indices are written out.  It is read before the
          # right-hand side is built, since UNDEF is a mark and not a value.
          if @whole_array && @array_names.include?(node.name) &&
             undef_constant?(node.value)
            record_array_rank(node.name, rank, node.location)
            record_subscripts(node.name,
                              Array.new(rank) { |axis| [@outer_names[axis], 0] })
            @written_arrays << node.name unless @written_arrays.include?(node.name)
            @uses_undef = true
            return MaskWrite.new(node.name, node.location)
          end
          expression = build(node.value)
          # In the whole-array spelling every name in the block is a cell, so
          # an assignment to a name that is an array outside writes that
          # array's cell -- the one the loop is on, the same cell every read
          # in the block is at.  A name that is not an array is a local, as
          # it is anywhere else.
          if @whole_array && @array_names.include?(node.name)
            return whole_array_write(node.name, expression, node.location)
          end
          @local_names << node.name unless @local_names.include?(node.name)
          Assignment.new(node.name, expression, node.location)
        when Prism::CallNode
          if node.receiver.nil? && node.name == :printf
            return build_print(node)
          end
          return build_raise(node) if node.receiver.nil? && node.name == :raise
          # A call to a C function may stand alone.  Its value is dropped, as
          # Ruby drops it, and what it did is wherever its pointer parameters
          # pointed -- which is the whole reason C has statements that are
          # calls.  Everything else keeps the refusal below: a computation
          # standing where a statement stands is a line that does nothing.
          if (call = recursive_call(node) || c_function_call(node))
            @calls_for_effect = true
            return CallStatement.new(call, node.location)
          end
          build_element_write(node)
        when Prism::IfNode
          build_branch(node)
        when Prism::WhileNode
          build_while(node)
        when Prism::NextNode
          build_loop_jump(node, LoopSkip, "next")
        when Prism::BreakNode
          build_loop_jump(node, LoopStop, "break")
        else
          raise Unsupported.new(
            "a kernel body holds assignments, `if`, `while`, `(a...b).each` " \
            "and `n.times` only, got #{node_name(node)}",
            node.location)
        end
      end

      # `next` skips the rest of this iteration, `break` leaves the loop.  Both
      # mean in the generated loop what they mean in the Ruby loop it replaces
      # -- with one exception: Ruby's `break` in the kernel block is not a
      # loop exit at all but a return from `jit_for` with a value, and the
      # value is one this cannot produce.  So `break` belongs to an inner
      # loop, which is a loop in both languages.
      def build_loop_jump (node, kind, word)
        if node.arguments
          raise Unsupported.new(
            "`#{word}` here takes no value: the loop's own value is never " \
            "used, so a value would be dropped",
            node.location)
        end
        if kind == LoopStop && @loop_depth.zero?
          raise Unsupported.new(
            "`break` in the kernel block returns from `jit_for` in Ruby, " \
            "with a value this cannot produce; it works inside a loop -- an " \
            "`(a...b).each`, an `n.times` or a `while` -- and `next` skips " \
            "the cell here",
            node.location)
        end
        kind.new(node.location)
      end

      # `while cond ... end`.  The loop whose end is not written down.
      #
      # It is the one construct here that can keep a kernel from returning,
      # and there is no honest way to stop it from that: a bound the compiler
      # invented would be a number nobody could choose -- the loops whose
      # bound is knowable are already the bounded loop's, spelled
      # `(0...cap).each` with a `break`.  So what is offered is C's own
      # bargain, the same one a `jit_function` that recurses too deep already
      # takes: the loop does what it is written to do, and a condition that
      # never goes false does not return.  Worth knowing before writing one:
      # the C loop has no interrupt check in it, so `Ctrl-C` does not reach a
      # kernel that is running -- whether or not it holds the GVL -- and a
      # runaway pass ends with a signal from another terminal.
      #
      # `begin ... end while` is refused rather than compiled as a do-while.
      # Ruby's is the one loop in the language that tests after the body, and
      # a reader who missed the `begin` would read the body's first pass as
      # conditional when it is not.  `while` with the test written first says
      # the same thing where it can be seen.
      def build_while (node)
        if node.begin_modifier?
          raise Unsupported.new(
            "`begin ... end while` runs its body before the condition is " \
            "ever read, which is not what `while` says anywhere else in " \
            "Ruby; write the test at the top",
            node.location)
        end
        condition = build(node.predicate)
        @loop_depth += 1
        statements = statements_of(node.statements).map { |inner|
          build_statement(inner)
        }
        @loop_depth -= 1
        # Whether a loop returns is not a question that can be answered in
        # general, and nothing here pretends to answer it.  This is the one
        # case where it does not have to be: a condition written `true` is
        # never going to be false, so the only way out is a `break` or a
        # `raise`, and a body with neither cannot end.  That is not a guess
        # about the data -- it is the loop read as written -- so refusing it
        # costs no legitimate program.  `while true` with a `break` in it is
        # a normal thing to write, and is left alone.
        if literal_true?(node.predicate) && !can_leave?(statements)
          raise Unsupported.new(
            "this `while true` holds no `break` and no `raise`, so it cannot " \
            "end; a kernel that does not return cannot be interrupted either, " \
            "since `Ctrl-C` does not reach a running kernel",
            node.location)
        end
        While.new(condition, statements, node.location)
      end

      def literal_true? (node)
        unwrap(node).is_a?(Prism::TrueNode)
      end

      # Whether any statement of this loop's own body could leave it.  A
      # `break` in a loop nested inside leaves that one, not this one, so the
      # walk goes into branches and stops at loops.
      def can_leave? (statements)
        statements.any? do |statement|
          case statement
          when LoopStop, Raise then true
          when Branch
            can_leave?(statement.consequent) || can_leave?(statement.alternative)
          else false
          end
        end
      end

      # `if` in statement position, where the branches write cells rather than
      # produce a value.  Unlike the expression form, this one does not need an
      # `else`: a cell the kernel does not write keeps what it had.
      # `(from...to).each { |j| ... }` -- the loop a reduction runs in -- and
      # `n.times { |j| ... }`, which is that loop with both ends implied.
      #
      # `each` rather than `for` because its scoping is the one being
      # compiled: `for` would assign an enclosing variable of the same name
      # and leave the index bound afterwards, neither of which the generated
      # loop does.  `times` has the scoping of `each` and needs no exception.
      def build_inner_loop (node)
        counted = node.name == :times
        range = unwrap(node.receiver)
        if !counted && !range.is_a?(Prism::RangeNode)
          raise Unsupported.new(
            "an inner loop runs over a range, as in `(0...n).each { |j| ... }`",
            node.location)
        end
        unless node.block && node.block.parameters
          raise Unsupported.new("an inner loop names its index", node.location)
        end
        requireds = node.block.parameters.parameters&.requireds || []
        unless requireds.size == 1
          raise Unsupported.new("an inner loop names one index", node.location)
        end
        index = requireds.first.name
        if index_in_scope?(index)
          raise Unsupported.new("`#{index}` is already an index here", node.location)
        end
        unless counted || (range.left && range.right)
          raise Unsupported.new("an inner loop needs both ends of its range",
                                node.location)
        end

        # `n.times` is `(0...n).each`: the count is the exclusive end, and it
        # is built from the same vocabulary a range end is, so a literal and a
        # captured integer both serve.
        if counted
          from = IntegerLiteral.new(0, node.location)
          to = build(node.receiver)
        else
          from = build(range.left)
          to = build(range.right)
          to = BinaryOperation.new(:+, to, IntegerLiteral.new(1, node.location),
                                   node.location) unless range.exclude_end?
        end

        @inner_names << index
        @inner_names_seen << index
        @inner_ranges[index] = [from, to]
        @loop_depth += 1
        statements = statements_of(node.block.body).map { |inner|
          build_statement(inner)
        }
        @loop_depth -= 1
        @inner_names.pop
        InnerLoop.new(index, from, to, statements, node.location)
      end

      def unwrap (node)
        return node unless node.is_a?(Prism::ParenthesesNode)
        body = node.body ? node.body.body : []
        body.size == 1 ? unwrap(body.first) : node
      end

      def build_branch (node)
        alternative =
          case node.subsequent
          when nil then []
          when Prism::ElseNode
            statements_of(node.subsequent.statements).map { |inner|
              build_statement(inner)
            }
          when Prism::IfNode then [build_branch(node.subsequent)]
          else
            raise Unsupported.new("unsupported `if` continuation", node.location)
          end
        Branch.new(build(node.predicate),
                   statements_of(node.statements).map { |inner|
                     build_statement(inner)
                   },
                   alternative,
                   node.location)
      end

      def statements_of (node)
        node ? node.body : []
      end

      def build_element_write (node)
        return build_inner_loop(node) if node.name == :each || node.name == :times
        unless node.name == :[]=
          # An expression standing alone in this spelling is a computation
          # nobody can see: there is no index to have written it against, and
          # nothing took its value.
          if @whole_array && !@map
            raise Unsupported.new(
              "this computes a value and puts it nowhere; assign it to an " \
              "array, as in `out = ...`, or ask for the value back with " \
              "`CArray.jit_map`",
              node.location)
          end
          raise Unsupported.new(
            "a kernel body holds assignments, `if`, `while`, `(a...b).each` " \
            "and `n.times` only, got a call to `#{node.name}`",
            node.location)
        end
        if (pointer = pointer_subscript(node, write: true))
          name, index = pointer
          arguments = node.arguments.arguments
          return PointerWrite.new(name, index, build(arguments.last),
                                  node.location)
        end
        array = array_name(node.receiver, node.location)
        arguments = node.arguments ? node.arguments.arguments : []
        # `out[] = ...` was how a block that had to run as Ruby said "the
        # whole array", `[]=` being the only spelling Ruby has for it.  The
        # block is read rather than run, and every name in it is a cell, so
        # the assignment is Ruby's own: `out = ...`.
        if @whole_array && arguments.size == 1
          raise Unsupported.new(
            "`#{array}[] = ...` writes the cell the loop is on, which is what " \
            "`#{array} = ...` says; the block is read rather than run, so the " \
            "assignment is an ordinary one",
            node.location)
        end
        subscripts = read_subscripts(array, arguments[0..-2], node.location)
        # A kernel writes a cell its own indices reach -- or one it works out,
        # which is a scatter and is checked as it is reached rather than in
        # advance.  What it may not do is write through an index that is not
        # the loop's: an inner index addresses reads only.
        #
        # In a contraction the left-hand side names which indices are free and
        # which are summed over, so it is checked there instead.
        unless @contract || walking_subscripts?(subscripts) ||
               computed_subscripts?(subscripts)
          raise Unsupported.new(
            "a kernel writes through its own indices, so `#{array}[...]` on " \
            "the left of `=` is addressed by #{@outer_names.join(', ')}, by a " \
            "position fixed before the loop runs -- or by a value the kernel " \
            "works out, which is a scatter",
            node.location)
        end
        record_subscripts(array, subscripts)
        @written_arrays << array unless @written_arrays.include?(array)
        if undef_constant?(arguments.last)
          @uses_undef = true
          return MaskWrite.new(array, node.location)
        end
        ElementWrite.new(array, build(arguments.last), node.location, subscripts)
      end

      def build (node)
        case node
        when Prism::IntegerNode
          IntegerLiteral.new(node.value, node.location)
        when Prism::FloatNode
          FloatLiteral.new(node.value, node.location)
        when Prism::ImaginaryNode
          # `2i` is Complex(0, 2); its imaginary part is what the literal
          # spells, and may be an Integer or a Float.
          ImaginaryLiteral.new(node.value.imaginary, node.location)
        when Prism::TrueNode
          BooleanLiteral.new(true, node.location)
        when Prism::FalseNode
          BooleanLiteral.new(false, node.location)
        when Prism::ParenthesesNode
          inner = node.body ? node.body.body : []
          unless inner.size == 1
            raise Unsupported.new("parentheses must hold one expression", node.location)
          end
          build(inner.first)
        when Prism::LocalVariableReadNode
          build_name_read(node.name, node.location)
        when Prism::IfNode
          build_conditional(node)
        when Prism::AndNode
          LogicalOperation.new(:"&&", build(node.left), build(node.right),
                               node.location)
        when Prism::OrNode
          LogicalOperation.new(:"||", build(node.left), build(node.right),
                               node.location)
        when Prism::ConstantPathNode
          build_constant_path(node)
        when Prism::CallNode
          build_call(node)
        when Prism::ConstantReadNode
          if node.name == :UNDEF
            raise Unsupported.new(
              "UNDEF is not a number; write it as `a[i] == UNDEF` to test a " \
              "cell, or `a[i] = UNDEF` to mark one",
              node.location)
          end
          # A constant holds an array, a number or a function like any other
          # name -- and is the only name a method body can reach, since `def`
          # closes over nothing.
          build_name_read(node.name, node.location)
        else
          raise Unsupported.new("unsupported expression #{node_name(node)}",
                                node.location)
        end
      end

      # A name is an index, a local once assigned, an error if the block
      # assigns it only later, an array, or a captured scalar.  The same rule
      # serves both entry points: parsed on its own a captured name arrives as
      # a receiverless call, while in the file it was written in Prism
      # resolves it to the enclosing scope's local.
      def build_name_read (name, location)
        axis = @outer_names.index(name)
        return IndexVariable.new(name, axis, location) if axis
        return IndexVariable.new(name, nil, location) if @inner_names.include?(name)
        if @local_names.include?(name)
          return LocalRead.new(name, location)
        end
        if @cell_names.include?(name)
          return cell_read(name, location)
        end
        if @array_names.include?(name)
          # Every name in this spelling is a cell: the loop is the compiler's
          # and is not written in the block, so `a + b * c` reads three cells
          # and computes one.  What the same expression means in CArray is
          # what it adds up to over the whole array -- in one pass here,
          # instead of three with two arrays in between.
          # And a stencil reads a captured array the same way: the windows
          # are what reach, so a name that is not one is the cell the loop is
          # on -- `a[0, 0]` spelled the way a block with no indices spells it.
          if @whole_array || @windows.any?
            subscripts = Array.new(rank) { |axis| [@outer_names[axis], 0] }
            record_array_rank(name, rank, location)
            record_subscripts(name, subscripts)
            return ElementRead.new(name, subscripts, location)
          end
          raise Unsupported.new(
            "`#{name}` is an array; index it, as in `#{name}[#{@index_names.first}]`",
            location)
        end
        if @assigned_names.include?(name)
          raise Unsupported.new("`#{name}` is read before it is assigned", location)
        end
        @scalar_names << name unless @scalar_names.include?(name)
        CaptureRead.new(name, location)
      end

      def build_conditional (node)
        unless node.subsequent
          raise Unsupported.new("`if` without `else` has no value for every cell",
                                node.location)
        end
        unless node.subsequent.is_a?(Prism::ElseNode)
          raise Unsupported.new("`elsif` is not supported", node.location)
        end
        Conditional.new(build(node.predicate),
                        build_single(node.statements, node.location, "if"),
                        build_single(node.subsequent.statements, node.location, "else"),
                        node.location)
      end

      def build_single (statements, location, what)
        body = statements ? statements.body : []
        unless body.size == 1
          raise Unsupported.new("the `#{what}` branch must be a single expression",
                                location)
        end
        build(body.first)
      end

      # `f.call(x)`, `f.(x)` -- which Prism also spells `call` -- and `f[x]`,
      # after Proc.  All three are real Ruby that computes the same thing when
      # the block is run rather than compiled, which is the property the rest
      # of the kernel grammar keeps too.
      C_FUNCTION_CALL_NAMES = [:call, :[]].freeze

      def build_call (node)
        if node.receiver.nil? && node.arguments.nil? && node.block.nil?
          return build_name_read(node.name, node.location)
        end
        if (recursive = recursive_call(node))
          return recursive
        end
        if (c_function = c_function_call(node))
          return c_function
        end
        return build_complex(node) if node.receiver.nil? && node.name == :Complex
        if node.block
          raise Unsupported.new("block arguments are not supported", node.location)
        end
        return build_element_read(node) if node.name == :[]

        if node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Math
          return build_math_call(node)
        end

        arguments = node.arguments ? node.arguments.arguments : []

        if node.name == :-@ && arguments.empty?
          return UnaryMinus.new(build(node.receiver), node.location)
        end
        if node.name == :+@ && arguments.empty?
          return build(node.receiver)
        end
        if node.name == :! && arguments.empty?
          return LogicalNot.new(build(node.receiver), node.location)
        end
        if node.name == :abs && arguments.empty?
          return AbsoluteValue.new(build(node.receiver), node.location)
        end
        if arguments.empty? && (part = COMPLEX_PARTS[node.name])
          return ComplexPart.new(part, node.name, build(node.receiver),
                                 node.location)
        end
        if arguments.empty? && (conversion = CONVERSIONS[node.name])
          type, function = conversion
          return Conversion.new(function, build(node.receiver), type, node.location)
        end
        if node.name == :** && arguments.size == 1
          return build_power(node.receiver, arguments.first, node.location)
        end
        if arguments.empty?
          if (function = postfix_math(node.name))
            return MathCall.new(function, [build(node.receiver)], node.location)
          end
          if (reason = REFUSED_POSTFIX[node.name])
            raise Unsupported.new("`.#{node.name}` is not compiled: #{reason}",
                                  node.location)
          end
        end
        if [:==, :!=].include?(node.name) && arguments.size == 1
          # Either way round: `a[i] == UNDEF` and `UNDEF == a[i]` ask the same
          # question, and Ruby lets both be written.
          if undef_constant?(arguments.first)
            return build_mask_test(node.receiver, node.name == :!=, node.location)
          end
          if undef_constant?(node.receiver)
            return build_mask_test(arguments.first, node.name == :!=, node.location)
          end
        end
        if node.name == :~ && arguments.empty?
          return BitwiseNot.new(build(node.receiver), node.location)
        end
        if (ARITHMETIC_OPERATORS + COMPARISON_OPERATORS +
            BIT_OPERATORS).include?(node.name)
          unless arguments.size == 1
            raise Unsupported.new("`#{node.name}` takes one operand", node.location)
          end
          return BinaryOperation.new(node.name, build(node.receiver),
                                     build(arguments.first), node.location)
        end

        if raise_call?(node)
          raise Unsupported.new(
            "`raise` is a statement here, not a value: write it on its own, " \
            "as in `raise \"x is 0\" if x == 0`",
            node.location)
        end
        raise Unsupported.new("unsupported method `#{node.name}`", node.location)
      end

      def build_constant_path (node)
        # Math is answered here, whether or not the answer exists: a name it
        # does not have is not something to go looking for outside.
        if node.parent.is_a?(Prism::ConstantReadNode) && node.parent.name == :Math
          if MATH_CONSTANTS.key?(node.name)
            return FloatLiteral.new(MATH_CONSTANTS.fetch(node.name), node.location)
          end
          raise Unsupported.new("unsupported constant #{node.slice}", node.location)
        end
        # Any other path names one thing, the way a plain constant does.
        build_name_read(node.slice.to_sym, node.location)
      end

      def subscripted? (node)
        node.is_a?(Prism::CallNode) && node.name == :[]
      end

      def undef_constant? (node)
        node.is_a?(Prism::ConstantReadNode) && node.name == :UNDEF
      end

      # `a[i] == UNDEF` asks whether the cell is missing, which is a question
      # about the mask.  Only a cell can be asked.
      def build_mask_test (receiver, negated, location)
        # In an element kernel the name is already the cell -- the loop is
        # the compiler's and is not written in the block -- so `a == UNDEF`
        # asks about the same cell `a` reads.  `a[] == UNDEF` says it the
        # longer way and is read below, with the indexed spellings.
        if @whole_array && !subscripted?(receiver)
          name = captured_name(receiver)
          unless name && @array_names.include?(name)
            raise Unsupported.new(
              "only a cell can be compared with UNDEF, as in `a == UNDEF`",
              location)
          end
          subscripts = Array.new(rank) { |axis| [@outer_names[axis], 0] }
          record_array_rank(name, rank, location)
          record_subscripts(name, subscripts)
          @uses_undef = true
          return MaskTest.new(name, subscripts, negated, location)
        end
        unless subscripted?(receiver)
          raise Unsupported.new(
            "only a cell can be compared with UNDEF, as in `a[i] == UNDEF`",
            location)
        end
        array = array_name(receiver.receiver, location)
        array_for_test = array
        subscripts = read_subscripts(array_for_test,
                                     receiver.arguments ? receiver.arguments.arguments : [],
                                     location)
        # Recorded like any other read, because the cell still has to exist
        # and still has to have been settled before it is asked about.  What
        # it does not do is feed the value-mask propagation, which is decided
        # separately: a mask test never enters the value's mask.
        record_subscripts(array, subscripts)
        @uses_undef = true
        MaskTest.new(array, subscripts, negated, location)
      end

      # `[name, index]` when this subscripts a pointer parameter, nil when it
      # does not.  A pointer declared const is refused on the left rather than
      # silently written through: the declaration is a promise to the caller,
      # not decoration.
      def pointer_subscript (node, write: false)
        name = captured_name(node.receiver)
        return nil unless name && @pointers.key?(name)
        case @pointers.fetch(name)
        when nil
          raise Unsupported.new(
            "`#{name}` points at nothing in particular, so there is no cell " \
            "for `#{name}[...]` to reach; declare what it points at",
            node.location)
        when false
          if write
            raise Unsupported.new(
              "`#{name}` is declared const, so the function may read it but " \
              "not write through it", node.location)
          end
        end
        arguments = node.arguments ? node.arguments.arguments : []
        arguments = arguments[0..-2] if write
        unless arguments.size == 1
          raise Unsupported.new(
            "`#{name}` is a pointer, so it takes one index", node.location)
        end
        @pointer_names << name unless @pointer_names.include?(name)
        [name, build(arguments.first)]
      end

      # `fact(n - 1)` inside the body of `double fact(double)`, and
      # `fact.call(n - 1)` for whoever prefers the spelling a captured
      # function takes.  Returns nil when this is not that call.
      #
      # It is not a capture: nothing outside the function is reached, and the
      # compiled object still references no Ruby value.  The name is in the
      # declaration the caller wrote, which is where C would have put it too.
      def recursive_call (node)
        return nil unless @recursion
        name, parameters, result_type = @recursion
        # `fact.call(n - 1)`, the spelling every other C function takes.  A
        # bare `fact(n - 1)` would read better as C and is refused all the
        # same: it is not Ruby, and the block has to stay runnable, since
        # running it beside the compiled function is how the two are checked
        # against each other.
        if node.receiver.nil? && node.name == name && node.arguments
          raise Unsupported.new(
            "`#{name}` calls itself the way any C function is called here, " \
            "as `#{name}.call(...)` -- a bare `#{name}(...)` is not Ruby, and " \
            "the block has to stay runnable",
            node.location)
        end
        return nil unless C_FUNCTION_CALL_NAMES.include?(node.name) &&
                          captured_name(node.receiver) == name
        return nil if node.block
        arguments = node.arguments ? node.arguments.arguments : []
        unless arguments.size == parameters.size
          raise Unsupported.new(
            "`#{name}` takes #{parameters.size} " \
            "#{parameters.size == 1 ? 'argument' : 'arguments'}; " \
            "#{arguments.size} #{arguments.size == 1 ? 'was' : 'were'} given",
            node.location)
        end
        built = arguments.each_with_index.map { |argument, position|
          build_c_function_argument(argument, parameters[position], name)
        }
        RecursiveCall.new(name, built, parameters, result_type, node.location)
      end

      # Returns the node for a call on a captured C function, or nil when this
      # is not one.
      def c_function_call (node)
        return nil unless C_FUNCTION_CALL_NAMES.include?(node.name)
        name = captured_name(node.receiver)
        return nil unless name && @c_functions.key?(name)
        c_function = @c_functions.fetch(name)
        arguments = node.arguments ? node.arguments.arguments : []
        unless arguments.size == c_function.arity
          raise Unsupported.new(
            "`#{name}` is `#{c_function}`, so it takes #{c_function.arity} " \
            "#{c_function.arity == 1 ? 'argument' : 'arguments'}; " \
            "#{arguments.size} #{arguments.size == 1 ? 'was' : 'were'} given",
            node.location)
        end
        @c_function_names << name unless @c_function_names.include?(name)
        built = arguments.each_with_index.map { |argument, position|
          build_c_function_argument(argument, c_function.parameters[position], name)
        }
        CFunctionCall.new(name, built, node.location)
      end

      # A parameter that points at numbers takes an array, not a cell: the
      # kernel hands over the address and the function reaches the cells
      # itself.  Which it is comes from the declaration, so the same captured
      # name means a cell in one argument position and the whole array in
      # another -- `poly.call(x[i], coef)` says both.
      def build_c_function_argument (argument, parameter, c_function)
        # Inside a function, one of its own pointer parameters is already the
        # address the callee wants, and handing it on is what C does -- for a
        # `void *` slot as much as for a run of numbers, since neither is
        # read here.  It is emitted as the bare name, which is what the C
        # parameter is called.
        if parameter&.pointer
          name = captured_name(argument)
          if name && @pointers.key?(name)
            @pointer_names << name unless @pointer_names.include?(name)
            return ArrayAddress.new(name, argument.location)
          end
        end
        return build(argument) unless parameter&.indexable?
        name = captured_name(argument)
        unless name && @array_names.include?(name)
          raise Unsupported.new(
            "`#{c_function}` takes `#{parameter.text}` there, which is an array; " \
            "pass one by name",
            argument.location)
        end
        @address_arrays << name unless @address_arrays.include?(name)
        # What the declaration promised about it, kept so the caller can hold
        # the array to it: which type it points at, whether it may be written
        # through, and how long it said it was.
        (@address_parameters[name] ||= []) << parameter
        ArrayAddress.new(name, argument.location)
      end

      # A free name, however Prism spelled it: a block parsed on its own sees
      # a local it does not know as a method call with no receiver.
      def captured_name (receiver)
        case receiver
        when Prism::LocalVariableReadNode then receiver.name
        when Prism::ConstantReadNode then receiver.name
        when Prism::ConstantPathNode then receiver.slice.to_sym
        when Prism::CallNode
          receiver.name if receiver.receiver.nil? && receiver.arguments.nil? &&
                           receiver.block.nil?
        end
      end

      # `out = ...` in the whole-array spelling.  The cell is the loop's own,
      # which is what makes this an assignment rather than a subscript: there
      # is no other cell it could mean.
      def whole_array_write (name, expression, location)
        subscripts = Array.new(rank) { |axis| [@outer_names[axis], 0] }
        record_array_rank(name, rank, location)
        record_subscripts(name, subscripts)
        @written_arrays << name unless @written_arrays.include?(name)
        ElementWrite.new(name, expression, location, subscripts)
      end

      def build_element_read (node)
        if (pointer = pointer_subscript(node))
          return PointerRead.new(pointer.first, pointer.last, node.location)
        end
        array = array_name(node.receiver, node.location)
        arguments = node.arguments ? node.arguments.arguments : []
        subscripts = read_subscripts(array, arguments, node.location)
        record_subscripts(array, subscripts)
        ElementRead.new(array, subscripts, node.location)
      end

      def record_subscripts (array, subscripts)
        @subscripts[array] << subscripts unless @subscripts[array].include?(subscripts)
      end

      def array_name (receiver, location)
        name = captured_name(receiver)
        unless name && @array_names.include?(name)
          raise Unsupported.new("only a captured CArray may be indexed", location)
        end
        name
      end

      # One [index name, offset] per axis of the array.  Which index addresses
      # which axis is the caller's choice, so a reduction can run an inner
      # index down one axis while an outer one holds the others.
      def read_subscripts (array, arguments, location)
        return window_subscripts(array, arguments, location) if @windows.include?(array)
        # An array the block closed over rather than was given is read at the
        # cell the loop is on, which is what a bare name means everywhere a
        # loop is this compiler's.
        if @windows.any? && arguments.empty? && !@cell_names.include?(array)
          record_array_rank(array, rank, location)
          return Array.new(rank) { |axis| [@outer_names[axis], 0] }
        end
        if @whole_array
          unless arguments.empty?
            raise Unsupported.new(
              "this block takes no indices, so an array is spelled `a[]`",
              location)
          end
          return Array.new(rank) { |axis| [@outer_names[axis], 0] }
        end
        if arguments.empty?
          return cell_subscripts(array, location) if @cell_names.include?(array)
          raise Unsupported.new("`#{array}` needs an index for each of its axes",
                                location)
        end
        record_array_rank(array, arguments.size, location)
        arguments.map { |argument| read_subscript(argument, location) }
      end

      # `a[-1, 1]`: one offset per axis, written out.  Written out because the
      # offsets are what the radius is read from, and the radius is what lets
      # the interior be walked without asking, at every cell, whether it is
      # still inside.  A computed subscript is a different thing and has a
      # different spelling -- it is `jit_for`'s.
      def window_subscripts (array, arguments, location)
        if arguments.size != rank
          raise Unsupported.new(
            "`#{array}` is a window onto a rank-#{rank} array, so it takes " \
            "#{rank} #{rank == 1 ? 'offset' : 'offsets'}: `#{array}[0" \
            "#{', 0' * (rank - 1)}]` is the cell itself",
            location)
        end
        record_array_rank(array, arguments.size, location)
        arguments.each_with_index.map { |argument, axis|
          offset = literal_integer(argument)
          unless offset
            raise Unsupported.new(
              "a window's offsets are written out, as in `#{array}[-1, 1]`; " \
              "a subscript the kernel works out is `jit_for`'s",
              location)
          end
          @window_reach[axis] = [[@window_reach[axis][0], offset].min,
                                 [@window_reach[axis][1], offset].max]
          [@outer_names[axis], offset]
        }
      end

      def record_array_rank (array, count, location = nil)
        known = @array_ranks[array]
        if known && known != count
          raise Unsupported.new(
            "`#{array}` is indexed with #{known} " \
            "#{known == 1 ? 'index' : 'indices'} in one place and #{count} in " \
            "another",
            location)
        end
        @array_ranks[array] = count
      end

      # An index expression is `j`, `j + c` or `j - c`, where `j` is any index
      # in scope, so that the offset is a compile-time constant.
      def read_subscript (node, location)
        if node.is_a?(Prism::LocalVariableReadNode) && index_in_scope?(node.name)
          return [node.name, 0]
        end
        if node.is_a?(Prism::CallNode) && [:+, :-].include?(node.name) &&
           node.receiver.is_a?(Prism::LocalVariableReadNode) &&
           index_in_scope?(node.receiver.name)
          return walked_subscript(node)
        end
        # Anything else pins the axis at a position the loop does not walk:
        # `a[i, 0]`, or `a[row, k]` where `row` is an integer the block closed
        # over.  It is an argument to the kernel like any other scalar, so one
        # compiled kernel serves every value of it.
        [nil, pinned_subscript(node)]
      end

      def pinned_subscript (node)
        build(node)
      end

      # The one cell a CScalar has: position zero on its one axis, which is a
      # pinned subscript like any other and is checked like one.
      def cell_subscripts (array, location)
        record_array_rank(array, 1, location)
        [[nil, IntegerLiteral.new(0, location)]]
      end

      def cell_read (array, location)
        subscripts = cell_subscripts(array, location)
        record_subscripts(array, subscripts)
        ElementRead.new(array, subscripts, location)
      end

      # A subscript that does not walk with the loop is *fixed* when its value
      # can be worked out before the kernel runs -- a literal, a captured
      # integer, arithmetic over those.  Then it joins the checks that happen
      # in advance: it is part of the box a view has to transfer, and reaching
      # outside the array is a message rather than a read.
      #
      # Anything else is *dynamic*: `a[b[i]]`, or an index the body computed.
      # Its value is not knowable until the cell is reached, so the check
      # moves to the access itself.
      def self.fixed_subscript? (node)
        case node
        when IntegerLiteral, CaptureRead then true
        when UnaryMinus                  then fixed_subscript?(node.operand)
        when BinaryOperation
          [:+, :-, :*].include?(node.operator) &&
            fixed_subscript?(node.left) && fixed_subscript?(node.right)
        else false
        end
      end


      # `j + c` or `j - c`, where c is a literal or an integer built from
      # literals and captured integers -- `a[i - window]` for a window the
      # caller chooses.  A captured offset reaches the kernel as an argument,
      # so one compiled kernel serves every value of it, and the judgements
      # that need the value (which way the axis runs, and whether the offset
      # is a dependency at all under this extent's step) are made when the
      # kernel is called, where the value is known, alongside the bounds check.
      def walked_subscript (node)
        receiver = node.receiver
        arguments = node.arguments ? node.arguments.arguments : []
        unless arguments.size == 1
          raise Unsupported.new("an index offset takes one argument",
                                node.location)
        end
        argument = arguments.first
        if argument.is_a?(Prism::IntegerNode)
          constant = argument.value
          if constant < 0
            raise Unsupported.new("write the offset as `j - c` with c >= 0",
                                  node.location)
          end
          return [receiver.name, node.name == :+ ? constant : -constant]
        end
        offset = pinned_subscript(argument)
        [receiver.name, node.name == :+ ? offset : UnaryMinus.new(offset)]
      end

      def index_in_scope? (name)
        @outer_names.include?(name) || @inner_names.include?(name)
      end

      def available_indices
        (@outer_names + @inner_names).map { |name| "`#{name}`" }.join(", ")
      end

      # Index expressions are limited to `i`, `i + c` and `i - c` so that the
      # dependency offset is a compile-time constant.
      def read_offset (node, axis)
        expected = @index_names[axis]
        if node.is_a?(Prism::LocalVariableReadNode) && node.name == expected
          return 0
        end
        unless node.is_a?(Prism::CallNode) && [:+, :-].include?(node.name)
          raise Unsupported.new(
            "index #{axis} must be `#{expected}`, `#{expected} + c` or " \
            "`#{expected} - c`", node.location)
        end
        receiver = node.receiver
        unless receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name == expected
          raise Unsupported.new("index #{axis} must start from `#{expected}`",
                                node.location)
        end
        arguments = node.arguments ? node.arguments.arguments : []
        unless arguments.size == 1 && arguments.first.is_a?(Prism::IntegerNode)
          raise Unsupported.new("an index offset must be an integer literal",
                                node.location)
        end
        constant = arguments.first.value
        if constant < 0
          raise Unsupported.new("write the offset as `#{expected} - c` with c >= 0",
                                node.location)
        end
        node.name == :+ ? constant : -constant
      end

      # `Complex(x, y)`, whose arguments are the parts, and `Complex(x)`,
      # which is taken for `Complex(x, 0.0)`.
      #
      # In Ruby the shorter one is not quite the longer one: its imaginary
      # part is an exact Integer zero, and `f_add` returns the other operand
      # untouched rather than adding that zero to it, so
      # `Complex(1.0) + Complex(2.0, -0.0)` keeps the sign of a zero that
      # `Complex(1.0, 0.0) + Complex(2.0, -0.0)` loses.  Nothing else tells
      # them apart -- multiplication and division agree, infinities and all --
      # and carrying an exactly-zero imaginary part through the type lattice
      # to reproduce that one case is not worth what it would cost to read.
      def build_complex (node)
        arguments = node.arguments ? node.arguments.arguments : []
        unless (1..2).cover?(arguments.size)
          raise Unsupported.new(
            "`Complex` takes one part or two, and got #{arguments.size}",
            node.location)
        end
        imaginary = arguments.size == 2 ? build(arguments.last)
                                        : FloatLiteral.new(0.0, node.location)
        ComplexBuild.new(build(arguments.first), imaginary, node.location)
      end

      def postfix_math (name)
        return nil unless POSTFIX_NAMES.include?(name)
        MATH_FUNCTIONS[name]
      end

      # Ruby's Integer ** Integer is exact and unbounded, which int64 is not.
      # A non-negative literal exponent can still be squared out; anything
      # else has to be asked for in floating point.
      def build_power (receiver, exponent, location)
        base = build(receiver)
        power = build(exponent)
        if power.is_a?(IntegerLiteral) && power.value < 0
          raise Unsupported.new(
            "a negative exponent gives a Rational in Ruby; write `1.0 / x ** n`",
            location)
        end
        Power.new(base, power, location)
      end

      def build_math_call (node)
        function = MATH_FUNCTIONS[node.name]
        unless function
          raise Unsupported.new("Math.#{node.name} has no math.h counterpart",
                                node.location)
        end
        arguments = node.arguments ? node.arguments.arguments : []
        expected = [:atan2, :hypot].include?(node.name) ? 2 : 1
        unless arguments.size == expected
          raise Unsupported.new("Math.#{node.name} takes #{expected} argument(s)",
                                node.location)
        end
        MathCall.new(function, arguments.map { |argument| build(argument) },
                     node.location)
      end

      def node_name (node)
        node.class.name.split("::").last.sub(/Node\z/, "")
      end

    end

  end
end
