require "fiddle"
require "carray/jit/sweep"

class CArray
  module JIT

    # A compiled kernel, bound to one set of array data types and one set of
    # scalar types.
    #
    # Every kernel has the same C signature, so the Fiddle::Function shape is
    # fixed and the per-kernel detail travels in the six buffers.
    class CompiledKernel

      # @!attribute [r] source
      #   @return [String] the block's Ruby source, as it was read.
      # @!attribute [r] c_source
      #   @return [String] the C this kernel was compiled from.
      # @!attribute [r] compiled
      #   @return [Boolean] whether this call invoked the compiler, rather
      #     than reusing a cached object.
      attr_reader :source, :c_source, :arrays, :storage_types, :reals,
                  :integers, :complexes, :unsigned_integers,
                  :rank, :index_names, :written_arrays,
                  :compiled, :masked, :directions, :contracted_names,
                  :index_axes,
                  # How far a stencil's windows reach on each axis, as
                  # [lowest, highest] per axis: what the caller walks the
                  # interior by.  Empty for a kernel that has no windows.
                  :window_reach, :window_reaches,
                  # What a cell that stopped can have been raising about --
                  # the block's own `raise`s, and those of the bodies pasted
                  # into this kernel, by the code each reports.
                  :raise_messages

      def initialize (source:, generator:, analyzer:, storage_types:)
        @source = source
        @c_source = generator.provenance + generator.generate
        @arrays = generator.arrays
        @reals = generator.reals
        @integers = generator.integers
        @complexes = generator.complexes
        @unsigned_integers = generator.unsigned_integers
        # Per array, the axes read at an index only the running kernel knows,
        # and the extents it checks them against.
        @extent_slots = generator.extent_slots
        @dynamic_arrays = @extent_slots.map(&:first).uniq
        @storage_types = storage_types
        @rank = analyzer.rank
        @index_names = analyzer.index_names
        @written_arrays = analyzer.written_arrays
        @array_ranks = analyzer.array_ranks
        @inner_ranges = analyzer.inner_ranges
        # An index the block wrote twice has two identifiers here; the
        # messages speak the name it was written with.
        @index_sources = analyzer.index_sources
        @axis_uses = @arrays.to_h { |array|
          [array, (0...array_rank(array)).map { |axis| analyzer.axis_use(array, axis) }]
        }
        @contracted_names = analyzer.contracted_names
        # Where each index appears, so that a contraction can take its extents
        # from the arrays and say so when they disagree.
        @index_axes = Hash.new { |hash, key| hash[key] = [] }
        @axis_uses.each do |array, uses|
          uses.each_with_index do |(walkers, _), axis|
            walkers.each { |index, _, _| @index_axes[index] << [array, axis] }
          end
        end

        @masked = generator.masked
        @window_reach = analyzer.window_reach
        @window_reaches = analyzer.window_reaches
        # What `raise` in the block said, by the code the cell that raised
        # writes into the error slot.  The message does not travel: C has
        # nothing to carry it in, and it was known when this was compiled.
        @raise_messages = generator.raise_messages
        # Kept so the sweep entry point can be built from it if one is ever
        # asked for.  Compiling it eagerly would pay for a road most kernels
        # never take.
        @generator = generator
        # The names of the C functions the block called, in the order their
        # addresses are packed into the `functions` buffer.  Names, not the
        # functions themselves: a borrowed function is keyed on its signature
        # alone, so this kernel is shared by every function of that shape and
        # the address has to come from the call rather than from the build.
        @c_function_names = generator.address_functions.keys
        # Arrays handed to a C function whole, in the order their addresses
        # are packed into `data`, and what each was promised to be.
        @address_arrays = generator.address_arrays
        @address_parameters = generator.address_parameters
        # One translation unit holds both entry points -- the kernel and the
        # wrapper CArray's sweep calls -- and one build produces both.  They
        # were two builds of the same body until the second was noticed: the
        # wrapper's source already contains the kernel verbatim, so compiling
        # it separately meant compiling everything twice and throwing the
        # first object away whenever the pass swept, which is the usual case
        # for jit_each.  About 230 ms per call site, and an entry in the
        # cache that was never opened.
        @source_text = generator.provenance + generator.generate_slab(SLAB_NAME)
        @handle, @compiled = Compiler.build(generator.generate_slab(SLAB_NAME),
                                            CGenerator::FUNCTION_NAME,
                                            header: generator.provenance)
        @function = Fiddle::Function.new(@handle[CGenerator::FUNCTION_NAME],
                                         [Fiddle::TYPE_VOIDP] * 10,
                                         Fiddle::TYPE_VOID)
      end

      # `bounds` is one [start, limit, step] per axis.
      #
      # `border:` runs the frame's entry point instead of the interior's: the
      # same statements, with a window that falls off the array answered by
      # the rule the kernel was compiled for rather than by reading.  Which is
      # why the reach is not checked for one -- reaching outside is what it is
      # for, and the C answers for it.
      def call (array_values, scalar_values, bounds, c_function_values = {},
                border: false)
        arrays = @arrays.map { |name| array_values.fetch(name) }
        ranges = index_ranges(bounds, scalar_values)
        verify(arrays, bounds, ranges, scalar_values, reach: !border)

        writable = @arrays.map { |name| @written_arrays.include?(name) }
        error = [0].pack("l")
        packed_bounds = bounds.flatten.pack("q*")
        reals = packed_reals(scalar_values)
        integers = packed_integers(scalar_values, array_values)
        functions = @c_function_names.map { |name|
          c_function_values.fetch(name).pointer.to_i
        }.pack("Q*")
        # An array handed over whole is walked contiguously by the C, so it is
        # packed into an entity first and copied back after if the C may have
        # written to it.  This is the same lifecycle CFunction#call keeps, and for
        # the same reason.
        addressed = @address_arrays.map { |name|
          [name, array_values.fetch(name)]
        }
        packed = addressed.map { |name, array| [array, address_buffer(name, array)] }
        data = packed.map { |_, buffer|
          Access.open([buffer], [false], [nil], [nil]) { |bases|
            bases.first[:pointer]
          }
        }.pack("Q*")

        box = region_box(ranges, scalar_values, array_values)
        Access.open(arrays, writable, box[0], box[1]) do |bases|
          pointers = bases.map { |basis| basis[:pointer] }.pack("Q*")
          strides = bases.flat_map { |basis| basis[:strides] }.pack("q*")
          mask_pointers = bases.map { |basis| basis[:mask_pointer] || 0 }.pack("Q*")
          mask_strides = bases.flat_map { |basis|
            basis[:mask_strides] || Array.new(@rank, 0)
          }.pack("q*")
          entry = border ? border_function : @function
          entry.call(buffer(pointers), buffer(strides), buffer(packed_bounds),
                         buffer(reals), buffer(integers), buffer(functions),
                         buffer(data),
                         buffer(mask_pointers), buffer(mask_strides), error)
        end

        packed.each_with_index do |(array, buffer), index|
          next if array.equal?(buffer)
          next if @address_parameters.fetch(@address_arrays[index]).all?(&:const)
          array[] = buffer
        end

        report(error)
      end

      # @private
      SLAB_NAME = "carray_jit_slab"

      # Runs the kernel as CArray's chunked sweep rather than through the
      # addressing here: CArray acquires the operands, broadcasts them, ORs
      # and propagates the masks, and calls back with a chunk at a time.
      #
      # `array_values` are the operands in the order the kernel addresses
      # them, which is the order it packs `pointers` in -- so the same three
      # arguments the kernel's own loop takes are the ones a chunk arrives as.
      def sweep (array_values, scalar_values, c_function_values = {})
        arrays = @arrays.map { |name| array_values.fetch(name) }
        fsync = @arrays.map { |name|
          @written_arrays.include?(name) ? "1" : "0"
        }.join

        error = [0].pack("l")
        reals = packed_reals(scalar_values)
        integers = packed_integers(scalar_values, array_values)
        functions = @c_function_names.map { |name|
          c_function_values.fetch(name).pointer.to_i
        }.pack("Q*")
        addressed = @address_arrays.map { |name|
          [name, array_values.fetch(name)]
        }
        packed = addressed.map { |name, array| [array, address_buffer(name, array)] }
        data = packed.map { |_, item|
          Access.open([item], [false], [nil], [nil]) { |bases|
            bases.first[:pointer]
          }
        }.pack("Q*")
        # The kernel declares these only when it reads a mask, and a body that
        # reads one does not come this way; they are here because the
        # signature has the slots.
        masks = ("\0" * 8)

        held = [buffer(reals), buffer(integers), buffer(functions),
                buffer(data), masks, masks, error]
        context = held.map { |item| Fiddle::Pointer[item].to_i }.pack("Q*")

        Sweep.call(slab_pointer, fsync, arrays, Fiddle::Pointer[context])

        packed.each_with_index do |(array, item), index|
          next if array.equal?(item)
          next if @address_parameters.fetch(@address_arrays[index]).all?(&:const)
          array[] = item
        end

        report(error)
      end

      # The wrapper CArray's sweep calls, for the same reason #c_source is
      # here: the generated C is the debugging surface.  Built on demand,
      # because a kernel that never sweeps never needs it.
      def slab_source
        @source_text
      end

      # True when this kernel could be run as a sweep at all: the body must
      # not ask about a mask, since a chunk carries no per-cell mask the
      # generated code can test.
      def sweepable?
        !@masked
      end

      private

      # What the cell that stopped said, raised now that Ruby has control
      # back.  C cannot raise, so a failure is a code in a slot and a loop
      # that stops; this is where it becomes the exception the same body run
      # in Ruby would have raised.
      def report (error)
        code = error.unpack1("l")
        case code
        when 0 then nil
        when 1 then raise ZeroDivisionError, "divided by 0"
        when 2 then raise IndexError, "index out of range"
        when 3 then raise ArgumentError,
                            "min argument must be less than or equal to " \
                            "max argument"
        # Ruby's own wording names the value it could not compare, and the
        # slot carries a code rather than a number, so the reason is named
        # instead.  The class and the failure are Ruby's.
        when 4 then raise ArgumentError,
                            "comparison with a NaN failed, so `clamp` has " \
                            "no answer"
        else
          message = @raise_messages[code]
          # A code with no message behind it is this compiler's bug, not the
          # block's, and says so rather than raising something the block
          # looks responsible for.
          raise Error, "the kernel reported #{code}, which is no failure it " \
                       "was compiled to report" unless message
          raise RuntimeError, message
        end
      end

      def slab_pointer
        @slab_pointer ||= @handle[SLAB_NAME]
      end

      # Resolved when the frame is first walked rather than at build time: a
      # kernel that has one is a stencil with a border rule, and even that one
      # runs its interior first.
      def border_function
        @border_function ||=
          Fiddle::Function.new(@handle[CGenerator::BORDER_NAME],
                               [Fiddle::TYPE_VOIDP] * 10, Fiddle::TYPE_VOID)
      end

      # What a C function may be handed as a pointer, and what has to be true
      # of it.  The checks are the declaration's own: the type it points at,
      # the length it said it was, and whether it may be written through.
      # The `reals` slots the kernel reads.  A captured Complex travels as its
      # two parts, after the reals, and the kernel puts it back together with
      # CMPLX -- so both loops pack this the same way, which is why it is one
      # method: #sweep once packed the reals alone, and a kernel that captured
      # a Complex then read slots nothing had written.
      def packed_reals (scalar_values)
        (@reals.map { |name| Float(scalar_values.fetch(name)) } +
         @complexes.flat_map { |name|
           value = scalar_values.fetch(name)
           [Float(value.real), Float(value.imaginary)]
         }).pack("d*")
      end

      # The `integers` slots the kernel reads: the signed captures, then the
      # unsigned ones, then the extents an index is checked against.  A uint64
      # is packed as the bits it is -- `pack("q")` would take 2**63 modulo the
      # width and say nothing -- and the kernel casts the slot back, so the
      # two directives are what makes one buffer carry both widths.
      #
      # One method because both loops pack it, and the same buffer packed in
      # two places is what `packed_reals` is one method about.
      def packed_integers (scalar_values, array_values)
        @integers.map { |name| Integer(scalar_values.fetch(name)) }.pack("q*") +
          @unsigned_integers.map { |name|
            Integer(scalar_values.fetch(name))
          }.pack("Q*") +
          @extent_slots.map { |name, axis|
            array_values.fetch(name).dim[axis]
          }.pack("q*")
      end

      def address_buffer (name, array)
        @address_parameters.fetch(name).each do |parameter|
          wanted = CDeclaration::DATA_TYPES.fetch(parameter.element.fiddle)
          unless array.data_type_name == wanted.to_s
            raise Unsupported,
                  "`#{name}` is handed to a C function as `#{parameter.text}`, " \
                  "which takes a #{wanted} array, and `#{name}` is " \
                  "#{array.data_type_name}"
          end
          if parameter.sized? && array.elements < parameter.array
            raise Unsupported,
                  "`#{name}` is handed to a C function as `#{parameter.text}`, " \
                  "which reads #{parameter.array} of them, and `#{name}` has " \
                  "#{array.elements}"
          end
        end
        if array.has_mask?
          # A masked cell's bytes are out of contract, and a C function has no
          # mask to consult -- it would read whatever is underneath.  What is
          # refused is carrying a mask at all rather than having a cell under
          # it, because the way through is the same either way: `#strip_mask`
          # is where the caller says what the C should see there, and an array
          # that masks nothing loses the mask and no values.
          raise Unsupported,
                "`#{name}` carries a mask and is handed to a C function, " \
                "which has no mask to read; the values under a mask are not " \
                "values, so `#{name}.strip_mask(fill)` is what says what the " \
                "C should see there"
        end
        Access.classify(array)[:entity] ? array : array.copy
      end

      # A pointer into an empty string is not something Fiddle can hand over,
      # and a kernel with no scalars has an empty buffer.
      def buffer (packed)
        packed.empty? ? "\0" * 8 : packed
      end

      # The region tier transfers a box rather than the whole view.  The box
      # is the loop range grown by how far the kernel reaches from the cell it
      # is on -- per array, because two arrays in one kernel need not be read
      # at the same offsets, and per axis, because they need not be read at
      # the same offsets on each of them.
      def region_box (ranges, scalars, array_values)
        starts = []
        counts = []
        @arrays.each do |name|
          per_axis_start = []
          per_axis_count = []
          # An index the kernel works out could reach any cell, so the box is
          # the whole thing.  For a view that has to be transferred that costs
          # what a copy of it would have cost -- which is what the caller
          # would otherwise have written by hand.
          if @dynamic_arrays.include?(name)
            starts << Array.new(array_rank(name), 0)
            counts << array_values.fetch(name).dim.dup
            next
          end
          @axis_uses.fetch(name).each do |walkers, pinned|
            positions = pinned_positions(pinned, scalars)
            # One box per axis, so an axis walked by two indices takes the box
            # that covers both.
            walkers.each do |index, offsets|
              low, high = ranges.fetch(index)
              next unless low < high
              minimum, maximum = offset_span(offsets, scalars)
              positions << low + minimum
              positions << high - 1 + maximum
            end
            if positions.empty?
              per_axis_start << 0
              per_axis_count << 0
              next
            end
            per_axis_start << positions.min
            per_axis_count << positions.max - positions.min + 1
          end
          starts << per_axis_start
          counts << per_axis_count
        end
        [starts, counts]
      end

      def array_rank (array)
        @array_ranks.fetch(array, @rank)
      end

      # Every index's range: the outer ones from the extents, the inner ones
      # from the range each `each` was written with, which is an integer
      # expression over literals and captured scalars.
      def index_ranges (bounds, scalar_values)
        ranges = {}
        @index_names.each_with_index do |name, axis|
          ranges[name] = covered_span(bounds[axis])
        end
        flat = bounds.flatten
        @inner_ranges.each do |name, (from, to, step)|
          ranges[name] = covered_span([evaluate(from, scalar_values, flat),
                                       evaluate(to, scalar_values, flat),
                                       step || 1])
        end
        ranges
      end

      # The half-open span an axis actually touches.  A step may skip cells,
      # but every cell it lands on has to exist, so the span runs from the
      # first index to the last one visited.
      def covered_span (triple)
        start, limit, step = triple
        return [0, 0] if step.positive? ? start >= limit : start <= limit
        count = ((limit - start).abs + step.abs - 1) / step.abs
        last = start + step * (count - 1)
        step.positive? ? [start, last + 1] : [last, start + 1]
      end

      def evaluate (node, scalars, flat_bounds = nil)
        case node
        when IntegerLiteral then node.value
        when CaptureRead    then Integer(scalars.fetch(node.name))
        when BoundsValue    then flat_bounds.fetch(node.slot)
        when UnaryMinus     then -evaluate(node.operand, scalars, flat_bounds)
        when BinaryOperation
          left = evaluate(node.left, scalars, flat_bounds)
          right = evaluate(node.right, scalars, flat_bounds)
          case node.operator
          when :+ then left + right
          when :- then left - right
          when :* then left * right
          else
            raise Unsupported,
                  "an inner loop's range is built from `+`, `-` and `*` only"
          end
        else
          raise Unsupported,
                "an inner loop's range is an integer expression over literals " \
                "and captured scalars"
        end
      end

      def verify (arrays, bounds, ranges, scalars, reach: true)
        # A contraction carries the summed indices' extents after the free
        # ones, because the loops over them are generated rather than written.
        expected = @rank + @contracted_names.size
        unless bounds.size == expected
          raise Unsupported,
                "the kernel has #{expected} index/indices, got #{bounds.size} extent(s)"
        end
        @arrays.each_with_index do |name, position|
          array = arrays[position]
          unless array.is_a?(CArray)
            raise Unsupported, "`#{name}` is not a CArray"
          end
          unless array.rank == array_rank(name)
            raise Unsupported,
                  "`#{name}` has rank #{array.rank}, but is indexed with " \
                  "#{array_rank(name)} #{array_rank(name) == 1 ? 'index' : 'indices'}"
          end
          unless array.data_type_name == @storage_types.fetch(name)
            raise Unsupported,
                  "the kernel was compiled for `#{name}` as " \
                  "#{@storage_types.fetch(name)}, got #{array.data_type_name}"
          end
          verify_bounds(name, array, ranges, scalars) if reach
        end
      end

      # Every cell the kernel would touch has to exist.  Range and offsets and
      # extents are all known here, so reaching outside an array is caught
      # before anything runs rather than read -- or written -- past its end.
      def verify_bounds (name, array, ranges, scalars)
        @axis_uses.fetch(name).each_with_index do |(walkers, pinned), axis|
          extent = array.dim[axis]

          pinned_positions(pinned, scalars).each do |position|
            next if position >= 0 && position < extent
            raise Unsupported,
                  "`#{name}` is indexed at position #{position} on axis " \
                  "#{axis}, " \
                  "which has an extent of #{extent}"
          end

          walkers.each do |index, offsets|
            low, high = ranges.fetch(index)
            next if low >= high
            spelled = @index_sources.fetch(index, index)
            minimum, maximum = offset_span(offsets, scalars)
            if low + minimum < 0
              raise Unsupported,
                    "`#{name}` is indexed at " \
                    "#{offset_text(name, spelled, minimum)}, so " \
                    "the range on `#{spelled}` cannot start at #{low}"
            end
            if high - 1 + maximum > extent - 1
              raise Unsupported,
                    "`#{name}` is indexed at " \
                    "#{offset_text(name, spelled, maximum)}, so " \
                    "the range on `#{spelled}` cannot end at #{high} " \
                    "for an extent of #{extent}"
            end
          end
        end
      end

      # A pinned subscript's position is an integer expression over literals
      # and captured scalars, so its value is known here even though it is not
      # known when the kernel is compiled.
      def pinned_positions (pinned, scalars)
        pinned.map { |node| node.is_a?(Node) ? evaluate(node, scalars) : node }
      end

      # An offset may be an expression over captured integers, so how far the
      # kernel reaches along an axis is known here rather than when it was
      # compiled.
      def offset_span (offsets, scalars)
        values = offsets.map { |offset|
          offset.is_a?(Node) ? evaluate(offset, scalars) : offset
        }
        [values.min, values.max]
      end

      def offset_text (name, index, offset)
        return "`#{name}[#{index}]`" if offset.zero?
        sign = offset.negative? ? "-" : "+"
        "`#{name}[#{index} #{sign} #{offset.abs}]`"
      end

    end

  end
end
