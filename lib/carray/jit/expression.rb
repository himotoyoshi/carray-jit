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

      # A kernel that can divide by zero calls ca_zerodiv, which the CArray
      # extension defines and this object does not.  ELF is content to leave
      # the name undefined and resolve it when the object is loaded, which is
      # what the declaration in #source_for assumes; Mach-O refuses to link at
      # all, so on macOS every expression holding an integer `/` or `%` failed
      # to compile and was silently handed back to CArray to walk.  The flag
      # says to look the name up at load time, which is what Ruby builds its
      # own extensions with and the only thing this object leaves undefined.
      DYNAMIC_LOOKUP =
        (RbConfig::CONFIG["host_os"] =~ /darwin/ ? ["-Wl,-undefined,dynamic_lookup"] : []).freeze

      # Built the way CArray's own kernels were, since that is what the answer
      # is being compared against.  The Prism front end wants the opposite of
      # this on one point -- it answers to a Ruby loop, which does not fuse a
      # multiply and an add into one rounding, so it compiles with
      # -ffp-contract=off.  Here the reference is the eager kernel, which was
      # built with whatever CArray settled on.
      FLAGS = ["-fPIC", "-shared", *CArray::BUILD_FLAGS.split, *DYNAMIC_LOOKUP].freeze

      C_TYPES = {
        float64: "double",  float32: "float",
        int8:    "int8_t",  int16:   "int16_t",
        int32:   "int32_t", int64:   "int64_t",
        uint8:   "uint8_t", uint16:  "uint16_t",
        uint32:  "uint32_t", uint64: "uint64_t",
        boolean: "uint8_t",
      }.freeze

      # A shifted read is a node CArray added after 3.0.2; one that does not
      # have it never hands one over.
      SHIFTED = defined?(CArray::Fusion::Shifted) ? CArray::Fusion::Shifted : Class.new

      def initialize
        @kernels = {}
      end

      # Fills `out` and returns true, or returns false and leaves it to
      # CArray.  A decline may have written part of `out` first, which is
      # what walking it over again then settles.
      def call (plan, out)
        return false unless C_TYPES.key?(plan.data_type)
        aliased = plan.leaves.any? { |array| array.equal?(out) }
        # A shifted read reaches cells other than the one being written, so
        # over its own output it would read what it has just written.
        return false if aliased && shifted_leaves(plan).any? { |i| plan.leaves[i].equal?(out) }
        kernel = kernel_for(plan, aliased) or return false
        arrays = [out, *plan.leaves]
        writable = [true, *Array.new(plan.leaves.size, false)]
        Access.open(arrays, writable) do |bases|
          return false unless bases.each_with_index.all? { |basis, i|
            basis[:strides] == end_to_end(arrays[i])
          }
          if shifted?(plan)
            dim = out.dim.pack("q*")
            kernel.call(out.elements, Fiddle::Pointer[dim], *pointers(plan, bases))
          else
            kernel.call(out.elements, *pointers(plan, bases))
          end
        end
        true
      rescue ZeroDivisionError
        # A zero divisor is an answer, not a fault: it is what ca_zerodiv --
        # the only thing a kernel here calls out to -- reports, and the same
        # expression walked reaches the same place and raises the same error.
        #
        # CArray cannot tell the two apart, though.  It catches whatever an
        # evaluator raises, retires it for the rest of the process and says so
        # on stderr, which is right for an evaluator that is broken and wrong
        # for one that has just met a zero.  So this declines instead, and
        # CArray walks the expression and raises it there.  Anything else
        # still reaches CArray and still retires this, which is what that net
        # is for.
        #
        # What it costs: a kernel that raised where the walk does not -- over
        # a masked zero, say -- now reads as slow rather than as wrong, since
        # the walk answers and nobody sees the difference.  The answer is
        # right either way, and the masked-divisor test asks the evaluator
        # directly for that reason.
        false
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
          (plan.masked ? 1 : 0) + (shifted?(plan) ? 1 : 0)
      end

      def shifted? (plan)
        plan.nodes.any? { |node| node.is_a?(SHIFTED) }
      end

      def shifted_leaves (plan)
        plan.nodes.grep(SHIFTED).map(&:index)
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
        body = statements(plan, :edge) or return nil
        result = ["out[n] = v#{plan.nodes.size - 1};",
                  *(plan.masked ? ["out_mask[n] = m#{plan.nodes.size - 1};"] : [])]
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
          carray_jit_expression (int64_t elements#{shifted?(plan) ? ", const int64_t *dim" : ""}, #{out_type} *#{restrict}out#{mask_parameter(plan, restrict)}#{parameters(plan, restrict)})
          {
          #{loop(plan, body + result, shifted?(plan) && (statements(plan, :inside) + result)).join("\n")}
          }
        C
      end

      # The C for every node, in order.  `where` matters only to a shifted
      # read: at the :edge it may fall outside the array, :inside it cannot.
      def statements (plan, where)
        @where = where
        body = plan.nodes.each_with_index.map { |node, i| line(plan, node, i) }
        body.any?(&:nil?) ? nil : body.flatten
      end

      # Cell by cell in storage order.  A plan that reads an array shifted
      # needs to know where along each axis the cell is, so it walks the
      # outer axes and splits the last one in three: the stretch in the
      # middle, where no shifted read can leave the array, is a plain loop
      # the compiler can vectorise, and only the ends check.
      def loop (plan, edge, inside = nil)
        unless inside
          return ["  for ( int64_t n = 0; n < elements; n++ ) {",
                  *edge.map { |l| "    " + l }, "  }"]
        end
        ndim = plan.dim.size
        last = ndim - 1
        offsets = plan.nodes.grep(SHIFTED).map(&:offset)
        lines = (0...ndim).map { |k| "  const int64_t d#{k} = dim[#{k}];" }
        plan.nodes.each_with_index do |node, i|
          next unless node.is_a?(SHIFTED)
          flat = (1...ndim).reduce("(int64_t)(#{node.offset[0]})") { |acc, k|
            "(#{acc}) * d#{k} + (#{node.offset[k]})"
          }
          lines << "  const int64_t o#{i} = #{flat};"
        end
        (0...ndim).each do |k|
          below = [0, *offsets.map { |o| -o[k] }].max
          above = [0, *offsets.map { |o| o[k] }].max
          lines << "  const int64_t lo#{k} = d#{k} < #{below} ? d#{k} : #{below};"
          lines << "  const int64_t hi#{k} = d#{k} - #{above} > lo#{k} ? d#{k} - #{above} : lo#{k};"
        end
        indent = "  "
        (0...last).each do |k|
          lines << "#{indent}for ( int64_t i#{k} = 0; i#{k} < d#{k}; i#{k}++ ) {"
          indent += "  "
        end
        row = (0...last).reduce("(int64_t) 0") { |acc, k| "(#{acc}) * d#{k} + i#{k}" }
        row = "(#{row}) * d#{last}"
        outer = (0...last).map { |k| "i#{k} >= lo#{k} && i#{k} < hi#{k}" }
        lines << "#{indent}const int64_t row = #{row};"
        lines << "#{indent}const int64_t a = #{outer.empty? ? "lo#{last}" : "(#{outer.join(" && ")}) ? lo#{last} : d#{last}"};"
        lines << "#{indent}const int64_t b = a < hi#{last} ? hi#{last} : a;"
        [["0", "a", edge], ["a", "b", inside], ["b", "d#{last}", edge]].each do |from, to, body|
          lines << "#{indent}for ( int64_t i#{last} = #{from}; i#{last} < #{to}; i#{last}++ ) {"
          lines << "#{indent}  const int64_t n = row + i#{last};"
          lines.concat(body.map { |l| "#{indent}  " + l })
          lines << "#{indent}}"
        end
        (last - 1).downto(0) do |k|
          indent = indent[2..]
          lines << "#{indent}}"
        end
        lines
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
        when SHIFTED
          shifted_line(plan, node, i, type)
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

      # The cell `offset` away, read from an index clamped into the array so
      # that the load is always in bounds, then replaced where it fell out.
      def shifted_line (plan, node, i, type)
        bounds = node.bounds.uniq
        return nil unless bounds.size == 1
        if @where == :inside
          return ["#{type} v#{i} = a#{node.index}[n + o#{i}];",
                  *(plan.masked ? ["uint8_t m#{i} = #{node.masked ? "k#{node.index}[n + o#{i}]" : "0"};"] : [])]
        end
        ndim = node.offset.size
        index = (0...ndim).map { |k| "s#{i}_#{k}" }
        lines = node.offset.each_with_index.map { |o, k|
          "int64_t #{index[k]} = i#{k} + (#{o});"
        }
        inside = (0...ndim).map { |k| "#{index[k]} >= 0 && #{index[k]} < d#{k}" }.join(" && ")
        lines << "int s#{i}_in = #{inside};"
        (0...ndim).each { |k|
          lines << "int64_t c#{i}_#{k} = #{index[k]} < 0 ? 0 : (#{index[k]} >= d#{k} ? d#{k} - 1 : #{index[k]});"
        }
        flat = (1...ndim).reduce("c#{i}_0") { |acc, k| "(#{acc}) * d#{k} + c#{i}_#{k}" }
        lines << "#{type} v#{i} = a#{node.index}[#{flat}];"
        if bounds.first == :fill
          fill = CArray::Fusion::Const.new(node.fill, node.data_type)
          lines << "if ( ! s#{i}_in ) { v#{i} = #{literal(fill)}; }"
        end
        if plan.masked
          inner = node.masked ? "k#{node.index}[#{flat}]" : "0"
          outer = bounds.first == :mask ? "1" : "0"
          lines << "uint8_t m#{i} = s#{i}_in ? #{inner} : #{outer};"
        end
        lines
      end

      def literal (node)
        case node.data_type
        when :float64, :float32 then float_literal(node.value.to_f)
        when :boolean           then truth(node.value) ? 1 : 0
        else node.value.to_s
        end
      end

      # `%.17g` writes -0.0 as "-0", which C reads as the integer 0 negated,
      # and writes NaN and the infinities as words C does not know.
      def float_literal (value)
        return "NAN" if value.nan?
        return (value > 0 ? "INFINITY" : "(-INFINITY)") if value.infinite?
        text = "%.17g" % value
        text.match?(/[.e]/) ? text : "#{text}.0"
      end

      # A boolean cell as CArray stores it: 0 is false, as is false.
      def truth (value)
        value.is_a?(Numeric) ? value != 0 : !!value
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
