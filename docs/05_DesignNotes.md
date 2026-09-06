# Design notes

Decisions that were not obvious, and why.

## The type is C's, and so is the arithmetic where the width is real

The storage type is CArray's, mapped to C exactly -- `int64_t`, `uint8_t`, `float` -- and everything the type itself decides follows from that: the width, the wrap on store, the bit patterns, what a shift does past the width. There a kernel agrees with CArray, because both are the same C.

The arithmetic follows the same rule where the width makes a difference to the answer, and Ruby's where it does not. That splits the types in two.

**Floating point computes in its own width.** A `float32` cell is read as a `float`, worked on as a `float`, and stored as one; the literal it meets takes the same width, since one `double` in a C expression takes the whole expression with it. So a kernel over float32 arrays gives what CArray's own operators give:

```ruby
one = CArray.float32(1); one[0] = 1.0
tiny = CArray.float32(1); tiny[0] = 1.0e-8

((one + tiny) - one)[0]                     #=> 0.0, computed in float
CArray.jit_for(1) { |i| out[i] = (one[i] + tiny[i]) - one[i] }
out[0]                                      #=> 0.0, the same
```

Ruby's answer for that loop is 9.99e-09, because Ruby has no float32 arithmetic to give: every cell it reads becomes a Float, which is a double. Where Ruby has no width to have an opinion about, the opinion followed is CArray's.

**The integers compute in `int64_t`,** as they always have. Reading an `int32` cell gets an Integer that does not stop at 2^31, and that is what a kernel gives it -- `int32 + int32` is worked out in 64 bits and truncated at the store.

Narrowing them was tried and dropped, because it would change the answer and buy nothing. Truncation commutes with add, subtract and multiply, so a compiler can prove the wide computation equals the narrow one and emits the narrow vectors by itself: `int16` multiplication comes out as `mul.8h` on arm64 and `pmullw` on x86 whether the C says `int16_t` or `int64_t`, with no widening instruction anywhere. Floating point has no such property -- each step rounds -- which is exactly why it has to be narrow to be narrow, and why it is about twice as fast now that it is.

