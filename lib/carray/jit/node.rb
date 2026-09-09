class CArray
  module JIT

    # Typed intermediate representation.
    #
    # Nodes are built untyped by Analyzer and annotated by TypeAssignment,
    # which is why #type is writable.  Types are one of :int64, :double,
    # :complex or :boolean -- computation types, deliberately distinct from
    # any array's storage type (see TypeAssignment).
    class Node

      attr_accessor :type
      attr_reader :location

      def initialize (location = nil)
        @location = location
        @type = nil
      end

      def children
        []
      end

    end

    class IntegerLiteral < Node
      attr_reader :value
      def initialize (value, location = nil)
        super(location)
        @value = value
      end
    end

    class FloatLiteral < Node
      attr_reader :value
      def initialize (value, location = nil)
        super(location)
        @value = value
      end
    end

    # An imaginary literal: `2i`, or the `1i` that turns a real formula
    # complex.  Ruby has no literal for a complex number with both parts, so
    # this is always purely imaginary and `1 + 2i` is an addition.
    class ImaginaryLiteral < Node
      attr_reader :value
      def initialize (value, location = nil)
        super(location)
        @value = value
      end
    end

    # One of the loop indices; `axis` is its position in the index list.
    class IndexVariable < Node
      attr_reader :name, :axis
      def initialize (name, axis, location = nil)
        super(location)
        @name = name
        @axis = axis
      end
    end

    class LocalRead < Node
      # The C variable this read resolves to.  A Ruby local may hold an
      # Integer at one point in the body and a Float at another; a C variable
      # cannot, so each type gets its own.
      attr_accessor :binding_name
      attr_reader :name
      def initialize (name, location = nil)
        super(location)
        @name = name
      end
    end

    # A scalar the block closed over; passed in as a kernel argument.
    class CaptureRead < Node
      attr_reader :name
      def initialize (name, location = nil)
        super(location)
        @name = name
      end
    end

    # array[i + 1, j], where each axis is addressed by some index in scope.
    # `subscripts` holds one [index name, offset] pair per axis of the array,
    # which need not be the kernel's own indices: an inner loop introduces
    # index names too, and that is what lets a reduction be written.
    class ElementRead < Node
      attr_reader :array, :subscripts
      def initialize (array, subscripts, location = nil)
        super(location)
        @array = array
        @subscripts = subscripts
      end
    end

    # array[i] == UNDEF, or its negation.
    #
    # This reads the mask, not the value, which is what makes it different
    # from every other read: a cell tested this way has not had its garbage
    # looked at, so it does not mask what it decides.  That distinction is
    # syntactic, which is what lets it be settled here at all.
    class MaskTest < Node
      attr_reader :array, :subscripts, :negated
      def initialize (array, subscripts, negated, location = nil)
        super(location)
        @array = array
        @subscripts = subscripts
        @negated = negated
      end
    end

    # `x.nan?` and `x.finite?`: a question about a number, answered true or
    # false whatever the number's width.  `infinite?` is not one of these --
    # Ruby answers it with nil or 1 or -1, which is not a boolean and has no
    # nil to be.
    class NumericPredicate < Node
      attr_reader :name, :operand
      def initialize (name, operand, location = nil)
        super(location)
        @name = name
        @operand = operand
      end
      def children
        [@operand]
      end
    end

    # Zero of whatever type another expression has.
    #
    # A sum has to start from a zero of the summand's type: start it from an
    # integer zero and the accumulator is an integer at its first assignment
    # and a float at its second, which is two variables rather than one, and
    # the sum would never accumulate.
    class ZeroLike < Node
      attr_reader :reference
      def initialize (reference, location = nil)
        super(location)
        @reference = reference
      end
      def children
        [@reference]
      end
    end

    # An extent the caller passed in, referred to by slot.  A contraction
    # derives its ranges from the arrays' own shapes, so they arrive with the
    # other extents rather than as expressions in the block.
    class BoundsValue < Node
      attr_reader :slot
      def initialize (slot, location = nil)
        super(location)
        @slot = slot
      end
    end

    # (from...to).each { |j| ... }, and n.times { |j| ... }
    #
    # The index it introduces is in scope only inside it, exactly as the block
    # scopes it in Ruby, and can address any axis of any array that is read.
    # Nothing is written through it: a kernel writes the cell its outer
    # indices are on, and the inner loop is what runs within that cell.
    class InnerLoop < Node
      # `step` is the stride the loop counts by, and `to` is exclusive of it:
      # a descending loop ends one below the last index it visits, as an
      # extent written with `step` does.
      attr_reader :index, :from, :to, :step, :statements
      def initialize (index, from, to, statements, location = nil, step = 1)
        super(location)
        @index = index
        @from = from
        @to = to
        @step = step
        @statements = statements
      end
      def children
        [@from, @to] + @statements
      end
    end

    # while cond ... end
    #
    # The loop the bounded one is not: it introduces no index, and how many
    # passes it takes is not written anywhere -- it is whatever the condition
    # says, pass by pass.  That is the whole of what it adds, and the whole of
    # what it costs: a kernel with one in it may fail to return, and nothing
    # here can tell whether it will.
    #
    # The condition is re-read at the top of every pass, as Ruby's is.  A
    # local it reads must already be a local before the loop -- the condition
    # is walked before the body, so a name the body would introduce is not in
    # scope yet, and says so rather than reading whatever C left there.
    class While < Node
      attr_reader :condition, :statements
      def initialize (condition, statements, location = nil)
        super(location)
        @condition = condition
        @statements = statements
      end
      def children
        [@condition] + @statements
      end
    end

    # `next` and `break` inside a loop.  Neither carries a value: the inner
    # loop's own value is never used, so `break x` would drop x silently.
    class LoopSkip < Node
      def children
        []
      end
    end

    class LoopStop < Node
      def children
        []
      end
    end

    # array[i] = UNDEF -- marks the cell missing and leaves its bytes alone.
    class MaskWrite < Node
      attr_reader :array
      def initialize (array, location = nil)
        super(location)
        @array = array
      end
    end

    # if/else in statement position, with writes inside the branches.
    class Branch < Node
      attr_reader :condition, :consequent, :alternative
      def initialize (condition, consequent, alternative, location = nil)
        super(location)
        @condition = condition
        @consequent = consequent
        @alternative = alternative
      end
      def children
        [@condition] + @consequent + @alternative
      end
    end

    class BinaryOperation < Node
      attr_reader :operator, :left, :right
      def initialize (operator, left, right, location = nil)
        super(location)
        @operator = operator
        @left = left
        @right = right
      end
      def children
        [@left, @right]
      end
    end

    # && and ||
    class LogicalOperation < Node
      attr_reader :operator, :left, :right
      def initialize (operator, left, right, location = nil)
        super(location)
        @operator = operator
        @left = left
        @right = right
      end
      def children
        [@left, @right]
      end
    end

    class LogicalNot < Node
      attr_reader :operand
      def initialize (operand, location = nil)
        super(location)
        @operand = operand
      end
      def children
        [@operand]
      end
    end

    # abs, which unlike the math.h functions keeps the type it was given.
    class AbsoluteValue < Node
      attr_reader :operand
      def initialize (operand, location = nil)
        super(location)
        @operand = operand
      end
      def children
        [@operand]
      end
    end

    # Complex(x, y) -- the way into the complex type from two real numbers,
    # and the only one that does not start from a complex array.
    class ComplexBuild < Node
      attr_reader :real, :imaginary
      def initialize (real, imaginary, location = nil)
        super(location)
        @real = real
        @imaginary = imaginary
      end
      def children
        [@real, @imaginary]
      end
    end

    # real / imag / conjugate / arg.  Three of the four take a Complex to a
    # Float, which makes them the way out of the complex type: a kernel that
    # writes into a real array has to pass through one of them.
    #
    # `ruby_name` is the spelling the block used, kept only so that a message
    # about it names the method that was actually written.
    class ComplexPart < Node
      attr_reader :name, :ruby_name, :operand
      def initialize (name, ruby_name, operand, location = nil)
        super(location)
        @name = name
        @ruby_name = ruby_name
        @operand = operand
      end
      def children
        [@operand]
      end
    end

    # floor / ceil / round / truncate / to_i / to_f, whose result type is a
    # property of the method rather than of the operand.
    class Conversion < Node
      attr_reader :name, :operand, :result_type
      def initialize (name, operand, result_type, location = nil)
        super(location)
        @name = name
        @operand = operand
        @result_type = result_type
      end
      def children
        [@operand]
      end
    end

    # A captured array handed to a C function whole, as an address.
    #
    # Not an ElementRead: nothing is read here.  A kernel addresses an array
    # cell by cell, through a base and a stride; a C function takes the
    # address itself, which does not vary with the cell the kernel is on.
    class ArrayAddress < Node
      attr_reader :array
      def initialize (array, location = nil)
        super(location)
        @array = array
      end
      def children
        []
      end
    end

    # `p[i]` where `p` is a pointer parameter of a compiled function.
    #
    # Not an ElementRead: an array's cell is reached through a base and a
    # stride the caller supplied, and a pointer parameter is reached the way C
    # reaches it -- contiguous, from the address it was handed.  The index is
    # an expression rather than a loop index with an offset, because there is
    # no loop.
    class PointerRead < Node
      attr_reader :name, :index
      def initialize (name, index, location = nil)
        super(location)
        @name = name
        @index = index
      end
      def children
        [@index]
      end
    end

    # `p[i] = value` through a pointer parameter that was not declared const.
    class PointerWrite < Node
      attr_reader :name, :index, :expression
      def initialize (name, index, expression, location = nil)
        super(location)
        @name = name
        @index = index
        @expression = expression
      end
      def children
        [@index, @expression]
      end
    end

    # A call to a C function the block closed over.  The name is the local
    # the block used, not the symbol: which library it came from is settled
    # before the kernel is built, and the kernel only knows the signature.
    class CFunctionCall < Node
      attr_reader :name, :arguments
      def initialize (name, arguments, location = nil)
        super(location)
        @name = name
        @arguments = arguments
      end
      def children
        @arguments
      end
    end

    # A call standing where a statement stands, its value dropped.
    #
    # Only a call to a C function may be one.  Everything else this compiler
    # can write is a computation, and a computation nobody takes the value of
    # is a line that does nothing -- refused, because writing one is a
    # mistake rather than an intention.  A C function is the exception
    # because its parameters can carry an address, so what it did may be
    # somewhere other than in the value it returned.
    class CallStatement < Node
      attr_reader :call
      def initialize (call, location = nil)
        super(location)
        @call = call
      end
      def children
        [@call]
      end
    end

    # A call to the function being compiled, from inside its own body.  The
    # name is the one its declaration gave it, which is how C would spell the
    # call too; the symbol it becomes is the generator's business.  What the
    # call takes and returns is the declaration's answer rather than anything
    # inferred, so both travel on the node.
    class RecursiveCall < Node
      attr_reader :name, :arguments, :parameters, :result_type
      def initialize (name, arguments, parameters, result_type, location = nil)
        super(location)
        @name = name
        @arguments = arguments
        @parameters = parameters
        @result_type = result_type
      end
      def children
        @arguments
      end
    end

    # x ** y
    class Power < Node
      attr_reader :base, :exponent
      def initialize (base, exponent, location = nil)
        super(location)
        @base = base
        @exponent = exponent
      end
      def children
        [@base, @exponent]
      end
    end

    class BitwiseNot < Node
      attr_reader :operand
      def initialize (operand, location = nil)
        super(location)
        @operand = operand
      end
      def children
        [@operand]
      end
    end

    class BooleanLiteral < Node
      attr_reader :value
      def initialize (value, location = nil)
        super(location)
        @value = value
      end
      def children
        []
      end
    end

    class UnaryMinus < Node
      attr_reader :operand
      def initialize (operand, location = nil)
        super(location)
        @operand = operand
      end
      def children
        [@operand]
      end
    end

    class MathCall < Node
      attr_reader :name, :arguments
      def initialize (name, arguments, location = nil)
        super(location)
        @name = name
        @arguments = arguments
      end
      def children
        @arguments
      end
    end

    class Conditional < Node
      attr_reader :condition, :consequent, :alternative
      def initialize (condition, consequent, alternative, location = nil)
        super(location)
        @condition = condition
        @consequent = consequent
        @alternative = alternative
      end
      def children
        [@condition, @consequent, @alternative]
      end
    end

    # A block-local variable: w = ...
    # `printf` in the block, for looking at what a kernel is doing.  The
    # format is carried as it was written and rewritten on the way out: C's
    # directives are not Ruby's, and by then each argument's type is known.
    class Print < Node
      attr_reader :template, :arguments
      def initialize (template, arguments, location = nil)
        super(location)
        @template = template
        @arguments = arguments
      end
      def children
        @arguments
      end
    end

    # `raise "..."` in the block.  C has no exception to throw, so the
    # message is not carried out of the kernel: it is registered as it is
    # compiled, the cell writes its code into the error slot the kernel is
    # already watching, and the Ruby side raises when the loop is over.  The
    # message is written out rather than computed, because it has to be known
    # at compile time to be registered at all.
    class Raise < Node
      attr_reader :message
      def initialize (message, location = nil)
        super(location)
        @message = message
      end
      def children
        []
      end
    end

    class Assignment < Node
      attr_accessor :binding_name
      attr_reader :name, :expression
      def initialize (name, expression, location = nil)
        super(location)
        @name = name
        @expression = expression
      end
      def children
        [@expression]
      end
    end

    # A cell of an array: out[i, j] = ...
    #
    # Writes are always at the cell the loop is on.  Writing elsewhere would
    # make the evaluation order a property of the body rather than of the
    # dependencies, which is what lets the order be derived at all.
    class ElementWrite < Node
      # How the left-hand side was indexed.  A kernel writes the cell its
      # outer indices are on, so this is normally just those; a contraction
      # reads it to learn which indices are free and which are summed over.
      attr_accessor :subscripts
      attr_reader :array, :expression
      def initialize (array, expression, location = nil, subscripts = nil)
        super(location)
        @array = array
        @expression = expression
        @subscripts = subscripts
      end
      def children
        [@expression]
      end
    end

    class KernelBody < Node
      attr_reader :statements
      def initialize (statements)
        super(nil)
        @statements = statements
      end
      def children
        @statements
      end
    end

  end
end
