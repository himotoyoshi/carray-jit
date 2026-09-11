require "carray"

require "carray/jit/version"
require "carray/jit/errors"
require "carray/jit/node"
require "carray/jit/analyzer"
require "carray/jit/block_reader"
require "carray/jit/c_function"
require "carray/jit/type_assignment"
require "carray/jit/c_generator"
require "carray/jit/compiler"
require "carray/jit/access"
require "carray/jit/kernel"

class CArray

  # @!group Compiling a block

  # Returns the kernel compiled from `block` and run over `extents`.
  #
  # The block's parameters are the loop indices, and each extent is a Range or
  # an Integer standing for `0...n`, one per index:
  #
  #   CArray.jit_for(2...24) { |i|
  #     w  = x * leg[i-1]
  #     wy = w - leg[i-2]
  #     leg[i] = wy + w - wy/i
  #   }
  #
  # Naming an index is what lets a kernel reach a neighbouring cell, and
  # reaching a neighbouring cell is what makes the range and the direction
  # matter.  A computation that reaches no neighbour names no index and needs
  # no extent, and is written with CArray.jit_each or CArray.jit_map instead.
  #
  # Arrays and scalars are the variables the block closes over, so nothing has
  # to be named twice.  Which way each axis runs is derived from the kernel's
  # own dependencies, not chosen: reading a cell the kernel will later write
  # means that cell has to be reached in one particular order.
  #
  # A block outside the compilable subset raises CArray::JIT::Unsupported
  # rather than falling back to a Ruby loop.  Nobody calls this method except
  # to make a per-cell computation fast, so quietly doing the slow thing would
  # answer a question that was not asked.
  #
  # The name is CArray's own: carray/lazy.rb defines jit_for to raise
  # NotImplementedError, saying that the block is compiled and that the
  # compiler is this gem.  Requiring carray/jit replaces it with this one.
  # So the method is named where the subset is documented, and a program that
  # calls it either compiles or is told why it cannot -- an expression over
  # whole arrays that needs no compiler is CArray.fuse's.
  #
  # `reassociate:` says whether a reduction's accumulator may be split into
  # partial sums.  It defaults to CArray::JIT.reassociate, which is true:
  # the answer is then not the one a serial Ruby loop reaches, and is usually
  # the more accurate of the two, because splitting the accumulation is what
  # limits the cancellation.  Pass false for the serial order -- for a
  # compensated summation, whose algorithm *is* the order, or to check a
  # kernel against the loop it replaces.
  #
  # Returns the compiled kernel, whose {CArray::JIT::CompiledKernel#c_source} is the
  # C that ran.
  #
  # The block is read and compiled, never called, so it is not yielded to.
  #
  # @param extents [Array<Range, Integer>] one per loop index, an Integer
  #   standing for `0...n`.
  # @param reassociate [Boolean, nil] whether a reduction's accumulator may be
  #   split into partial sums; `nil` defers to {CArray::JIT.reassociate}.
  # @return [CArray::JIT::CompiledKernel]
  # @raise [CArray::JIT::Unsupported] when the block falls outside the
  #   recognized subset, or the extents do not match its parameters.
  def self.jit_for (*extents, reassociate: nil, &block)
    unless block
      raise JIT::Unsupported, "jit_for needs a block"
    end
    if block.arity.zero?
      raise JIT::Unsupported,
            "jit_for's block names the cells it is on, so it takes the loop " \
            "indices as its parameters; a block that names none is " \
            "element-wise and belongs to jit_each"
    end
    JIT.run(extents, block, reassociate)
  end

  # Returns the kernel compiled from `block` and run at every cell.
  #
  # Element-wise means what it means in CArray: every cell is computed from
  # the cells beside it in the other arrays, none reaches a neighbour, and the
  # shapes are broadcast.  So there is no index to name and no extent to give,
  # and what changes is not the expression but how it runs -- at the cell, in
  # one pass, instead of one pass per operation with intermediate arrays in
  # between.
  #
  #   CArray.jit_each { out = a + b * c }
  #
  # The arrays are the variables the block closes over, and the expression is
  # written the way CArray already writes it.  Every name in the block is a
  # cell -- the loop is this compiler's and is not written here -- so the
  # assignment is Ruby's own: `out = ...` writes the cell of the array `out`
  # names outside.  A name that is not an array there is a local of the
  # block's, as it is anywhere else.
  #
  # `each` is what CArray means by it: a cell.  It is jit_for's sibling and
  # not its special case -- a block that names an index is on a cell and can
  # reach the cells around it, which is what makes a range and a direction
  # matter, while an element-wise block has neither.  And it is jit_map's
  # sibling in the other direction: the name says whether a value comes back.
  #
  # Like jit_for, the name is CArray's own and raises there until this gem
  # replaces it.  Written without a compiler, the same computation is
  # CArray.fuse's -- the expression itself, one pass per operation, with the
  # intermediates this one does without.
  #
  # Returns the compiled kernel, whose #c_source is the C that ran.  The
  # value of the computation is in the
  # arrays the block wrote; ask for it back with {CArray.jit_map} instead.
  #
  # The block is read and compiled, never called, so it is not yielded to.
  #
  # @return [CArray::JIT::CompiledKernel]
  # @raise [CArray::JIT::Unsupported] when the block falls outside the
  #   recognized subset, or names any parameter.
  def self.jit_each (&block)
    unless block
      raise JIT::Unsupported, "jit_each needs a block"
    end
    unless block.arity.zero?
      raise JIT::Unsupported,
            "this block names the arrays it reaches, so it takes no " \
            "parameters; for a loop that names its indices, see `jit_for`"
    end
    JIT.run_over_whole_arrays(block)
  end

  # Returns a new array holding `block`'s value at every cell.
  #
  # The same block as {CArray.jit_each}, with its value asked for:
  #
  #   larger = CArray.jit_map { a > b ? a : b }
  #
  # The last statement is the value every cell of the result gets, and the
  # result is allocated here and returned, typed from that value. An
  # assignment may be the last statement -- in Ruby an assignment has the
  # value it assigned -- so a block may write an array of yours and hand the
  # same value back.
  #
  # The block is read and compiled, never called, so it is not yielded to.
  #
  # @return [CArray] a new array, typed from the block's value.
  # @raise [CArray::JIT::Unsupported] when the block falls outside the
  #   recognized subset, or names any parameter.
  def self.jit_map (&block)
    unless block
      raise JIT::Unsupported, "jit_map needs a block"
    end
    unless block.arity.zero?
      raise JIT::Unsupported,
            "this block names the arrays it reaches, so it takes no " \
            "parameters; for a loop that names its indices, see `jit_for`"
    end
    JIT.run_over_whole_arrays(block, map: true)
  end

  # Returns a new array holding `block`'s value at every cell, computed from
  # windows onto `arrays`.
  #
  # A stencil: every cell from the ones around it, with the loop implied.
  #
  #   smoothed = CArray.jit_stencil(image) { |a|
  #     0.25 * (a[-1, 0] + a[1, 0] + a[0, -1] + a[0, 1])
  #   }
  #
  # The arrays are given rather than closed over, and the block's parameters
  # are windows onto them, in that order: `a[0, 0]` is the cell, `a[-1, 1]`
  # its neighbour. The block's value is what the cell gets, as jit_map's is,
  # and the result comes back -- an array of the same shape.
  #
  # Naming a window rather than an index is what lets the edge be said at the
  # call rather than written into the loop. Where the window falls off the
  # array there is nothing to read, and `border:` says what to do about it:
  #
  #   :mask   the cell is UNDEF -- it was not computed  (the default)
  #   :skip   the cell is left as it was found
  #
  # The default is `:mask` because CArray can say "not computed", and a
  # border of zeros that means the same thing cannot be told from zeros that
  # were computed.
  #
  # `type:` names the array to collect into; without it the type is the
  # block's value's, as jit_map's result is. `into:` writes into an array of
  # yours instead, and then the type is that array's.
  #
  # The block is read and compiled, never called, so it is not yielded to.
  #
  # @param arrays [Array<CArray>] the arrays the block has windows onto, in
  #   the order its parameters name them.
  # @param border [Symbol] `:mask` to leave an uncomputed cell UNDEF,
  #   `:skip` to leave it as it was found.
  # @param type [Symbol, nil] the data type to collect into; `nil` takes the
  #   block's value's.
  # @param into [CArray, nil] an array of yours to write into, which then
  #   decides the type.
  # @return [CArray] `into` when it is given, otherwise a new array.
  # @raise [CArray::JIT::Unsupported] when the block falls outside the
  #   recognized subset, when no array is given, or when both `type` and
  #   `into` are.
  def self.jit_stencil (*arrays, border: :mask, type: nil, into: nil, &block)
    unless block
      raise JIT::Unsupported, "jit_stencil needs a block"
    end
    if arrays.empty?
      raise JIT::Unsupported,
            "jit_stencil takes the arrays its block has windows onto, as in " \
            "`CArray.jit_stencil(image) { |a| ... }`"
    end
    JIT.run_stencil(arrays, block, border, type, into)
  end

  # Returns the contraction the block writes: a repeated index is summed.
  #
  #   CArray.jit_contract { |i, j, k| c[i,j] = a[i,k] * b[k,j] }
  #
  # Every block parameter is an index.  The ones that appear on the left are
  # the cells written; the rest -- `k` here -- are summed over.  An index that
  # repeats is summed however often it repeats: `q[i,i,i]` is one index read
  # at three positions, and the sum runs along the cube's long diagonal.
  #
  # No extent is given, because every index's extent is fixed by the axes it
  # addresses; an index whose axes disagree is an error, which is the shape
  # check a contraction needs.
  #
  # With no assignment the result is allocated and returned, with the free
  # indices as its axes in the order the block named them:
  #
  #   c = CArray.jit_contract { |i, j, k| a[i,k] * b[k,j] }
  #
  # Assigning into an array of your own says where to put it, and in what
  # order its axes lie; it does not decide what is summed.
  #
  # That a repeated index is summed is a statement about *dimensions*,
  # which is the world the notation comes from: two dimensions met is an inner
  # product, and there is no other reading.  An index that numbers things --
  # a point, a sample, a batch -- is not a dimension, and `x[p,k] * y[p,k]`
  # repeating `p` says "the same point", not "sum over points".  Naming the
  # result's axes says which is meant:
  #
  #   CArray.jit_contract(:p) { |k| x[p,k] * y[p,k] }               # one number per point
  #   CArray.jit_contract(:a) { square[a,a] }                       # the diagonal, not the trace
  #   CArray.jit_contract(:b, :i, :j) { |k| u[b,i,k] * v[b,k,j] }   # a batch of products
  #
  # The arguments are the result's axes, in that order.  What they say is
  # which indices are free; what a repetition means is unchanged.  So the rule
  # is the convention's, with a third clause: an index that repeats is summed,
  # one that appears once is free, and a named one is free however often it
  # appears -- which is what puts the diagonal and the per-point quantity
  # inside the notation instead of outside it.  The list is all of the
  # result's axes rather than some of them -- name one and you have named them
  # all -- so what is left out of it is summed, at however few positions it
  # sits: `jit_contract(:i) { |k| a[i,k] }` is the row sums, which the
  # convention alone cannot say.  (`sum(axis:)` is the faster way to write
  # that one, being a reduction rather than a contraction.)  Naming is allowed
  # even where the convention would have reached the same answer, which is how
  # the result's axes are put in another order.
  #
  # Where the block assigns into an array of yours, the left-hand side has the
  # result's axes on it, and an axis there that the list left out is the list
  # falling short rather than an index to sum -- which is refused, and is the
  # one place a short list is caught.
  #
  # The sum is split into partial ones, as `jit_for`'s reduction is: a
  # contraction says which indices are summed and nothing about the order, so
  # there is no order here to override.  `CArray::JIT.reassociate = false`
  # asks for the serial one, which is what a Ruby loop would take.
  #
  # The block is read and compiled, never called, so it is not yielded to.
  #
  # @param free_indices [Array<Symbol>] the result's axes, in order; empty to
  #   let the convention decide, which is an index appearing once.
  # @return [CArray, CArray::JIT::CompiledKernel] the allocated result when the block
  #   assigns into nothing, otherwise the compiled kernel.
  # @raise [CArray::JIT::Unsupported] when the block falls outside the
  #   recognized subset, or an index's axes disagree.
  def self.jit_contract (*free_indices, &block)
    unless block
      raise JIT::Unsupported, "jit_contract needs a block"
    end
    unless free_indices.all? { |name| name.is_a?(Symbol) }
      raise JIT::Unsupported,
            "jit_contract's arguments are the result's axes, named as symbols, " \
            "as in `CArray.jit_contract(:p) { |k| x[p,k] * y[p,k] }`"
    end
    repeated = free_indices.tally.select { |_, count| count > 1 }.keys
    unless repeated.empty?
      raise JIT::Unsupported,
            "#{repeated.map { |name| "`#{name}`" }.join(', ')} names more than " \
            "one axis of the result; each axis is one index"
    end
    # Nothing named is the convention; naming none of them is a contraction
    # to a single number, and the two are different statements.
    JIT.run_contraction(block, free_indices.empty? ? nil : free_indices)
  end

  # @!endgroup

  # @!endgroup

  # @!group C functions

  # Returns a callable for a C function someone else compiled, named by
  # quoting its declaration, so that a kernel body -- or Ruby -- can call it:
  #
  #   j0 = CArray.jit_extern("double j0(double)", from: "libgsl")
  #   CArray.jit_each { out = j0.call(x) }
  #
  # Nothing is compiled here: `extern` is C's word for a body that lives
  # elsewhere, and finding it is Fiddle's job.  What this gem adds is that the
  # kernel calls the address directly instead of reaching it per cell through
  # Fiddle.
  #
  # @param prototype [String] the function's C declaration, as C writes it.
  # @param from [String, nil] the library to open; `nil` searches the process.
  # @return [CArray::JIT::CFunction]
  def self.jit_extern (prototype, from: nil, &block)
    JIT.extern(prototype, from: from, &block)
  end

  # Returns a callable for a C function of your own, written in Ruby and
  # compiled here:
  #
  #   smoothstep = CArray.jit_function("double (*)(double)") { |t| t * t }
  #
  # It is called from a kernel like any other, which gives kernels a body that
  # can be factored and named, and its address may be handed to a C library
  # that knows nothing about Ruby.
  #
  # The block is read and compiled, never called, so it is not yielded to.
  #
  # @param prototype [String] the function's C declaration, as C writes it.
  # @return [CArray::JIT::CFunction]
  # @raise [CArray::JIT::Unsupported] when the block falls outside the
  #   recognized subset.
  def self.jit_function (prototype, &block)
    JIT.function(prototype, &block)
  end

  # Returns a random number generator a kernel can draw from:
  #
  #   rand = CArray.jit_rng(seed: 4)
  #   CArray.jit_for(n) { |i| out[i] = random(rng: rand) }
  #
  # `random(rng: rand)` gives one double in [0.0, 1.0).  Each generator has its own
  # state, so two of them in one kernel are two independent sequences, and
  # the state survives the call: a second kernel over the same generator
  # carries on rather than starting again.
  #
  # What comes back is a CArray::Rng, and it is a generator on both sides
  # of the compiler.  So a sequence can begin in an array and continue in a
  # kernel:
  #
  #   rand = CArray.jit_rng(seed: 4)
  #   a.random!(rng: rand)                         # fills a, advancing rand
  #   CArray.jit_for(n) { |i| b[i] = random(rng: rand) }   # b takes the next draws
  #
  # and those are the same numbers a single `random!` over `a` and `b` would
  # have laid down, because CArray's generator and the kernel's are one text
  # rather than two implementations.  `CArray::Rng.new` makes the same
  # object; this is the spelling that says what it is for.
  #
  # Which draw lands in which cell is the loop's order, which is the
  # caller's -- the same rule every kernel here follows.  Where that matters
  # -- common random numbers, antithetic variates -- what is wanted is a
  # generator addressed by position, and this is not one.
  #
  # @param seed [Integer, nil] the seed; nil draws one, so two generators
  #   made without a seed differ.  The seed is data the kernel is handed and
  #   not part of it, so the same compiled kernel serves every seed.
  # @param generator [Symbol] which generator, from
  #   `CArray::Rng::GENERATORS`.
  # @return [CArray::Rng]
  def self.jit_rng (seed: nil, generator: :xoshiro256pp)
    JIT.rng(seed: seed, generator: generator)
  end

  # @!endgroup

  # The compiler behind `CArray.jit_*`: it reads a block, generates C for it,
  # builds it and calls it.  What is public here is the reassociation default
  # and the kernel cache; the rest is the machinery.
  module JIT

    class << self

      # Whether a reduction's accumulator may be split into partial sums when
      # the call site does not say.  True: a kernel is here to be fast, and
      # splitting the accumulation is usually the more accurate answer as well
      # as the faster one.
      #
      # What it does not give is the order a serial Ruby loop takes, so it is
      # false that says "compute this exactly as the loop would" -- for a
      # compensated summation, or to check one against the other.
      # CARRAY_JIT_REASSOCIATE=0 sets it false for a whole process, which is
      # how this gem's own tests compare against Ruby.
      # @!attribute [w] reassociate
      #   Sets whether a reduction's accumulator may be split into partial
      #   sums when the call site does not say.
      #   @return [Boolean]
      attr_writer :reassociate

      # @return [Boolean] whether a reduction's accumulator may be split when
      #   the call site does not say.
      def reassociate
        return @reassociate unless @reassociate.nil?
        @reassociate = ENV["CARRAY_JIT_REASSOCIATE"] != "0"
      end

      # `CArray.jit_rng`.  The generator is CArray's -- this makes one and
      # says why the making is here: a kernel can only draw from a generator
      # whose C it can paste, and whether this CArray hands its C out is the
      # thing to find out now rather than at the compile.
      def rng (seed: nil, generator: :xoshiro256pp)
        unless defined?(CArray::Rng) &&
               CArray::Rng.const_defined?(:SOURCE)
          raise Unsupported,
                "this CArray does not hand out its generator's source " \
                "(CArray::Rng::SOURCE), so a kernel cannot draw from " \
                "one; CArray 3.0.2 or newer is what carries it"
        end
        unless CArray::Rng::SOURCE.key?(generator)
          raise Unsupported,
                "`#{generator.inspect}` is not a generator this CArray hands " \
                "the source of; it has " \
                "#{CArray::Rng::SOURCE.keys.map(&:inspect).join(', ')}"
        end
        CArray::Rng.new(generator, :seed => seed)
      end

      # @private
      RESULT = :__contraction_result

      # @private
      def run_contraction (block, free_indices = nil)
        node, source, origin = read_block(block)
        # An index named at the call site is not a parameter of the block, so
        # the block reaches for it the way it reaches for a captured value.
        # It is neither: it is an index, and it is answered here.
        names = capture_names(source, node) - (free_indices || [])
        arrays, scalars, c_functions, randoms =
          split_captures(names, binding_of(block))
        refuse_a_generator(randoms, "a contraction", "the block is a summand " \
          "and runs once per term, so a draw in it would be one per term " \
          "rather than one per cell of the result")
        contract(source, arrays, free_indices, node: node, origin: origin,
                 scalars: scalars, c_functions: c_functions)
      end

      # Reads a block as a contraction and returns the terms it is a product
      # of, or nil when it is not one:
      #
      #   CArray::JIT.contraction_of(proc { |i, j, k| a[i,k] * b[k,j] })
      #   #=> { :terms => [[a, [:i, :k]], [b, [:k, :j]]],
      #   #     :free => [:i, :j], :summed => [:k], :scale => 1 }
      #
      # A number multiplied into the product is not a term -- it has no
      # indices and no cell -- so it comes back as `:scale`, which is 1 where
      # there is none.  `a[i,k] * b[k,j] * 2.0` is the same contraction scaled,
      # and a caller that rearranges it has to put the scale back: multiplying
      # a sum by a number and multiplying each of its terms are the same
      # arithmetic, but not the same rounding, and they are not the same
      # computation type either where the number is wider than the cells.
      #
      # This is the half of `jit_contract` that decides *what* is being
      # computed, without compiling anything, for a caller that wants to
      # rearrange it -- to contract two terms at a time, say, in an order it
      # chose -- and then reach `contract_terms` with the pieces.
      #
      # Nil means "there is nothing here to rearrange", not that the block is
      # wrong: a summand that is more than a product of element reads
      # (`Math.exp(a[i,k]) * b[k,j]`, a division, a captured scalar, an index
      # with an offset), or one that assigns into an array of its own. Such a
      # block is still a contraction and `jit_contract` still compiles it; it
      # is just not a product to be taken apart. A block that is not a
      # contraction at all raises here, as it would there.
      #
      # @param block [Proc] the block, read and not called.
      # @param free_indices [Array<Symbol>] the result's axes, as
      #   `jit_contract` takes them.
      # @return [Hash, nil] `{ terms:, free:, summed: }`, or nil.
      # @raise [CArray::JIT::Unsupported] when the block is not a contraction.
      def contraction_of (block, *free_indices)
        node, source, = read_block(block)
        # As `jit_contract` reads them: naming none is the convention, which
        # is not the same as naming an empty list of axes.
        free_indices = nil if free_indices.empty?
        names = capture_names(source, node) - (free_indices || [])
        arrays, scalars, c_functions, randoms =
          split_captures(names, binding_of(block))
        refuse_a_generator(randoms, "a contraction", "the block is a summand " \
          "and runs once per term, so a draw in it would be one per term " \
          "rather than one per cell of the result")
        # A compiled function in the summand is not something the structure
        # carries; a captured number is, as the scale.
        return nil unless c_functions.empty?

        analyzer = Analyzer.new(source, node: node, array_names: arrays.keys,
                                contract: :probe, free_indices: free_indices,
                                cell_names: cell_names(arrays))
        statements = analyzer.body.statements
        # Locals before the summand are computation the structure cannot
        # carry either; an ElementWrite last is the assigned form.
        return nil unless statements.size == 1
        factors = product_terms(statements.last, arrays, scalars)
        return nil unless factors
        terms, scale = factors
        return nil if terms.empty?

        free = analyzer.probe_free_names
        { :terms => terms, :free => free,
          :summed => terms.flat_map(&:last).uniq - free, :scale => scale }
      end

      # The product's terms and what multiplies them, or nil where the tree is
      # anything but a product of cells and numbers.
      def product_terms (node, arrays, scalars)
        case node
        when BinaryOperation
          return nil unless node.operator == :*
          left = product_terms(node.left, arrays, scalars)
          right = left && product_terms(node.right, arrays, scalars)
          right && [left.first + right.first, left.last * right.last]
        when ElementRead
          subscripts = node.subscripts
          return nil unless subscripts.all? { |index, offset|
            index && offset.is_a?(Integer) && offset.zero?
          }
          [[[arrays.fetch(node.array), subscripts.map(&:first)]], 1]
        when IntegerLiteral, FloatLiteral
          [[], node.value]
        when CaptureRead
          value = scalars[node.name]
          value.is_a?(Numeric) ? [[], value] : nil
        end
      end

      # @private
      TERM_PREFIX = "term"
      # @private
      TARGET = :target

      # Runs the contraction the terms describe, where a term is an array and
      # the indices it is read at:
      #
      #   CArray::JIT.contract_terms([[a, [:i, :k]], [b, [:k, :j]]],
      #                              free: [:i, :j])            # a matrix product
      #
      # It is `jit_contract` with the block already taken apart -- the same
      # rules, the same errors, the same kernels -- for a caller that has the
      # structure rather than a block to read.  A contraction that was decided
      # rather than written has no source, which is what this is for.
      #
      # `free:` is the result's axes in order, and is required: a structure has
      # no parameter list, so there is nowhere else for the order to be said.
      # Every index that is not named is summed, and must appear at more than
      # one position, exactly as in a block whose axes are named.
      #
      # The terms are a product of element reads and nothing else. A summand
      # that is more than that -- `Math.exp(a[i,k]) * b[k,j]`, a division, a
      # captured scalar, an index with an offset -- is written as a block and
      # compiled by `jit_contract`; there is no structure here that says it.
      #
      # @param terms [Array<Array>] `[array, [index, ...]]` pairs.
      # @param free [Array<Symbol>] the result's axes, in order.
      # @param into [CArray, nil] an array of yours to write into, which then
      #   decides the axis order and is what comes back.
      # @return [CArray] `into` when it is given, otherwise a new array.
      # @raise [CArray::JIT::Unsupported] when the terms are malformed, or the
      #   contraction they describe is one the compiler refuses.
      def contract_terms (terms, free:, into: nil)
        names = check_terms(terms)
        indices = terms.flat_map { |_, subscripts| subscripts }
        free = check_free_indices(free, indices)
        arrays = names.zip(terms.map(&:first)).to_h

        factors = terms.each_with_index.map { |(_, subscripts), position|
          "#{names[position]}[#{subscripts.join(',')}]"
        }
        body = factors.join(" * ")
        if into
          check_destination(into, free)
          arrays[TARGET] = into
          # With every index summed the result is one number, which lives in a
          # one-cell array at a fixed subscript -- as it is written in a block.
          body = "#{TARGET}[#{free.empty? ? '0' : free.join(',')}] = #{body}"
        end
        summed = indices.uniq - free
        parameters = summed.empty? ? "" : "|#{summed.join(', ')}| "

        # The source the block would have had.  It is what the kernel cache is
        # keyed by, so the same terms under the same shapes reach the same
        # kernel however they were arrived at -- and the string is canonical,
        # which is the same service einsum's subscripts perform.
        result = contract("proc { #{parameters}#{body} }", arrays, free)
        into || result
      end

      # The names the synthesized source gives the terms.  They are the
      # source's own, so nothing outside chose them -- but an index may
      # collide with one, and a collision would silently read an array as an
      # index.
      def check_terms (terms)
        unless terms.is_a?(Array) && !terms.empty?
          raise Unsupported,
                "contract_terms takes the terms of a product, as in " \
                "`[[a, [:i, :k]], [b, [:k, :j]]]`"
        end
        terms.each do |term|
          unless term.is_a?(Array) && term.size == 2 && term.first.is_a?(CArray)
            raise Unsupported,
                  "a term is an array and the indices it is read at, as in " \
                  "`[a, [:i, :k]]`; got #{term.inspect}"
          end
          array, subscripts = term
          unless subscripts.is_a?(Array) && subscripts.all? { |name| index_name?(name) }
            raise Unsupported,
                  "the indices of a term are symbols naming its axes, as in " \
                  "`[a, [:i, :k]]`; got #{subscripts.inspect}"
          end
          unless subscripts.size == array.rank
            raise Unsupported,
                  "a term names one index per axis: this array has rank " \
                  "#{array.rank} and #{subscripts.size} " \
                  "#{subscripts.size == 1 ? 'index' : 'indices'} were given"
          end
        end
        names = terms.each_index.map { |position| :"#{TERM_PREFIX}#{position}" }
        reserved = (names + [TARGET]) & terms.flat_map { |_, subscripts| subscripts }
        unless reserved.empty?
          raise Unsupported,
                "#{reserved.map { |name| "`#{name}`" }.join(', ')} names a term " \
                "here and cannot also be an index"
        end
        names
      end

      def check_free_indices (free, indices)
        unless free.is_a?(Array) && free.all? { |name| index_name?(name) }
          raise Unsupported,
                "`free:` is the result's axes in order, named as symbols"
        end
        repeated = free.tally.select { |_, count| count > 1 }.keys
        unless repeated.empty?
          raise Unsupported,
                "#{repeated.map { |name| "`#{name}`" }.join(', ')} names more " \
                "than one axis of the result; each axis is one index"
        end
        missing = free - indices
        unless missing.empty?
          raise Unsupported,
                "#{missing.map { |name| "`#{name}`" }.join(', ')} " \
                "#{missing.size == 1 ? 'names no axis' : 'name no axis'} here"
        end
        free
      end

      def check_destination (into, free)
        unless into.is_a?(CArray)
          raise Unsupported, "`into:` is an array to write into"
        end
        expected = free.empty? ? 1 : free.size
        unless into.rank == expected
          raise Unsupported,
                "`into:` has rank #{into.rank}, and the result's axes are " \
                "#{free.empty? ? 'none, which is one cell' : free.map { |name| "`#{name}`" }.join(', ')}"
        end
      end

      # An index is interpolated into the source this writes, so it has to be
      # a name Ruby reads back as a local variable.  `:end` and `:do` would
      # not parse at all, and `:nil` and `:self` would come back as something
      # else -- all of them as an error about a source the caller never wrote.
      def index_name? (name)
        return false unless name.is_a?(Symbol)
        text = name.to_s
        return false unless text.match?(/\A[a-z_][A-Za-z0-9_]*\z/)
        parsed = Prism.parse("#{text} = 1")
        parsed.errors.empty? &&
          parsed.value.statements.body.first.is_a?(Prism::LocalVariableWriteNode)
      end

      # What a contraction is once its block has been read: a source, the
      # arrays that source names, and which indices are free.  Everything
      # before this is about recovering those from a block; everything after
      # is the same whatever recovered them, which is what lets
      # `contract_terms` reach it with a source it wrote itself.
      def contract (source, arrays, free_indices,
                    node: nil, origin: nil, scalars: {}, c_functions: {})
        result = allocate_result(source, node, arrays, scalars, free_indices)
        arrays = arrays.merge(RESULT => result) if result

        kernel = compile(source,
                         node: node,
                         origin: origin,
                         array_names: arrays.keys,
                         storage_types: arrays.transform_values(&:data_type_name),
                         scalar_values: scalars,
                         c_functions: c_functions,
                         masked: arrays.each_value.any? { |array| array.has_mask? },
                         contract: true,
                         result: RESULT,
                         # A contraction sums an index; which order it sums it
                         # in is not something the caller wrote, so splitting
                         # the sum into partial ones does not change what the
                         # contraction means.  Same licence `jit_for` takes.
                         reassociate: JIT.reassociate,
                         free_indices: free_indices,
                         cell_names: cell_names(arrays))

        refuse_aliased_result(kernel, arrays)
        extents = contraction_extents(kernel, arrays)
        if kernel.masked
          kernel.written_arrays.each do |name|
            array = arrays.fetch(name)
            array.mask = 0 unless array.has_mask?
          end
        end
        kernel.call(arrays, scalars, extents, c_functions)
        result || kernel
      end

      # An array a contraction writes and also reads is a recurrence, which
      # the analyzer refuses -- but it compares the names a block gave them,
      # and two names may be one array.  `x = a` is one, and so is a view of
      # something being read: cells reached before the write see the old value
      # and cells reached after see the new one, so the answer depends on the
      # order and is not the contraction that was asked for.
      #
      # This is where the arrays themselves are known, so it is where the
      # question can be asked of them rather than of their names.  Views are
      # followed to what they are views of, since that is the memory two names
      # would share.
      def refuse_aliased_result (kernel, arrays)
        kernel.written_arrays.each do |written|
          target = root_of(arrays.fetch(written))
          arrays.each do |name, array|
            next if name == written
            next unless root_of(array).equal?(target)
            raise Unsupported,
                  "`#{written}` and `#{name}` are the same array, which this " \
                  "both writes and reads; that is a recurrence rather than a " \
                  "contraction, and is written with jit_for"
          end
        end
      end

      def root_of (array)
        array.respond_to?(:root_array) ? array.root_array : array
      end

      # A contraction with nothing to assign into needs its result sized and
      # typed before there is a kernel to ask, so the block is analyzed once
      # without being compiled.  Returns nil when the block assigns into an
      # array of its own.
      def allocate_result (source, node, arrays, scalars, free_indices = nil)
        probe = probe_contraction(source, node, arrays, scalars, free_indices)
        return nil unless probe
        free, index_axes, type = probe
        shape = free.map do |index|
          extents = index_axes.fetch(index).map { |array, axis|
            [arrays.fetch(array).dim[axis], array, axis]
          }
          distinct = extents.map(&:first).uniq
          if distinct.size > 1
            described = extents.map { |extent, array, axis|
              "`#{array}` axis #{axis} is #{extent}"
            }.join(", ")
            raise Unsupported,
                  "`#{index}` addresses axes of different extents: #{described}"
          end
          distinct.first
        end
        CArray.send(type, *(shape.empty? ? [1] : shape))
      end

      # @private
      def probe_contraction (source, node, arrays, scalars, free_indices = nil)
        key = [source, arrays.transform_values(&:data_type_name),
               scalars.transform_values { |value| TypeAssignment.scalar_type(value) },
               # The result's axes are named at the call site rather than in
               # the block, so the same source under another naming is another
               # kernel -- and another probe.
               free_indices,
               cell_names(arrays)]
        cached = probe_cache[key]
        return cached unless cached.nil?
        probe_cache[key] = build_probe(source, node, arrays, scalars, free_indices)
      end

      # @private
      def probe_cache
        @probe_cache ||= {}
      end

      # @private
      def build_probe (source, node, arrays, scalars, free_indices = nil)
        storage_types = arrays.transform_values(&:data_type_name)
        analyzer = Analyzer.new(source, node: node, array_names: arrays.keys,
                                contract: :probe, free_indices: free_indices,
                                cell_names: cell_names(arrays))
        return false if analyzer.body.statements.last.is_a?(ElementWrite)

        TypeAssignment.new(analyzer.body, storage_types, scalars)
        summand = analyzer.body.statements.last
        axes = Hash.new { |hash, key| hash[key] = [] }
        analyzer.subscripts.each do |array, uses|
          uses.each do |per_axis|
            per_axis.each_with_index do |(index, _), axis|
              axes[index] << [array, axis] if index
            end
          end
        end
        # The type the value was computed in decides the array it is collected
        # into, and that table lives with the computation types rather than
        # here -- a copy kept at the allocation site answers after a type is
        # added, and answers wrongly.  This one did: float32 and cmplx64 fell
        # through its default and a float contraction came back int64.
        [analyzer.probe_free_names, axes,
         TypeAssignment.result_storage_type(summand.type)]
      end

      # Each index's extent comes from the axes it addresses.  Where it
      # addresses more than one and they differ, the contraction has no shape
      # and says which axes disagreed.
      def contraction_extents (kernel, arrays)
        order = kernel.index_names + kernel.contracted_names
        order.map do |index|
          places = kernel.index_axes[index]
          extents = places.map { |array, axis| [arrays.fetch(array).dim[axis], array, axis] }
          distinct = extents.map(&:first).uniq
          if distinct.size > 1
            described = extents.map { |extent, array, axis|
              "`#{array}` axis #{axis} is #{extent}"
            }.join(", ")
            raise Unsupported,
                  "`#{index}` addresses axes of different extents: #{described}"
          end
          [0, distinct.first, 1]
        end
      end

      # @private
      MAP_RESULT = :__map_result

      # Whether CArray's sweep can run this pass, decided before there is a
      # kernel -- because the answer changes what is compiled.
      #
      # A chunk is one flat run of cells, and CArray already treats an operand
      # as one: its acquire reads `elements` and the element size and never
      # looks at the shape.  So the arrays do not have to be flattened, and
      # are not; what has to be flat is the *kernel*, which is compiled at
      # rank one over the same cells rather than as a nest over the axes.
      #
      # The one thing that cannot be flattened is a stretched operand.
      # Broadcasting arrives as a stride of zero on an axis, and an axis is
      # what a flat run has none of -- so cell k of the output would stop
      # lining up with cell k of the stretched operand.  Hence the test is
      # that every operand already has the shape the pass covers, which is
      # stricter than agreeing on the count of cells.
      def sweepable_pass? (arrays, shape, masked)
        return false unless Sweep.available?
        return false if masked
        return false if arrays.empty? || arrays.size > Sweep::MAX_ARITY
        return false unless arrays.each_value.all? { |array|
          array.rank.zero? || array.dim == shape
        }
        walkable_in_place?(arrays.each_value)
      end

      # Whether the operands settle the question the shape leaves open.
      #
      # The sweep re-gathers what it cannot walk in place, 32KB at a time,
      # and that is a bargain against materialising the same operand whole --
      # but only where the tiers here would have to materialise it.  So the
      # tier each operand would be opened at is the rest of the decision:
      #
      #   TIER_ATTACH  neither can walk it, and the sweep holds 32KB where
      #                the tiers hold the whole box: the sweep runs
      #   TIER_STRIDE  a column, a transpose, every other cell -- the tiers
      #                address it in place, and the sweep re-gathers it for
      #                nothing: the driver stays here
      #   TIER_ENTITY  both walk the buffer, and the two are
      #                indistinguishable: the sweep runs, as it always did
      #
      # Measured over two million doubles with a strided view as the operand:
      # 0.9 ns/cell with the driver here against 6.1 ns/cell swept, and no
      # scratch either way -- there was nothing the re-gather was buying.
      def walkable_in_place? (arrays)
        tiers = arrays.map { |array| Access.classify(array)[:tier] }
        return true if tiers.include?(Access::TIER_ATTACH)
        tiers.none? { |tier| tier == Access::TIER_STRIDE }
      end

      # Which loop runs it.  Both compute the same thing from the same
      # compiled body -- what differs is who acquires the operands.
      #
      # CArray's chunked sweep re-gathers an operand it cannot walk in place
      # 32KB at a time, where the tiers here move the whole box the kernel
      # touches, and for an element-wise pass that box is the whole array.
      # Measured over two million doubles with a gather view as an operand:
      # 1.3 ms either way, and 32KB of scratch against sixteen megabytes.
      # With an entity operand the two are indistinguishable, so there is
      # nothing to weigh.  With a strided view there is: the tiers address it
      # in place and the sweep re-gathers it, which is why #sweepable_pass?
      # asks what tier each operand would be opened at and not only what
      # shape it has.
      #
      # It cannot always.  A body that asks about a mask has no per-cell mask
      # in a chunk to ask it of; operands that disagree on their element count
      # are broadcast here and refused there; and a kernel of rank two or more
      # addresses its operands by axis, which one flat run of cells cannot
      # supply.
      def drive (kernel, aligned, scalars, c_functions, shape, sweeping)
        if sweeping
          kernel.sweep(aligned, scalars, c_functions)
        else
          kernel.call(aligned, scalars, shape.map { |extent| [0, extent, 1] },
                      c_functions)
        end
      end

      # What the frame gets.  Two kinds: `:mask` and `:skip` are answers about
      # the frame cells themselves -- mark them, or leave them -- and nothing
      # is computed for a cell that was not computed.  The other three say
      # what a read outside the array gives, so the frame is computed after
      # all, by a second walk with that rule written into its reads.
      FRAME_BORDERS = [:mask, :skip].freeze
      # @private
      COMPUTED_BORDERS = [:zero, :clamp, :wrap].freeze

      # @private
      def run_stencil (arrays, block, border, type, into)
        unless FRAME_BORDERS.include?(border) || COMPUTED_BORDERS.include?(border)
          raise Unsupported,
                "`border:` is " \
                "#{(FRAME_BORDERS + COMPUTED_BORDERS).map(&:inspect).join(', ')}, " \
                "got #{border.inspect}"
        end
        if type && into
          raise Unsupported,
                "`into:` names an array, which already says what type it is; " \
                "pass one or the other"
        end

        node, source, origin = read_block(block)
        windows = block.parameters.map(&:last)
        unless windows.size == arrays.size
          raise Unsupported,
                "the block takes #{windows.size} " \
                "#{windows.size == 1 ? 'window' : 'windows'}, and " \
                "#{arrays.size} #{arrays.size == 1 ? 'array was' : 'arrays were'} " \
                "given"
        end
        arrays.each_with_index do |array, position|
          unless array.is_a?(CArray)
            raise Unsupported,
                  "jit_stencil takes arrays; `#{windows[position]}` was given " \
                  "#{array.class}"
          end
        end
        shape = arrays.first.dim
        arrays.each_with_index do |array, position|
          next if array.dim == shape
          # Shapes are required to agree rather than broadcast: a stretched
          # axis has no neighbour to reach, so what a window would mean on one
          # is a question this does not have to answer yet.
          raise Unsupported,
                "`#{windows.first}` has shape #{shape.inspect} and " \
                "`#{windows[position]}` #{array.dim.inspect}; a stencil's " \
                "arrays have the same shape"
        end

        windowed = windows.zip(arrays).to_h
        free, assigned = free_and_assigned_names(source, node)
        captured, scalars, c_functions, randoms =
          split_captures(free - windows, binding_of(block))
        refuse_a_generator(randoms, "a stencil", "its border is a second loop " \
          "over the frame, so the draws would not run in one pass over the " \
          "cells")
        unless assigned.empty? || (assigned & captured.keys).empty?
          raise Unsupported,
                "a stencil's value is its block's, and the cells it is over " \
                "are windows; an array it writes belongs to `jit_each`"
        end
        given = windowed.merge(captured)

        result = stencil_result(source, node, given, scalars, c_functions,
                                windows, shape, type, into)
        # `:mask` does not make this a masked kernel.  The frame is marked
        # before the loop runs and the loop never reaches it, so what the
        # kernel is asked to carry is what the operands carry -- and a masked
        # kernel reads and ORs a mask byte per cell, which the interior of an
        # unmasked stencil has no reason to pay for.
        masked = given.each_value.any? { |array| array.has_mask? } ||
                 mentions_undef(source, node)
        kernel = compile(source,
                         node: node,
                         origin: origin,
                         array_names: given.keys + [MAP_RESULT],
                         storage_types: given.merge(MAP_RESULT => result)
                                             .transform_values(&:data_type_name),
                         scalar_values: scalars,
                         c_functions: c_functions,
                         masked: masked,
                         rank: shape.size,
                         windows: windows,
                         border: COMPUTED_BORDERS.include?(border) ? border : nil,
                         map: true,
                         result: MAP_RESULT)

        # The interior is where every window is inside the array; the frame is
        # what is left, and what `border:` answers for.
        reach = kernel.window_reach
        bounds = shape.each_with_index.map { |extent, axis|
          low, high = reach[axis]
          [-low, extent - high, 1]
        }
        if bounds.any? { |from, to, _| from >= to }
          raise Unsupported,
                "the window reaches #{reach.inspect} and the arrays are " \
                "#{shape.inspect}, so there is no cell where the window is " \
                "inside the array"
        end
        # Writing into an array a window reads is not a pass over the array:
        # a cell written here is a neighbour a later cell reads, so what comes
        # back depends on the order the cells were reached in.  The question
        # is about that window alone -- a window that reaches nowhere reads
        # only the cell the loop is on, and may be written in place however
        # far the other windows in the same kernel reach.
        if into
          aliased = given.find { |name, array|
            next false unless root_of(array).equal?(root_of(into))
            kernel.window_reaches[name].any? { |low, high|
              !low.zero? || !high.zero?
            }
          }
          if aliased
            raise Unsupported,
                  "`into:` is the array `#{aliased.first}` reaches its window " \
                  "into, and a cell written there is one a later cell reads; " \
                  "a stencil writes into an array of its own"
          end
        end
        result.mask = 0 if (kernel.masked || border == :mask) && !result.has_mask?
        mark_frame(result, bounds, shape) if border == :mask
        operands = given.merge(MAP_RESULT => result)
        kernel.call(operands, scalars, bounds, c_functions)
        if COMPUTED_BORDERS.include?(border)
          frame_boxes(bounds, shape).each do |box|
            kernel.call(operands, scalars, box, c_functions, border: true)
          end
        end
        result
      end

      # The frame, cut into boxes the loop can walk.  Peeling one axis at a
      # time and taking the interior of the axes already peeled is what keeps
      # them from overlapping: a cell in two of them would be computed twice,
      # and a stencil that wrote a cell twice would be a different thing
      # depending on which write landed last.
      #
      # Two boxes per axis, so 2 * rank of them however wide the window is --
      # the corners come with the axis peeled first rather than being cases of
      # their own.
      def frame_boxes (bounds, shape)
        boxes = []
        shape.each_index do |axis|
          from, to, = bounds[axis]
          [[0, from], [to, shape[axis]]].each do |low, high|
            next if low >= high
            box = shape.each_index.map { |other|
              if other == axis then [low, high, 1]
              elsif other < axis then bounds[other]
              else [0, shape[other], 1]
              end
            }
            boxes << box
          end
        end
        boxes
      end

      # A frame cell is one the loop does not write, so `:mask` marks it
      # before the loop rather than during it: what says "not computed" is a
      # mask byte, and the cells are named by the same bounds the loop is
      # given.  This is the whole of `:mask` -- there is nothing to compute
      # for a cell that was not computed.
      def mark_frame (result, bounds, shape)
        shape.each_with_index do |extent, axis|
          from, to, = bounds[axis]
          [(0...from), (to...extent)].each do |span|
            next if span.size.zero?
            index = Array.new(shape.size) { nil }
            index[axis] = span
            result[*index] = UNDEF
          end
        end
      end

      # Typed from the block's value, as jit_map's result is, unless the
      # caller said otherwise.  `into:` is checked against the shape here
      # rather than by the kernel, so that a wrong array is refused before
      # anything is compiled for it.
      def stencil_result (source, node, arrays, scalars, c_functions, windows,
                          shape, type, into)
        if into
          unless into.is_a?(CArray) && into.dim == shape
            raise Unsupported,
                  "`into:` takes an array of the stencil's own shape " \
                  "#{shape.inspect}"
          end
          return into
        end
        chosen = type || probe_stencil(source, node, arrays, scalars,
                                       c_functions, windows, shape)
        CArray.send(chosen, *shape)
      end

      # @private
      def probe_stencil (source, node, arrays, scalars, c_functions, windows,
                         shape)
        key = [:stencil, source, arrays.transform_values(&:data_type_name),
               scalars.transform_values { |value| TypeAssignment.scalar_type(value) },
               c_functions.transform_values(&:signature), shape.size]
        cached = probe_cache[key]
        return cached if cached
        analyzer = Analyzer.new(source, node: node, array_names: arrays.keys,
                                c_functions: c_functions, rank: shape.size,
                                windows: windows, map: :probe)
        TypeAssignment.new(analyzer.body, arrays.transform_values(&:data_type_name),
                           scalars, c_functions)
        probe_cache[key] =
          TypeAssignment.result_storage_type(analyzer.body.statements.last.type)
      end

      # The result has to be sized and typed before there is a kernel to ask,
      # so the block is analyzed once without being compiled -- the same thing
      # a returned contraction does, for the same reason.
      def allocate_map_result (source, node, arrays, scalars, shape, c_functions,
                               randoms = {})
        type = probe_map(source, node, arrays, scalars, c_functions, randoms)
        CArray.send(type, *(shape.empty? ? [1] : shape))
      end

      # @private
      def probe_map (source, node, arrays, scalars, c_functions, randoms = {})
        key = [:map, source, arrays.transform_values(&:data_type_name),
               scalars.transform_values { |value| TypeAssignment.scalar_type(value) },
               c_functions.transform_values(&:signature),
               randoms.transform_values(&:generator)]
        cached = probe_cache[key]
        return cached if cached
        analyzer = Analyzer.new(source, node: node, array_names: arrays.keys,
                                c_functions: c_functions, rank: 1, map: :probe,
                                randoms: random_state_names(randoms))
        TypeAssignment.new(analyzer.body, arrays.transform_values(&:data_type_name),
                           scalars, c_functions)
        value = analyzer.body.statements.last
        probe_cache[key] = TypeAssignment.result_storage_type(value.type)
      end

      # @private
      def run_over_whole_arrays (block, map: false)
        node, source, origin = read_block(block)
        free, assigned = free_and_assigned_names(source, node)
        arrays, scalars, c_functions, randoms =
          split_captures(free, binding_of(block))
        # `out = a + b` writes the array named `out` where the block was
        # written.  A name the block assigns is not free in it, so it is
        # looked up here rather than by split_captures -- and a name that is
        # not an array outside stays what it looks like, a local.
        arrays = arrays.merge(assigned_arrays(assigned, binding_of(block)))
        if arrays.empty?
          raise Unsupported, "the block reaches no array"
        end

        aligned, shape = broadcast(arrays)
        # A generator's state joins after the broadcast, never before it.
        # It is passed whole rather than walked, so the expression's shape
        # has nothing to say about it -- and it has a shape of its own that
        # would not line up anyway: four cells, against however many the
        # expression covers.  Lining it up first is what `jit_each` did to a
        # one-cell state before 314d6cb, and a four-cell one does not even
        # stretch.
        states = random_states(randoms)
        arrays = arrays.merge(states)
        aligned = aligned.merge(states)
        if map
          result = allocate_map_result(source, node, arrays, scalars, shape,
                                       c_functions, randoms)
          arrays = arrays.merge(MAP_RESULT => result)
          aligned = aligned.merge(MAP_RESULT => result)
        end
        masked = arrays.each_value.any? { |array| array.has_mask? } ||
                 mentions_undef(source, node)
        sweeping = sweepable_pass?(arrays, shape, masked)
        kernel = compile(source,
                         node: node,
                         origin: origin,
                         array_names: arrays.keys,
                         storage_types: arrays.transform_values(&:data_type_name),
                         scalar_values: scalars,
                         c_functions: c_functions,
                         randoms: randoms,
                         masked: masked,
                         rank: sweeping ? 1 : shape.size,
                         map: map,
                         result: map ? MAP_RESULT : nil)

        kernel.written_arrays.each do |name|
          next if name == MAP_RESULT
          written = arrays.fetch(name)
          unless written.dim == shape
            raise Unsupported,
                  "`#{name}` has shape #{written.dim.inspect}, but the " \
                  "expression covers #{shape.inspect}; a stretched array " \
                  "cannot be written to"
          end
          aligned[name] = written
        end

        # An array handed to a C function by address is passed whole rather
        # than walked, so the expression's shape has nothing to say about it.
        # Broadcasting it would stretch a one-cell state array into a
        # read-only `CARepeat`, which the copy-back after the call cannot
        # write through -- and a state array is exactly the shape a caller
        # reaches for.
        kernel.address_arrays.each do |name|
          aligned[name] = arrays.fetch(name)
        end

        if kernel.masked
          kernel.written_arrays.each do |name|
            array = arrays.fetch(name)
            array.mask = 0 unless array.has_mask?
          end
        end

        result.mask = 0 if map && kernel.masked && !result.has_mask?
        drive(kernel, aligned, scalars, c_functions, shape, sweeping)
        map ? result : kernel
      end

      # CArray lines the shapes up; a stretched axis comes back as a stride of
      # zero, which the kernel addresses like any other stride.
      # CArray leaves a CScalar as it is, because its own kernels know to read
      # one cell of it for every cell of everything else.  This loop does not
      # know that -- it addresses what it is handed -- so the CScalar is first
      # referred to as the one-cell array it already is, and comes back from
      # the broadcast as the stretched view a one-cell CArray comes back as.
      # The referred view is the same memory, so a write still lands.
      #
      # One axis per axis of what it is standing beside, rather than the one
      # axis it would have had on its own: `CArray.broadcast` stretches a
      # size-1 axis but does not invent an axis that is missing, so `[1]`
      # against a `[2, 3]` is an ndim mismatch rather than a scalar.  A
      # CScalar has no shape of its own to contradict this -- being shapeless
      # is what it is for -- so it takes the rank of the operands that do,
      # and stretches on every axis, which is what CArray's own operators
      # give for the same expression.
      def broadcast (arrays)
        values = arrays.values
        rank = values.reject { |value| value.is_a?(CScalar) }
                     .map(&:rank).max || 1
        values = values.map { |value|
          value.is_a?(CScalar) ? value.refer(value.data_type, [1] * rank) : value
        }
        aligned = values.size == 1 ? values : CArray.broadcast(*values)
        [arrays.keys.zip(aligned).to_h, aligned.first.dim]
      end

      # An indexed kernel addresses what it is handed, so a CScalar among the
      # captures is named here rather than stretched: it has no axis to walk,
      # and the block says so by writing no index for it.  The whole-array
      # spellings have no such name to write, and broadcast instead.
      def cell_names (arrays)
        arrays.select { |_, value| value.is_a?(CScalar) }.keys
      end

      # @private
      def binding_of (block)
        block.binding
      end

      # @private
      def run (extents, block, reassociate = nil)
        node, source, origin = read_block(block)
        names = capture_names(source, node)
        arrays, scalars, c_functions, randoms =
          split_captures(names, binding_of(block))
        # A generator's state is an operand like any other array, under a
        # name this compiler made up.  `jit_for` lines nothing up, so it can
        # simply join the rest.
        arrays = arrays.merge(random_states(randoms))

        # A plain CArray carries no mask; one exists only once a cell has
        # actually been marked.  So masks are touched at all only when some
        # array already has one -- and then the arrays being written need one
        # too, which is what CArray's own operators do.
        if extents.empty?
          count = block.arity
          raise Unsupported,
                "this block names #{count == 1 ? 'an index' : "#{count} indices"}, " \
                "so it needs #{count == 1 ? 'an extent' : 'one extent each'}; " \
                "pass a Range, a count or `(high - 1).step(low, -1)`, or drop " \
                "the #{count == 1 ? 'index' : 'indices'} and write the arrays " \
                "whole as `a[]`"
        end
        pairs = bounds(extents, extents.size)
        steps = pairs.map { |triple, _| triple[2] }

        kernel = compile(source,
                         node: node,
                         origin: origin,
                         array_names: arrays.keys,
                         storage_types: arrays.transform_values(&:data_type_name),
                         scalar_values: scalars,
                         c_functions: c_functions,
                         randoms: randoms,
                         masked: arrays.each_value.any? { |array| array.has_mask? },
                         steps: steps,
                         cell_names: cell_names(arrays),
                         reassociate: reassociate.nil? ? JIT.reassociate : reassociate)
        # The kernel decides, not the caller: mentioning UNDEF makes it a
        # masked kernel even when no array carries a mask yet.
        if kernel.masked
          kernel.written_arrays.each do |name|
            array = arrays.fetch(name)
            array.mask = 0 unless array.has_mask?
          end
        end
        unless pairs.size == kernel.rank
          raise Unsupported,
                "the block names #{kernel.rank} " \
                "#{kernel.rank == 1 ? 'index' : 'indices'}, and " \
                "#{pairs.size} #{pairs.size == 1 ? 'extent was' : 'extents were'} " \
                "given"
        end
        kernel.call(arrays, scalars, pairs.map(&:first), c_functions)
        kernel
      end

      # Compiles for one set of array data types and one set of scalar types,
      # and returns the same CompiledKernel for every later call with the
      # same ones.  Nothing on this path is cheap relative to running the
      # kernel, so all of it is memoized.
      def compile (source, node: nil, origin: nil, array_names:, storage_types:,
                   scalar_values:, c_functions: {}, masked: false, rank: nil,
                   steps: nil, contract: false, result: nil, map: false,
                   reassociate: false, cell_names: [], windows: [], border: nil,
                   free_indices: nil, randoms: {})
        # A kernel that mentions UNDEF is a masked one whatever its arrays
        # carry, and deciding that here means no caller has to remember it.
        masked ||= mentions_undef(source, node)
        key = [source, storage_types,
               scalar_values.transform_values { |value|
                 TypeAssignment.scalar_type(value)
               },
               # The signature, not the address: `j0` and `y0` are the same
               # kernel, and it is compiled once.  One written here adds its
               # symbol, which stands for its body -- see `CFunction#kernel_key`.
               c_functions.transform_values(&:kernel_key),
               # Which generator each name is, and nothing about its state:
               # the C pasted for a draw is decided by the kind, and the seed
               # is data the kernel is handed at the call.  So two runs that
               # differ only in seed are one kernel, and the same kernel
               # serves a generator reset between calls.
               randoms.transform_values(&:generator),
               masked, rank, steps, contract, result, map,
               # A contraction whose free indices were named is not the kernel
               # the same source is without them, nor with them in another
               # order: the naming decides what is summed and what comes out.
               free_indices,
               # Which names are read at their one cell rather than walked:
               # the same source over a CScalar is a different kernel from
               # the same source over a one-cell CArray.
               cell_names,
               # Which names are windows: the same source read as a stencil is
               # not the same kernel as the same source read as a block that
               # named its indices.
               windows,
               # And what a window that falls off the array reads: the rule is
               # emitted into the frame's body, so two rules are two kernels.
               border,
               # The licence is part of the kernel, not of the call: it
               # decides what C is emitted, so the two spellings are two
               # kernels and the cache keeps them apart.
               reassociate]
        found = registry[key]
        return found if found
        registry[key] = build(source, node, array_names, storage_types,
                              scalar_values, c_functions, masked, rank, steps,
                              contract, result, origin, map, reassociate,
                              cell_names, windows, border, free_indices,
                              randoms)
      end

      # A kernel that mentions UNDEF is a masked kernel whatever its arrays
      # happen to carry: it asks about masks, or makes them.  Checked here
      # because the answer is needed before the kernel is built.
      def mentions_undef (source, node = nil)
        cached = undef_cache[source]
        return cached unless cached.nil?
        undef_cache[source] = Analyzer.mentions_undef?(source, node: node)
      end

      # @private
      def undef_cache
        @undef_cache ||= {}
      end

      # @private
      def capture_names (source, node = nil)
        free, = free_and_assigned_names(source, node)
        free
      end

      # Which names the block reaches for, and which it assigns.  Both are
      # properties of the source, so both are cached; what each name *is* is
      # a property of the binding, and is settled outside the cache.
      def free_and_assigned_names (source, node = nil)
        cached = capture_name_cache[source]
        return cached if cached
        capture_name_cache[source] =
          Analyzer.free_and_assigned_names(source, node: node)
      end

      # @private
      def registry
        @registry ||= {}
      end

      # @private
      def capture_name_cache
        @capture_name_cache ||= {}
      end

      # Keyed by instruction sequence, which CRuby hands back as the same
      # object for every Proc made from one block literal.  That makes it a
      # free identity for the block, and keeps the file from being read and
      # parsed again on each call.
      def block_cache
        @block_cache ||= {}
      end

      # @!group Kernel cache

      # Forgets the kernels compiled in this process, so that the next call
      # reaches the cache on disk rather than the one held in memory.
      #
      # @return [void]
      def clear_registry
        @registry = {}
        @capture_name_cache = {}
        @block_cache = {}
        @undef_cache = {}
      end

      # @return [String] the directory this environment's kernels are kept in,
      #   named for the versions and architecture they were built for.
      def cache_directory
        Compiler.cache_directory
      end

      # @return [String] the directory holding one entry per environment.
      def cache_root
        Compiler.cache_root
      end

      # Puts this application's kernels somewhere of its own, rather than in
      # the cache shared under the home directory.  Say it before the first
      # kernel is compiled -- at the top of the program, beside the other
      # requires:
      #
      #     CArray::JIT.cache_root = File.expand_path("../.jit-cache", __dir__)
      #
      # Kernels already loaded keep working and what is already on disk stays
      # where it is; this says where the next one is looked for and written.
      # `CARRAY_JIT_CACHE` and `CARRAY_JIT_NO_CACHE` still come first, so
      # whoever runs the program can put the cache somewhere writable or do
      # without one. A directory inside a project wants to be ignored by the
      # version control it sits in.
      #
      # @param path [String, nil] the directory, relative to where the
      #   program starts; `nil` restores the default.
      # @return [void]
      def cache_root= (path)
        Compiler.cache_root = path
      end

      # @return [Array<String>] the environment directories no longer in use --
      #   another version, or another architecture.
      def stale_cache_environments
        Compiler.stale_environments
      end

      # @return [Integer] the number of kernels this environment has cached.
      def cache_entry_count
        Compiler.entry_count
      end

      # @return [Integer] the bytes this environment's cache holds.
      def cache_byte_size
        Compiler.byte_size
      end

      # Removes cached kernels.
      #
      # @param everything [Boolean] `true` to clear every environment, not
      #   only this one.
      # @return [Integer] the number of entries removed.
      def clear_cache (everything: false)
        Compiler.clear(:everything => everything)
      end

      # @!endgroup

      private

      def build (source, node, array_names, storage_types, scalar_values, c_functions,
                 masked, rank = nil, steps = nil, contract = false, result = nil,
                 origin = nil, map = false, reassociate = false,
                 cell_names = [], windows = [], border = nil, free_indices = nil,
                 randoms = {})
        analyzer = Analyzer.new(source, node: node, array_names: array_names,
                                c_functions: c_functions,
                                rank: rank, steps: steps, contract: contract,
                                result: result, map: map, free_indices: free_indices,
                                cell_names: cell_names, windows: windows,
                                randoms: random_state_names(randoms))
        assignment = TypeAssignment.new(analyzer.body, storage_types,
                                        scalar_values, c_functions)
        generator = CGenerator.new(analyzer, storage_types, assignment.scalar_types,
                                   c_functions: c_functions,
                                   randoms: randoms,
                                   masked: masked, reassociate: reassociate,
                                   steps: steps, border: border,
                                   origin: origin, block_source: source)
        CompiledKernel.new(source: source, generator: generator,
                           analyzer: analyzer, storage_types: storage_types)
      end

      # Recovering a block's source means parsing the whole file it lives in,
      # which is far too expensive to repeat per call.
      def read_block (block)
        sequence = RubyVM::InstructionSequence.of(block) if
          defined?(RubyVM::InstructionSequence)
        return BlockReader.read(block) unless sequence
        cached = block_cache[sequence]
        return cached if cached
        block_cache[sequence] = BlockReader.read(block)
      end

      # What a block closes over is one of three things, and which it is
      # decides what the name means inside the kernel: an array is addressed
      # at a cell, a scalar is a constant the kernel is compiled with, and a
      # C function is something it calls.
      # Of the names the block assigns, the ones that are arrays where it was
      # written.  Anything else -- a name that holds a number, or no name at
      # all -- is a local of the block's own.
      def assigned_arrays (names, binding)
        names.each_with_object({}) do |name, found|
          next unless binding.local_variable_defined?(name)
          value = binding.local_variable_get(name)
          found[name] = value if value.is_a?(CArray)
        end
      end

      def split_captures (names, binding)
        arrays = {}
        scalars = {}
        c_functions = {}
        randoms = {}
        names.each do |name|
          value = capture_value(name, binding)
          case value
          when CArray then arrays[name] = value
          when CFunction  then c_functions[name] = value
          when CArray::Rng then randoms[name] = value
          else             scalars[name] = value
          end
        end
        [arrays, scalars, c_functions, randoms]
      end

      # The name a generator's state array is an operand under.
      #
      # Made up here rather than taken from the caller, because the state is
      # not something the block named: it wrote `r.call`, and the array
      # behind that is machinery.  The name is derived from the one the block
      # did write, so it is the same in the next process as in this one --
      # which is what lets a compiled kernel be found in the cache rather
      # than built again.
      def random_state_name (name)
        :"__random_state_#{name}"
      end

      # Which state array each generator draws from, as operands.
      def random_states (randoms)
        randoms.to_h { |name, generator|
          [random_state_name(name), generator.state]
        }
      end

      # Which made-up name each generator's state is under, for the analyzer.
      def random_state_names (randoms)
        randoms.to_h { |name, _| [name, random_state_name(name)] }
      end

      # A constant is looked up where the block was written, so it means what
      # it means there -- the enclosing module's, not the top level's.  It is
      # the only name a method body can reach: `def` closes over nothing, so
      # a compiled function or a table held in a constant is how a method
      # gets at one.
      def capture_value (name, binding)
        if name.to_s.start_with?(/[A-Z]/)
          begin
            binding.eval(name.to_s)
          rescue NameError
            raise Unsupported,
                  "`#{name}` is not defined where the block was written"
          end
        else
          unless binding.local_variable_defined?(name)
            refuse_a_draw(name)
            raise Unsupported,
                  "`#{name}` is not defined where the block was written"
          end
          binding.local_variable_get(name)
        end
      end

      # `rand` is Kernel's, so "not defined" would be a lie, and the reason it
      # is not here is worth saying where it is reached for.
      DRAW_NAMES = [:rand, :srand].freeze

      def refuse_a_draw (name)
        # `random` with no `rng:` is not a name that was left undefined, it is
        # a draw with its generator missing.  It reaches here rather than
        # `random_call` because a bare name with no arguments is parsed as a
        # name read, and only the parentheses tell the two apart.
        if name.to_sym == :random
          raise Unsupported,
                "`random` in a kernel draws from a generator and has to say " \
                "which: `random(rng: r)`, where `r` is a `CArray::Rng` -- " \
                "`CArray.jit_rng(seed: 4)` makes one"
        end
        return unless DRAW_NAMES.include?(name.to_sym)
        raise Unsupported, draw_message("`#{name}`")
      end

      # A generator reaches `jit_for`, `jit_each` and `jit_map`, and stops
      # there.  The two that are left are not refused because a draw is
      # meaningless in them but because it would not mean what it looks like,
      # so the reason is given rather than the fact.
      def refuse_a_generator (randoms, what, because)
        return if randoms.empty?
        name = randoms.keys.first
        raise Unsupported,
              "`#{name}` is a generator, and #{what} does not draw from one: " \
              "#{because}. Fill an array with `CArray#random!` and read a " \
              "cell of it, or draw in a `jit_for` / `jit_each` / `jit_map` " \
              "block, where `random(rng: #{name})` works"
      end

      # `rand` is Ruby's, and Ruby's generator is reached through the VM: the
      # loop runs with the GVL released, which is not where it may be reached
      # at all.  That is why this one is refused, and it is the only reason --
      # a kernel *can* draw, from a generator whose C it can paste, which is
      # what `CArray.jit_rng` hands out.
      #
      # Both ways out are named because they are different answers.  A
      # generator draws in the order it is asked, and a kernel does not fix
      # that order: a stencil's border is a second loop over the frame, and a
      # reduction may split its accumulator.  Where which draw lands in which
      # cell has to be settled -- common random numbers, antithetic variates
      # -- an array filled before the call is the answer, and a draw in the
      # loop is not.  Where it does not, drawing in the kernel saves the
      # array.
      def draw_message (what)
        "#{what} draws from a generator this compiler cannot reach: it is " \
        "Ruby's, and the loop runs without the GVL. Draw from " \
        "`CArray.jit_rng`, which a kernel can; or, where which draw lands " \
        "in which cell matters, fill an array with `CArray#random!` and read " \
        "a cell of it as the kernel reads any other array"
      end

      # An extent is a Range, an Integer standing for `0...n`, or an
      # Enumerator::ArithmeticSequence -- which is what `(hi-1).step(lo, -1)`
      # returns, and how a downward loop is written.
      #
      # Returns the half-open pair per axis, and the direction the extent
      # asked for where it said one.
      def bounds (extents, rank)
        extents.map { |extent| bounds_of(extent) }
      end

      def bounds_of (extent)
        case extent
        when Range
          low = extent.begin || 0
          high = extent.end
          raise Unsupported, "an endless range has no extent" unless high
          [[low, extent.exclude_end? ? high : high + 1, 1], nil]
        when Integer
          [[0, extent, 1], nil]
        when Enumerator::ArithmeticSequence
          arithmetic_bounds(extent)
        else
          raise Unsupported,
                "an extent is a Range, an Integer or an arithmetic sequence, " \
                "got #{extent.class}"
        end
      end

      # A sequence may skip cells.  An offset still means what it means in
      # Ruby -- `a[i-1]` is the cell at index i-1 -- so skipping changes not
      # the reading but the dependencies: with a step of two, index i-1 is a
      # cell this loop never writes.
      def arithmetic_bounds (extent)
        step = extent.step
        raise Unsupported, "an extent's step cannot be zero" if step.zero?
        first = extent.begin
        last = extent.end
        raise Unsupported, "an endless sequence has no extent" if last.nil?
        limit = extent.exclude_end? ? last : last + (step.positive? ? 1 : -1)
        [[first, limit, step], step.positive? ? :ascending : :descending]
      end

      # The direction an extent asked for has to be the one the kernel's own
      # dependencies require -- and where they require one, the extent has to
      # say so, because that is the only place a reader sees it.
    end

  end

end

# ---------------------------------------------------------------------------
#  CArray asks about an expression it is about to compute; this answers.
#
#  Registering here rather than being reached for means a program that only
#  writes `CArray.fuse { ... }` gets the compiled path from having this gem
#  installed, and the same answer without it.
# ---------------------------------------------------------------------------

# The expression front end needs things CArray gained after 3.0.0 -- the
# plan, the kernel bodies as text, the flags they were built with, and
# somewhere to register.  Without them the Prism front end above is the
# whole of this gem, exactly as before.
if CArray.respond_to?(:expression_evaluator) &&
   CArray.respond_to?(:__kernel_body__) &&
   CArray.const_defined?(:BUILD_FLAGS)
  require "carray/jit/expression"
  CArray.expression_evaluator = CArray::JIT::Expression.new
end