`uint64` is neither: it is the width that cannot fold into `int64_t` at all, since the values it holds above 2^63 are the ones `int64_t` cannot carry, so it computes in a `uint64_t` of its own. See [Types](03_SupportedFeatures.md#unsigned-64-bit).

**A value with no data type follows Ruby.** A literal and a captured Numeric have no width of their own, so `2.0` is a double and `2` an Integer -- until they meet an array of their own kind, which lends them its width: `f32 * 2.0` is float32. What an array can lend is a width, never a kind, so `i32 * 2.0` is a float64 and `f32 * 1i` a cmplx128. A local that wants a particular type is seeded from a `CScalar`, which is a value with a data type. See [Locals](03_SupportedFeatures.md#locals-types-and-postfix-math).

`CArray.float` is float32; `CArray.double` is float64.

## `-ffp-contract=off` is mandatory

Without it, clang and gcc fuse `a*b + c` into a single FMA instruction -- **at `-O0` as well as `-O2` on arm64** -- which changes the last bit of the result. Measured on a two-term recurrence: 13 of 24 cells disagree with the Ruby loop with contraction on, and all 24 agree with it off.

The Legendre kernel happens to be immune, because its product is bound to a variable used twice and so never forms the fusable pattern. That makes this a bug a narrow test suite would miss entirely.

Fusing is not forbidden the way reassociating a reduction is not forbidden -- one rounding in place of two is if anything the more accurate -- so licensing it would be the same kind of move. It has not been made because it does not pay: measured here, contraction is worth about 1.2x on a coefficient-heavy stencil and makes the 300-cube matrix multiply about 1.3x *slower*, the vectoriser deciding differently. Off is also what keeps `a*b - a*b` and the error-free transformations meaning what they say.

## A sine beside a cosine is `sincos`, and is allowed to be

A kernel that asks for `Math.sin(x)` and `Math.cos(x)` of the same argument in the same pass does not get two library calls. The generated C says `sin(x)` and `cos(x)` on two lines and clang answers both with one call to `sincos`, whose sine is not always the one `sin` returns in the last bit. Ruby calls `sin`. So this is the one place where a kernel over `double` disagrees with the Ruby loop it replaces without the block having asked for anything unusual: measured over 200,000 arguments, a sine on its own agrees with Ruby's everywhere, and the same sine written beside a cosine of the same argument disagrees for 1748 of them, by a bit. [kepler.rb](../examples/applications/kepler.rb) prints both counts.

It is the same family of thing as fusing `a*b + c`, and the reason it is treated differently is that the flag is not the same shape. `-ffp-contract=off` stops one transformation and costs nothing. The two flags that stop this one cost, measured here on arm64 with Apple clang -- three processes, cache off, against the default flags:

```
                                   default   -ffp-model=strict   -fno-builtin
  element-wise a + b*c (4M)        1.91 ms    2.71 ms (1.42x)    2.10 ms (1.10x)
  five-point stencil (2000x2000)   1.92 ms    4.09 ms (2.14x)    2.08 ms (1.09x)
  row sums (2000x2000)             0.65 ms    0.68 ms (1.06x)    0.65 ms (1.01x)
  recurrence (4M)                 19.43 ms   27.02 ms (1.39x)   18.68 ms (0.96x)
  Kepler by Newton (200k)         11.74 ms   12.79 ms (1.09x)   12.42 ms (1.06x)
  exp and sqrt (4M)                7.25 ms    8.05 ms (1.11x)    9.47 ms (1.31x)
```

`-ffp-model=strict` brings `-frounding-math` and strict exception behaviour with it, so it does not stop one transformation -- it stops the vectoriser reasoning about floating point at all, which is where the stencil's 2.14x comes from. `-fno-builtin` is cheaper and better aimed, but it aims at the same place from the other side: it stops `sin` being recognised as `sin`, which also stops `sqrt` and `exp` being the instructions they have on this target. `-fno-builtin-sincos` does not stop the merge here at all.

So the merge stays, and is written down instead. A kernel wanting the last bit Ruby has can take the two lines apart -- a sine in one kernel and a cosine in another agree with Ruby everywhere -- and a kernel comparing itself against a Ruby loop should compare within a tolerance if it computes both.

## Integer division is floored, not truncated

Ruby floors integer division and gives the remainder the sign of the divisor; C truncates toward zero. `-7 / 2` is `-4` in Ruby and `-3` in C. CArray's own kernels were changed to floor and agree with Ruby, so a JIT specialized for CArray has to agree as well -- lowering `/` to C's operator would quietly produce different numbers for negative operands.

The generated helper mirrors `ext/mkkernel.rb` in CArray. Dividing by a positive power of two skips the helper: an arithmetic shift already floors, and is cheaper than the truncating divide C would emit.

For the same reason `%` is **not** lowered to `fmod`, which truncates. Ruby and CArray floor it. `%` is not in the subset yet.

## Integer division by zero

C has no exception to raise, and dividing by zero in the kernel would trap. The helper reports it through an `int32_t *error` out-parameter, which the Ruby side checks after the call and turns into `ZeroDivisionError`. The branch costs nothing measurable because the flooring correction needs a comparison anyway.

That slot carries `raise` too. 1 is the divisor that was not there and 2 the subscript that ran off its array; a `raise` in the block takes a code from 3 up, and the kernel keeps the message behind each -- as does a compiled function, for the `raise`s in its own body. The code is taken from the message rather than counted off as messages are met: a kernel is cached on disk under the C it generated, and a number that meant one string when the object was built and another when it was loaded would raise the wrong message out of a cache hit, quietly. From the message, one string is one code in every process.

## Reaching the array

A generated kernel addresses cells itself -- it reads `a[i-1]` and writes `a[i]` -- so what it needs from CArray is not element delivery but an **addressing basis**: a pointer, an offset, and one byte stride per axis.

That rules out the two surfaces that look like the obvious homes for it. The kernel iterator (`guides/devel/11`) delivers cells per slab, with mask gather and outer-axis walk, and has no N-ary form -- the Thomas algorithm touches six arrays at once. The sweep ELEMENT family (`guides/devel/13`) flattens the array and cannot recover the axis structure a stencil needs. Neither is wrong; they answer a different question.

The basis comes from three public predicates, checked in order:

| | Test | How the kernel reaches the array | Copy |
| --- | --- | --- | --- |
| 1 | `ca_is_entity` | the buffer is the basis | none |
| 2 | `ca_is_stride_family` | `ca_stride_compose_to_root` folds the whole view chain to `root + base + strides` | none |
| 3 | otherwise | `ca_xfer_stride` moves the box the loop touches | that box |

Tier 2 is what makes a transpose, a column slice, a reversal, or a slice of a slice run **in place**, with no gather and no scatter -- a write through the folded stride lands in the parent's memory, because it *is* the parent's memory. Measured on a two-million-element recurrence:

```
entity                       tier 1  stride 8    2.17 ns/element
contiguous row of a matrix   tier 2  stride 8    2.13 ns/element
strided column               tier 2  stride 16   4.85 ns/element
reversed                     tier 2  stride -8   4.86 ns/element
```

A contiguous view costs what an entity costs. A strided one costs about twice that, because the loop cannot be vectorised. Copying it out, running the contiguous loop and copying it back measured about 25% faster than folding it in place (7.4 ms against 9.8 ms) -- so folding is not chosen for speed. It is chosen because the alternative is the library allocating a second array behind the caller's back. Anyone who wants that trade writes `column.copy`, and can see what it costs.

The fold has to land on an array that owns its memory. It stops at the first thing it cannot fold through, and that need not be an entity -- a `CARefer` over a gather view (`whole[whole >= 0].reshape(4, 4)`) folds one step and lands on the `CASelect`. Attaching a root like that materialises a temporary, and detaching it would throw the kernel's writes away, so a fold that does not reach an entity is not the stride tier at all: it goes to the box transfer, which moves only the cells the kernel asked for and puts them back.

The fold is done **once**, before compiling, and its result is passed to the kernel. That matters more than it looks: composing the chain per access costs 10 ns for one hop and 37 ns for two, while a hoisted basis is flat at 3.5 ns regardless of depth.

## Why tier 3 never materialises the whole view

The box is computed per array and per axis: two arrays in one kernel need not be read at the same offsets, and one array need not be read at the same offsets on each of its axes.

`ca_attach` on a view gathers all of it, whatever the kernel intends to touch. On a four-million-element gather view that was 2.7 ms whether the loop covered a hundred cells or a million. `ca_xfer_stride` moves only the requested box:

```
loop covers        ca_attach     ca_xfer_stride
100 cells            2.97 ms         0.001 ms
10,000 cells         2.69 ms         0.022 ms
1,000,000 cells      3.86 ms         2.305 ms
```

Most kernels cover the whole array, so in practice this rarely changes the number. It changes what the library promises. A cost that does not scale with the work is one the caller cannot reason about, and a JIT that hides one has given up the thing it exists for.

The same reasoning is why nothing here materialises on the caller's behalf beyond that box. CArray's own rule is that a materialised copy happens when the user writes `copy` (`guides/devel/10`, principle 3); a kernel that silently gathered 32 MB would be breaking it.

## What was tried and rejected

The first version of this gem read the pointer through Ruby's MemoryView C API, to stay independent of `carray.h`. It asked for `RUBY_MEMORY_VIEW_SIMPLE`, which demands a contiguous buffer, concluded that views could not be reached, and rejected every one of them. Both halves were wrong: `RUBY_MEMORY_VIEW_STRIDES` exports the whole CAStride family zero-copy, and CArray's own predicates say more than the buffer protocol can. Refusing views to keep the gem decoupled was trading away the composability that views exist for.

Per-cell `ca_xfer_addrs` was measured as a tier-3 alternative and is not used. At `n = 1` it re-folds the view on every call and adds about 28 ns of fixed cost on top; batched over 1024 cells it is as fast as anything, but a recurrence cannot batch -- each write has to land before the next read.

## Recovering a block's source

Ruby will not hand back a Proc's source, but it does say exactly where the block sits. `RubyVM::InstructionSequence.of(block).to_a[4][:code_location]` gives `[first_line, first_column, last_line, last_column]`; the file (or `script_lines`) is parsed with Prism, and the block node at that position is the kernel.

The columns are the part that matters. `Proc#source_location` reports only a line, which cannot tell two blocks on one line apart -- so it is not enough on its own.

`RubyVM::AbstractSyntaxTree.of` looks like the obvious route and does not work: since Ruby 3.4 the default parser is Prism, and it refuses with "cannot get AST for ISEQ compiled by prism".

Two cases fall back to `source:`. A block defined in `eval` or in a console has no file to read -- setting `RubyVM.keep_script_lines = true` before it is defined makes `script_lines` available and handles that. And a file edited since it was loaded no longer holds the same text at that position, which is reported rather than compiled.
