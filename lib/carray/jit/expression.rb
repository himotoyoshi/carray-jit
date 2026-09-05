class CArray

  module JIT

    # Computes a CArray expression -- what `CArray.fuse { a + b * c }` builds
    # -- by compiling it, instead of walking it a node at a time.
    #
    # CArray asks; this answers or declines.  What it is handed is a plan
    # (CArray::Fusion), which already says which operation each node is, what
    # its mask does, and the C that the eager kernel computes it with.  So
    # nothing here restates any of that: it substitutes operands into bodies
    # it was given and wraps the result in a loop.
    #
    # Declining is ordinary.  An expression this cannot address -- an operand
    # that is not laid out end to end, a data type with no C to write it in --
    # goes back to CArray, which walks it and arrives at the same answer.
    class Expression

      # Built the way CArray's own kernels were, since that is what the answer
      # is being compared against.  The Prism front end wants the opposite of
      # this on one point -- it answers to a Ruby loop, which does not fuse a
      # multiply and an add into one rounding, so it compiles with
      # -ffp-contract=off.  Here the reference is the eager kernel, which was
      # built with whatever CArray settled on.
      FLAGS = ["-fPIC", "-shared", *CArray::BUILD_FLAGS.split].freeze

      C_TYPES = {
        float64: "double",  float32: "float",
        int8:    "int8_t",  int16:   "int16_t",
        int32:   "int32_t", int64:   "int64_t",
        uint8:   "uint8_t", uint16:  "uint16_t",
        uint32:  "uint32_t", uint64: "uint64_t",
        boolean: "uint8_t",
      }.freeze

      def initialize
        @kernels = {}
      end

      # Fills `out` and returns true, or writes nothing and returns false.
      def call (plan, out)
        return false unless C_TYPES.key?(plan.data_type)
        aliased = plan.leaves.any? { |array| array.equal?(out) }
        kernel = kernel_for(plan, aliased) or return false
        arrays = [out, *plan.leaves]
        writable = [true, *Array.new(plan.leaves.size, false)]
        Access.open(arrays, writable) do |bases|
          return false unless bases.each_with_index.all? { |basis, i|
            basis[:strides] == end_to_end(arrays[i])
          }
          kernel.call(out.elements, *pointers(plan, bases))
        end
        true
      end

      private

      # An expression of the same shape compiles to the same kernel whatever
      # arrays it is over, which is what the plan's signature says.
      def kernel_for (plan, aliased)
        @kernels.fetch([plan.signature, aliased]) do
          @kernels[[plan.signature, aliased]] = compile(plan, aliased)
        end
      end

      def compile (plan, aliased)
        source = source_for(plan, aliased) or return nil
        handle, = Compiler.build(source, "carray_jit_expression", flags: FLAGS)
        Fiddle::Function.new(handle["carray_jit_expression"],
                             [Fiddle::TYPE_LONG_LONG] +
                               [Fiddle::TYPE_VOIDP] * (1 + arity(plan)),
                             Fiddle::TYPE_VOID)
      rescue CompilationError
        nil
      end

      def arity (plan)
        plan.leaves.size + plan.leaves.count { |array| array.has_mask? } +
          (plan.masked ? 1 : 0)
      end

      def pointers (plan, bases)
        args = [bases.first[:pointer]]
        args << bases.first[:mask_pointer] if plan.masked
        bases.drop(1).each_with_index do |basis, i|
          args << basis[:pointer]
          args << basis[:mask_pointer] if plan.leaves[i].has_mask?
        end
        args
      end

      def end_to_end (array)
        steps = Array.new(array.ndim)
        step = array.bytes
        (array.ndim - 1).downto(0) do |axis|
          steps[axis] = step
          step *= array.dim[axis]
        end
        steps
      end

      # -- the C ------------------------------------------------------------

      def source_for (plan, aliased)
        out_type = C_TYPES.fetch(plan.data_type)
        restrict = aliased ? "" : "restrict "
        body = plan.nodes.each_with_index.map { |node, i| line(plan, node, i) }
        return nil if body.any?(&:nil?)
        <<~C
          #include <math.h>
          #include <stdlib.h>
          #include <stdint.h>
          #include <string.h>

          /* Some kernel bodies call back into CArray: integer division raises
             there rather than trapping.  Resolved against the extension,
             which is loaded by the time this is. */
          extern void ca_zerodiv (void);

          /* The bodies are written in CArray's own C vocabulary. */
          typedef float  float32_t;
          typedef double float64_t;

          void
          carray_jit_expression (int64_t elements, #{out_type} *#{restrict}out#{mask_parameter(plan, restrict)}#{parameters(plan, restrict)})
          {
            for ( int64_t n = 0; n < elements; n++ ) {
          #{body.flatten.map { |l| "    " + l }.join("\n")}
              out[n] = v#{plan.nodes.size - 1};#{plan.masked ? "\n    out_mask[n] = m#{plan.nodes.size - 1};" : ""}
            }
          }
        C
      end

      def mask_parameter (plan, restrict)
        plan.masked ? ", uint8_t *#{restrict}out_mask" : ""
      end

      def parameters (plan, restrict)
        plan.leaves.each_with_index.map { |array, i|
          text = ", const #{C_TYPES.fetch(array.data_type)} *#{restrict}a#{i}"
          text += ", const uint8_t *#{restrict}k#{i}" if array.has_mask?
          text
        }.join
      end

      def line (plan, node, i)
        type = C_TYPES[node.data_type] or return nil
        case node
        when CArray::Fusion::Leaf
          ["#{type} v#{i} = a#{node.index}[n];",
           *(plan.masked ? ["uint8_t m#{i} = #{node.masked ? "k#{node.index}[n]" : "0"};"] : [])]
        when CArray::Fusion::Const
          ["#{type} v#{i} = #{literal(node)};",
           *(plan.masked ? ["uint8_t m#{i} = 0;"] : [])]
        when CArray::Fusion::Op
          statement = substitute(node, i, type) or return nil
          [*(plan.masked ? [mask_line(node, i)] : []),
           "#{type} v#{i};",
           *guarded(node, i, statement, plan.masked)]
        end
      end

      def literal (node)
        case node.data_type
        when :float64, :float32 then "%.17g" % node.value
        when :boolean           then node.value ? 1 : 0
        else node.value.to_s
        end
      end

      def substitute (node, i, type)
        text = node.body.dup
        node.args.each_with_index { |arg, k| text = text.gsub("##{k + 1}", "v#{arg}") }
        text.gsub("##{node.args.size + 1}", "v#{i}").gsub("<type>", type).lines.map(&:strip)
      end

      # A masked cell is not computed where computing it would raise: the
      # divisor there is nobody's business.
      def guarded (node, i, statement, masked)
        return statement unless masked && node.trapping
        ["if ( m#{i} ) { v#{i} = 0; } else {", *statement, "}"]
      end

      # The rules the plan states, written out.
      def mask_line (node, i)
        args = node.args
        case node.mask
        when :pass  then "uint8_t m#{i} = m#{args[0]};"
        when :union then "uint8_t m#{i} = #{args.map { |a| "m#{a}" }.join(" | ")};"
        when :kleene_or, :kleene_and
          known = if node.mask == :kleene_or
                    "((!m#{args[0]} && v#{args[0]}) || (!m#{args[1]} && v#{args[1]}))"
                  else
                    "((!m#{args[0]} && !v#{args[0]}) || (!m#{args[1]} && !v#{args[1]}))"
                  end
          "uint8_t m#{i} = (m#{args[0]} | m#{args[1]}) && ! #{known};"
        end
      end
    end
  end
end
