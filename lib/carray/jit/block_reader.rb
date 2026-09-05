require "prism"

class CArray
  module JIT

    # Recovers the source of a Proc so that a real block can be compiled.
    #
    # Ruby does not hand back a Proc's source, but it does say exactly where
    # the block sits: RubyVM::InstructionSequence carries a :code_location of
    # [first_line, first_column, last_line, last_column].  Columns are what
    # make this usable -- Proc#source_location gives only a line, which cannot
    # tell two blocks on one line apart.
    #
    # RubyVM::AbstractSyntaxTree.of would be the obvious route and does not
    # work: since Ruby 3.4 the default parser is Prism, and it refuses with
    # "cannot get AST for ISEQ compiled by prism".
    module BlockReader

      class << self

        # Returns [Prism node for the block, its source text, where it was
        # written].  The third is for the generated C to say what it came
        # from: a hash names a kernel, a file and a line explain it.
        def read (block)
          unless defined?(RubyVM::InstructionSequence)
            raise Unsupported,
                  "this Ruby has no RubyVM::InstructionSequence; " \
                  "pass the kernel as `source:` instead"
          end

          sequence = RubyVM::InstructionSequence.of(block)
          unless sequence
            raise Unsupported,
                  "the block has no instruction sequence (defined in C?); " \
                  "pass the kernel as `source:` instead"
          end

          location = code_location(sequence)
          source = script_source(sequence)
          node = locate(source, location)
          [node, extract(source, location), origin(sequence, location)]
        end

        private

        def origin (sequence, location)
          path = begin
                   sequence.absolute_path || sequence.path
                 rescue NoMethodError
                   nil
                 end
          path ? "#{path}:#{location[0]}" : nil
        end

        def code_location (sequence)
          location = sequence.to_a[4][:code_location]
          unless location
            raise Unsupported,
                  "this Ruby does not report a code location for blocks; " \
                  "pass the kernel as `source:` instead"
          end
          location
        end

        # script_lines is present when the code was compiled with
        # RubyVM.keep_script_lines set, which covers eval'd blocks; otherwise
        # the file is read back.
        def script_source (sequence)
          lines = begin
                    sequence.script_lines
                  rescue NoMethodError
                    nil
                  end
          return lines.join if lines

          path = sequence.absolute_path
          if path && File.file?(path)
            return File.read(path)
          end

          raise Unsupported,
                "the block's source is not available " \
                "(defined in eval or in a console?); " \
                "pass the kernel as `source:`, or set " \
                "RubyVM.keep_script_lines = true before defining it"
        end

        def locate (source, location)
          first_line, first_column, = location
          result = Prism.parse(source)
          unless result.success?
            raise Unsupported, "the file holding the block does not parse"
          end
          node = find(result.value, first_line, first_column)
          unless node
            raise Unsupported,
                  "could not find the block at line #{first_line}, " \
                  "column #{first_column}; " \
                  "has the file changed since it was loaded?"
          end
          node
        end

        def find (node, line, column)
          if block_like?(node) &&
             node.location.start_line == line &&
             node.location.start_column == column
            return node
          end
          node.compact_child_nodes.each do |child|
            found = find(child, line, column)
            return found if found
          end
          nil
        end

        def block_like? (node)
          node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)
        end

        def extract (source, location)
          first_line, first_column, last_line, last_column = location
          lines = source.lines
          if first_line == last_line
            lines[first_line - 1][first_column...last_column]
          else
            body = lines[(first_line - 1)...last_line]
            body[0] = body[0][first_column..]
            body[-1] = body[-1][0...last_column]
            body.join
          end
        end

      end

    end

  end
end
