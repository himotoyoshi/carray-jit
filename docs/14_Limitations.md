# Known limitations

- **Integer overflow wraps**, as CArray's own operators wrap. Ruby's Integer
  is arbitrary precision; the generated C uses `int64_t`, so a kernel that
  would grow past 2^63 wraps instead. Float kernels are unaffected.
- **Object arrays are not handled.** `CA_OBJECT` holds Ruby values rather
  than numbers, and reaching into Ruby from inside a kernel would give up
  what compiling it was for.
- **`**` on a Complex is the one place the answer is not bit-for-bit Ruby's.**
  It is within a few machine epsilons, growing with the exponent. What is
  refused on a Complex is what Ruby refuses -- ordering comparisons, `%`,
  the rounding methods, the bit operators. See
  [Complex arrays](12_Types.md#complex-arrays).
- **A sine and a cosine of the same argument are one `sincos` call.** The C
  compiler merges them, and its sine differs from `sin` in the last bit for
  some arguments, where Ruby calls `sin`. Either flag that stops it costs more
  elsewhere than the bit is worth here, so it is documented rather than
  disabled; see [Design notes](17_DesignNotes.md#a-sine-beside-a-cosine-is-sincos-and-is-allowed-to-be).
- **A reduction does not take Ruby's order.** An accumulator is split into
  partial sums by default, which is usually the more accurate answer and is
  not the Ruby loop's; `reassociate: false` asks for that order back.
  `sum(axis:)`, whose kernels are written for the shape, is still faster at
  the reductions it covers.
- **A `while` may fail to return, and nothing can interrupt it.** The loop is
  in the subset now, and the bound that used to be compulsory is not: a
  compiler-invented cap would be a number nobody could choose, since the loops
  whose bound is knowable are already `(0...cap).each` with a `break`.  What
  comes with that is C's bargain, the one a `jit_function` recursing too deep
  already takes.  It bites harder here than it would in Ruby: a generated loop
  has no interrupt check in it, so `Ctrl-C` does not reach a running kernel --
  whether or not it holds the GVL -- and a runaway pass ends with a signal
  from another terminal.  The one case that can be read off the page,
  `while true` with no `break` and no `raise` in it, is refused.
- **`until` is not in the subset.** `while` with the condition negated is the
  same loop, and one spelling of it is enough to keep.
- **An inner loop's range must be a literal `Range`.**
  `Enumerator::ArithmeticSequence` -- `(0...n).step(2)` -- is accepted as an
  *extent* but not as an inner loop.
- **A kernel draws no random numbers.** Generate them outside and pass the
  array in: `noise = CArray.double(n).random!` and then `a[i] + noise[i]`,
  which is a captured array like any other. There is no `rand` in the subset,
  and the reason is the same one that makes it easy to work around. A
  generator has one state and hands out its numbers in the order it was
  asked, and this compiler does not fix the order it asks in: a stencil's
  border is a second loop over the frame, a reduction may split its
  accumulator, and a kernel runs with the GVL released, which is not where
  Ruby's own `Random` -- the one `CArray#random!` calls through -- may be
  reached at all. An array filled before the call has none of those
  questions: it was drawn in one order, by Ruby's generator, and the kernel
  reads a cell of it like any other cell.
- **An operand that is not an entity is transferred before the loop.** A
  kernel walks memory, so an array that is not one -- a view that does not
  fold to an entity, a `CAObject` computing its cells in Ruby -- has the box
  the kernel touches transferred into a packed buffer first, and written back
  afterwards if the kernel wrote it. The box, not the array: an extent
  covering two cells transfers two. What that costs is a copy; what it
  changes is when the cells are read. An array whose cells are computed on
  read is read once per cell per call, so two reads of one cell in a kernel
  give the same number where the same Ruby loop would give two -- and a
  one-cell source is one number for the whole loop. Drawing random numbers
  that way therefore works, and means what filling an array before the call
  means.
- **A block's source must be recoverable.** Blocks defined in `eval` or in a
  console have no file to read back; pass `source:` there, or set
  `RubyVM.keep_script_lines = true` before defining them. This also ties the
  gem to CRuby, which CArray requires anyway.
- **Nothing existing is replaced.** `jit_for` is a new method, not a faster
  `each_index`: the two differ in what they reject, and a caller should be
  able to choose.
