# The shapes a kernel takes

## `jit_each` and `jit_map`, when nothing reaches a neighbour

Naming an index is what lets a kernel reach a neighbouring cell, and reaching a neighbouring cell is what makes the range and the direction matter. A computation that reaches none needs none of that, so it names no index, takes no extent, and has a method of its own:

```ruby
CArray.jit_each { out = a + b * c }
```

That right-hand side is what the expression already means in CArray, written exactly as it would be written anywhere else. What changes is not the expression but how it runs: at the cell, in one pass, instead of three passes with two arrays in between.

The assignment is Ruby's own. Every name in the block is a cell -- the loop is this compiler's and is not written here -- so `out = ...` writes the cell of the array `out` names outside, and a name that is not an array there stays a local of the block's. `out[] = ...` was the spelling from when the block had to run as Ruby, `[]=` being the only way Ruby has to say "the whole array"; the block is read rather than run, so it is refused now and says this. `a[]` is still accepted on the right, and says what the bare name says.

#### A `CScalar` is a value with a home

`CScalar` is the one-cell `CArray` it subclasses, minus the index: `s[]` is the value, and `s[] = ...` puts one back. CArray's own operators read that one cell for every cell of everything else, and so does this:

```ruby
gain = CScalar.double() { 2.0 }
CArray.jit_each { out = signal * gain }        # gain read at every cell
CArray.jit_each { gain = gain + 0.5 }          # and written like any cell
```

An indexed kernel reaches it too, and there the missing index is the whole point: `s[]` and a bare `s` both mean the value, because there is no axis to walk and so no index to write.

```ruby
CArray.jit_for(n) { |i| out[i] = signal[i] * gain[] }
```

The two routes differ in how they get there. `jit_each` stretches it as it stretches a one-cell `CArray` -- a stride of zero -- while `jit_for` reads it where it lies. They compute the same thing, and `s[0]` keeps working in both, since it is still the one-cell array it is. Writing a wider expression into one is refused, with the shapes named, exactly as CArray refuses it.

The other method is the same block with its value asked for:

```ruby
sums = CArray.jit_map { a + b }
```

The last statement is what every cell of the result gets, so there is no output array to name and the result comes back typed from that value rather than from the arrays. The name is the whole of the difference: the block is read the same way, and what it may do is the same.

An assignment is a statement with a value -- Ruby's rule, not a special case here -- so `CArray.jit_map { out = a + b }` writes `out` and hands the same value back. Which is why the two methods are split by what returns rather than by what is written: writing is the block's business either way.

It is the same shape of block `CArray.jit_function` takes, and not the same thing. There, the loop belongs to whoever calls the function, so the body is reached through a pointer and may close over nothing. Here the loop is this compiler's and the body is inlined into it, so it costs no call and may reach a captured value, a `Math` function or a bound C function like any other kernel body.

#### Who drives the loop

An element-wise pass is the one shape that is a *sweep* -- nothing reaches a neighbour, nothing chooses an order -- so CArray can drive it instead. Where this CArray has `ca_call_cslab` (3.0.1 and later), `jit_each` hands it the compiled body and lets it acquire the operands.

The body is the same either way. The sweep entry point is a wrapper that calls the same kernel with the chunk as its bounds, so what changes is who opens the arrays, not what they compute.

What that is worth is memory. An operand CArray cannot walk in place -- a gather, a lazy array -- is re-gathered 32KB at a time by the sweep, where the tiers here move the whole box the kernel touches, and for an element-wise pass that box is the whole array. Over two million doubles with a gather view as an operand, both take about 1.3 ms and one of them holds sixteen megabytes of scratch while the other holds thirty-two kilobytes. With entity operands the two are indistinguishable, so there is nothing to weigh.

A **strided view** is the case where there is. A column, a transpose, every other cell: the tiers address those in place, with no gather and no scatter, so the sweep's re-gather has no whole-array copy to save you from and costs what it costs. Over two million doubles, `0.42 ns` a cell walked in place against `4.7 ns` swept, and no scratch either way. So the driver is chosen on the operands as well as the shape -- the sweep runs where some operand has to be moved whatever happens, and where none of them does.

The rank does not stand in the way, and the arrays are not reshaped to get it out of the way. CArray's acquire reads an operand's element count and element size and never looks at its shape, so a chunk is already a flat run of cells; what has to be flat is the *kernel*, and it is compiled at rank one over the same cells rather than as a nest over the axes. One such kernel then serves whatever rank it is given, because the rank has left the loop.

Four things keep the driver here. An operand that is a **strided view**, for the reason just measured: it is walked in place here, and re-gathered there for nothing. A **stretched operand**, which is the one thing that cannot be flattened: broadcasting arrives as a stride of zero on an axis, and a flat run has no axes, so cell k of the output would stop lining up with cell k of the operand. A body that **asks about a mask**, because a chunk carries no per-cell mask to ask it of -- CArray ORs and propagates the masks, but `a[i] == UNDEF` is a question about one cell. And a CArray **without the family** at all, which is asked for by symbol rather than assumed, so an older one falls back without the caller hearing about it.

`jit_for` never goes this way, and that is not a limitation: a kernel that names an index reaches neighbours, chooses an order and runs inner loops, none of which a chunked walk can offer. The two names mark the same line.

The two methods are one machinery and two names, and the names are the point: "cell" is a position, which is what a block names when it can reach the positions around it, and "element" is what CArray calls the same work done cell by cell with no neighbour in it. Each method's block is turned away by the other rather than quietly reinterpreted.

Shapes are broadcast the way CArray broadcasts them, which costs nothing here: a stretched axis comes back as a stride of zero, and the kernel addresses by stride anyway. The rank comes from the arrays rather than from the block, so one expression serves whatever shape it is given.

CArray has its own answer to the intermediate arrays: `CArray.fuse { a + b * c }` builds the expression as a structure rather than as arrays, reading the names from where the block was written. Walked by CArray that holds the intermediates to one buffer per level of the expression's right spine rather than removing them -- see the table in [Four ways](01_GettingStarted.md#four-ways-to-compute-an-expression-and-what-separates-them) -- and it leaves the passes alone: each operation is still its own walk over the data.

Where this gem is installed, though, `fuse` does not walk: it is registered as CArray's expression evaluator, and a fused expression is compiled into one kernel like any other. So there are two fuse rows, and the difference between them is this gem:

```
n = 4,000,000

out = a + b * c
  a + b * c                     5.2 ms   1.30 ns/element
  CArray.fuse, walked           3.9 ms   0.99 ns/element    1.32x
  CArray.fuse, compiled here    2.9 ms   0.74 ns/element    1.76x
  jit_each { out = ... }        1.3 ms   0.32 ns/element    4.11x

out = (a + b) * (c - a) + b * c - a
  plain                        17.7 ms   4.42 ns/element
  CArray.fuse, walked           8.5 ms   2.13 ns/element    2.08x
  CArray.fuse, compiled here    2.6 ms   0.66 ns/element    6.74x
  jit_each { out = ... }        1.2 ms   0.30 ns/element   14.67x
```

Walked, `fuse` earns more as the expression grows -- there are more intermediates it is not allocating -- but it still grows, because the passes are still there. Compiled, neither row grows: the expression is read once whatever it says.

What is left between the last two is not speed. `jit_each` is handed the array to write into, where `fuse` returns the expression and allocates when it is asked for an array; and a block can say what an expression cannot -- a cell reaching its neighbours, a loop written out, a reduction. Where an expression over whole arrays is the whole of it, `fuse` is what to write, and this gem makes it faster without being named.

## Extents, steps and subscripts

### The extent says which cells, and which way

Which way an axis runs is the extent's to say, and the kernel runs the order it is given. Where a kernel reads a cell it will later write, that order is the answer: reading behind the cell being written propagates forwards, reading ahead of it propagates backwards, and both together mean cells already passed hold new values while cells not yet reached hold old ones. None of these is ambiguous, and each is what the same Ruby loop leaves behind.

So the direction is **written at the call site**, because that is the only place a reader sees it:

```ruby
CArray.jit_for(1...n) { |i|                       # upward: reads cc[i-1]
  denominator = b[i] - a[i] * cc[i-1]
  cc[i] = c[i] / denominator
  dd[i] = (d[i] - a[i] * dd[i-1]) / denominator
}

CArray.jit_for((n-2).step(0, -1)) { |i|           # downward: reads x[i+1]
  x[i] = dd[i] - cc[i] * x[i+1]
}
```

A plain `Range` means upward, and `step` is how the other direction is said. Neither is checked against the body: a kernel is not asked to justify the order it was handed, any more than a `for` loop in C or a `do` loop in Fortran is. What *is* checked is that every cell the loop would touch exists -- see below.

`(n-2)..0` would read better than `(n-2).step(0, -1)`, and is not accepted: Ruby gives that Range no elements at all, so the same expression written as a Ruby loop would silently do nothing. `step` is the spelling Ruby actually iterates backwards.

The forward sweep above also shows why a kernel writes as many arrays as it likes: `cc` and `dd` share a denominator, and splitting them into two loops would compute it twice.

### Skipping cells

An extent may step by more than one, and an offset still means what it means in Ruby -- `a[i-1]` is the cell at index i-1, whether or not the loop is one that writes it:

```ruby
CArray.jit_for((2...n).step(2)) { |i| a[i] = a[i-1] + b[i] }
CArray.jit_for((2...n).step(2)) { |i| a[i] = a[i-2] * 3.0 }
```

With a step of two the loop writes only every other cell, so the first reads cells this loop never touches and the second reads its own previous iterate. Both are what the same Ruby loop over the same sequence would do.

### Ranges are checked, not guessed

Because the range is given rather than inferred, the extents, the range and the offsets are all known before anything runs, and a kernel that would reach outside its array says so rather than reaching:

```ruby
CArray.jit_for(0...8) { |i| values[i] = values[i-1] * 2.0 }
#=> CArray::JIT::Unsupported: `values` is indexed at `values[i - 1]`,
#   so the range on `i` cannot start at 0
```

This is the check that has to be here. Ruby raises on an index past the end and CArray does too; C reads whatever is there, or writes it. Everything else about the order is the caller's to say.

An inferred range would have quietly started at 1 instead, and a kernel that meant to touch cell 0 would never say so.

### Subscripts the kernel works out

A subscript is usually an index and a constant, and then every cell the kernel touches is known before it runs. But it may also be a value the kernel works out -- a cell of another array, or a local -- and then it cannot be, so the check moves to the access:

```ruby
CArray.jit_for(n) { |i| result[i] = table[index[i]] }        # a gather

CArray.jit_for(n) { |i|                                      # a histogram
  bin = value[i].floor
  histogram[bin] = histogram[bin] + 1
}
```

Out of range raises `IndexError`, at the cell the Ruby loop would have raised at: the loop stops there rather than running on and reporting at the end. A read outside the array reads cell zero and reports, which changes nothing that is kept; a write outside it is not made at all, since a report that arrived after the damage would be no use.

This is the one thing about a kernel that is not settled in advance, and it costs what that implies: a compare per access, and no vectorising the expression it is in. Kernels without such a subscript are untouched -- they keep both loops and the check that costs nothing.

A view that has to be reached a box at a time still takes one, but the box becomes the whole view: a computed index could reach any cell of it. That costs what copying the view would have cost, which is what the caller would otherwise have been told to write by hand.

One restriction remains. A write is either the cell the loop is on or a computed one -- never the cell one along, which is the cell another iteration writes.

## Stencils

A stencil is every cell from the ones around it, and `jit_stencil` is the spelling where the loop is implied:

```ruby
smoothed = CArray.jit_stencil(image) { |a|
  0.25 * (a[-1, 0] + a[1, 0] + a[0, -1] + a[0, 1])
}
```

The arrays are given rather than closed over, and the block's parameters are windows onto them, in that order. `a[0, 0]` is the cell the loop is on and `a[-1, 1]` its neighbour, so the offsets are the stencil as it is drawn. The block's value is what the cell gets, as `jit_map`'s is, and what comes back is an array of the same shape.

The offsets are written out — a literal, or arithmetic over literals — because the radius has to be known before the loop runs; see [what is not a stencil](#what-is-not-a-stencil). The weights need not be: `w[-1] * coef[0] + w[0] * coef[1]` reads those from an array like any other captured value.

Written with the indices named, the same thing is [`jit_for`](#extents-steps-and-subscripts)'s:

```ruby
rows, columns = image.dim
smoothed = CArray.double(rows, columns)
CArray.jit_for(1...(rows-1), 1...(columns-1)) { |i, j|
  smoothed[i, j] = 0.25 * (image[i-1, j] + image[i+1, j] +
                           image[i, j-1] + image[i, j+1])
}
```

What the window is for is not the four lines. It is the border.

### The border is an argument

With the indices named, what `image[i-1, j]` means at `i = 0` has nowhere to be said. So the extents say it by not going there, and the border keeps whatever the output array held — zeros, usually, which cannot be told from zeros that were computed. A window has nowhere to write an index and so has somewhere to put the question:

```ruby
CArray.jit_stencil(image, border: :mask)    # the cell is UNDEF        (default)
CArray.jit_stencil(image, border: :skip)    # the cell is left as found
CArray.jit_stencil(image, border: :zero)    # a read outside gives 0
CArray.jit_stencil(image, border: :clamp)   # a read outside gives the nearest cell
CArray.jit_stencil(image, border: :wrap)    # a read outside comes back the other side
```

The default is `:mask` because CArray can say "not computed", and that is what those cells are. `:skip` is the older spelling's behaviour, for when the border is yours to fill.

The other three are answers about the read rather than about the cell, so the border cells are computed after all — `:wrap` is what makes a Game of Life board a torus, and `:clamp` what an image filter usually wants at the edge.

### What it costs

Two loops, not one with a question in it. The interior is the loop the written-out spelling compiles to, with nothing about the border in it; the frame is walked afterwards, by the same statements with the rule woven into their reads. Over a 2000x2000 five-point stencil:

```
  jit_for over the interior, by hand      1.13 ms   0.28 ns/cell
  jit_stencil, border: :skip              1.13 ms   0.28 ns/cell
  jit_stencil, border: :clamp             1.19 ms   0.30 ns/cell
  jit_stencil, border: :wrap              1.20 ms   0.30 ns/cell
  the same clamp written inside one loop  3.20 ms   0.80 ns/cell
```

The window costs nothing to run: the interior is the same loop, and the same answer bit for bit. The border costs about five per cent, because the frame is 0.2% of the cells — and writing the same rule into the one loop costs 2.7x, because then every cell pays for what only the frame needed.

### Several arrays, and everything else

Each array given gets a window, in the order the block names them; the names shadow whatever they hold outside, as `CArray.fuse`'s do.

```ruby
CArray.jit_stencil(u, k) { |u, k| u[0,0] + k[0,0] * (u[-1,0] + u[1,0] - 2.0*u[0,0]) }
```

An array the block closed over rather than was given has no window, and is read at the cell — what a bare name means wherever the loop is this compiler's. A captured scalar is a scalar.

A missing cell reaches as far as the window does: `a[-1, 0]` over a cell whose neighbour is UNDEF gives UNDEF, which is the propagation the rest of this compiler already does.

### The array that comes back

Typed from the block's value, as `jit_map`'s result is, unless you say otherwise:

```ruby
CArray.jit_stencil(image, type: :float32)      # collect into float32
CArray.jit_stencil(image, into: edges)         # write into an array of yours
```

`into:` takes an array of the stencil's own shape and returns it; the type is then that array's. Passing both is refused — the array already says what type it is.

### What is not a stencil

- **A computed offset.** `a[k, 0]` where `k` is a value is refused: the offsets are what the radius is read from, and the radius is what lets the interior be walked without asking, at every cell, whether it is still inside. A subscript the kernel works out is [`jit_for`](#extents-steps-and-subscripts)'s, and so is a window whose width is decided when the program runs.

Arithmetic over literals is not a computed offset — `a[-1-1, 0]` is `a[-2, 0]`, folded where the block is read, and a stencil drawn from a formula is usually written that way. What may not appear is anything that has to be *read* to be known, a captured integer included: those arrive with the call, and one compiled kernel serves every value of them, so a window built from one would have a radius the loop does not know.
- **A recurrence.** `smoothed[i] = alpha * price[i] + (1-alpha) * smoothed[i-1]` reads a cell this loop wrote. A window reads the array as it was, so that is not a stencil however much it looks like one — it is `jit_for`'s, and the direction of its extent is what records the dependency.
- **Writing.** A stencil produces a value. A block that writes several arrays is [`jit_each`](#jit_each-and-jit_map-when-nothing-reaches-a-neighbour)'s.
- **Arrays of different shapes.** They must agree; a stretched axis has no neighbour to reach.

## Reductions

A reduction is a per-cell computation like any other: the caller says where the answer goes, and the kernel fills that cell.

```ruby
CArray.jit_for(rows) { |i|
  accumulator = 0.0
  (0...columns).each { |j| accumulator = accumulator + source[i, j] }
  total[i] = accumulator
}
```

The accumulator is split into partial sums, which is faster than the serial chain and usually the more accurate answer, and is not the order the same loop would take in Ruby. `reassociate: false` asks for that order; see "The order a reduction takes its terms in" below.

What makes it expressible is `(from...to).each { |j| ... }` -- or `n.times { |j| ... }`, which is the same loop from zero: an inner loop whose index addresses arrays but writes nothing. The accumulator is then an ordinary block-local, which is why sum, maximum, product, count and a dot product all fall out without a primitive each -- and why a matrix multiply does too:

```ruby
CArray.jit_for(rows, columns) { |i, j|
  accumulator = 0.0
  (0...inner).each { |t| accumulator = accumulator + left[i, t] * right[t, j] }
  result[i, j] = accumulator
}
```

`each` rather than `for`, because `for` does not open a scope: it would assign an enclosing variable of the same name and leave the index bound afterwards, neither of which the generated loop does. The range must be a literal `Range`; `Enumerator::ArithmeticSequence` -- `(0...n).step(2)` -- is not handled yet.

Inner loops nest, and an index binds to an axis by name rather than by position. One index may walk two axes of the same array (a trace), two indices may walk one axis of it (`c[p,a] * c[p,b]`, which is a covariance), the outer indices need not address axes in their own order (a transposing read), and a full contraction is the same thing written into a one-cell box.

That holds for an array the kernel writes as well. In `v[a,b] = v[a,a]` the cell read is one this loop also writes, so cells reached before it read the old value and cells reached after it read the new one, and the answer depends on the order -- which is what the extent states. So the kernel runs the order it was given and means what the same Ruby loop means.

Written out, a contraction is loops; but the loops are the *definition* rewritten, so `jit_contract` writes the definition instead -- see [Contraction](#contraction).

An offset may be an integer the block closed over -- `a[i - window]` for a window the caller chooses -- and it reaches the kernel as an argument, so one compiled kernel serves every value of it. How far the kernel reaches is then known when it is called rather than when it compiled, which is where the bounds check already lives. Nothing is executed before it passes.

An index may address any axis of any array that is read. A subscript that is not an index **pins** the axis: `a[i, 0]` is the first column, and so is `a[i, offset]` where `offset` is an integer the block closed over. A pinned position is an argument to the kernel rather than part of it, so one compiled kernel serves every value -- which is what lets a contraction be taken row by row from an ordinary Ruby loop:

```ruby
n.times { |i| out[i] = CArray.jit_contract { |k| a[i, k] * b[i, k] }[0] }
```

Whether that is a good idea depends on how much work each call does. A call costs 20-40 us before the kernel starts, and against that:

```
64 dot products, inner length  Ruby loop    loop of jit_contract    one jit_for
                            4    0.04 ms             1.22 ms         0.03 ms
                           64    0.56 ms             1.41 ms         0.02 ms
                        1,000    8.38 ms             1.51 ms         0.07 ms
                       10,000   83.17 ms             2.00 ms         0.60 ms
                      100,000  839.73 ms             7.17 ms         5.92 ms
```

Below a few hundred elements the loop of `jit_contract` is **slower than the Ruby loop it replaces** -- at an inner length of four, thirty times slower -- because the per-call cost dwarfs an inner loop the interpreter gets through quickly. Past a thousand it wins, and by a hundred thousand the overhead has disappeared and the loop form is simply the more readable one.

How many times the outer loop runs does not enter into it: both sides scale with it, so the ratio holds. At an inner length of 64 the loop of `jit_contract` is 0.12x, 0.33x and 0.40x the Ruby loop for 4, 64 and 1024 outer iterations; at 10,000 it is 48x, 41x and 41x. The only question is whether one call's worth of work is worth its 20-30 us.

Writing the whole thing as one kernel has no such threshold: it beats the Ruby loop at every size on this table, and by two orders of magnitude once there is real work.

A constant subscript pins an axis: `a[i, 0]` and `a[i, j]` on the same array is ordinary. An array the kernel *writes* cannot be read through an inner index, because that would reach cells another outer iteration owns and no evaluation order settles it.

```
row sums over 2000 x 500
  jit_for                       0.3 ms   0.25 ns/cell
  jit_for, reassociate: false   0.9 ms   0.92 ns/cell   3.61x
  Ruby loop                     50.7 ms  50.75 ns/cell    200x
  sum(axis: 1)                   0.1 ms   0.10 ns/cell   0.40x

matrix multiply 300 x 300 x 300
  jit_for                       6.5 ms   0.24 ns per multiply-add   8.37 GFLOP/s
  jit_for, reassociate: false  15.3 ms   0.57 ns per multiply-add   3.53 GFLOP/s
```

#### The order a reduction takes its terms in

Floating-point addition is not associative, so a serial accumulator is one dependent chain and each addition waits for the one before it. Splitting it into partial sums is what fills that latency, and it is the whole of the difference between the two rows above -- and between `jit_for` and `sum(axis: 1)`, whose kernels take a `reduction_kind:` licence that emits `#pragma omp simd reduction(...)`.

A kernel splits the accumulator by default, into eight chains combined pairwise at the end, with the terms that do not fill a round left to a serial tail. So the three answers are three numbers:

```
Ruby's serial sum              204800000000.0     4247d78400000000
jit_for, reassociate: false   204800000000.0     4247d78400000000
jit_for                       204800000000.0042  4247d7840000008a
sum(axis: 1)                   204800000000.0074  4247d784000000f2
```

That is not a trade of accuracy for speed. Splitting the accumulation is what limits the cancellation, so the partial sums are usually the *more* accurate answer -- on this row, which cancels, the licensed kernel is nearer the true sum than the serial one is. What it is not is the order Ruby's loop would have taken, and that is what `reassociate: false` asks for:

```ruby
CArray.jit_for(rows, reassociate: false) { |i|
  accumulator = 0.0
  (0...columns).each { |j| accumulator = accumulator + source[i, j] }
  total[i] = accumulator
}
```

Two reasons to ask for it. A **compensated summation** -- Kahan's, or any error-free transformation -- *is* its order: reassociating it does not make it less accurate, it deletes the algorithm. And **checking a kernel against the loop it replaces** needs the two to be comparable to the last bit, which is how this gem's own tests are written; `CARRAY_JIT_REASSOCIATE=0` sets it for a whole process.

What is licensed is the order the *iterations* are grouped in, and nothing else. Each term is computed exactly as it was written, in the operand order it was written in, and everything outside a reduction is untouched: a recurrence is serial by definition, and a stencil's cells are independent, so neither has an order to give up.

The licence is part of the kernel rather than of the call -- it decides what C is emitted -- so the two spellings compile to two kernels and the cache keeps them apart. `#c_source` shows which one ran; the chains are named `<accumulator>__p0` and up.

**A fold and nothing else.** The accumulator has to enter the loop already live and leave it folded whole: one statement, one associative operator, the accumulator on one side and a term that does not mention it on the other. An exponential average -- `accumulator = accumulator * 0.5 + source[i, j]` -- is not that, and keeps the serial loop, which is right: there the order is the algorithm. So does a masked accumulator (a partial sum would need a mask each), an integer one (reassociating it computes the same number, so there is nothing to license), and a written-out extent shorter than one round.

The matrix multiply carries a different subtlety -- it is a plain triple loop and not a blocked GEMM, so BLAS is still an order of magnitude away.

So this is not a faster `sum`. It is a way to write the reduction that has no `sum`.

## Contraction

`CArray.jit_contract` contracts over a repeated index: **an index that repeats in the term is summed**. The repetition is the notation -- it is what stands in for the sigma. How often it repeats does not enter into it: `q[i,i,i]` is one index read at three positions, and the sum runs along the cube's long diagonal.

```ruby
c = CArray.jit_contract { |i, j, k| a[i,k] * b[k,j] }   # a matrix product
m = CArray.jit_contract { |i, k|    a[i,k] * v[k]   }   # a matrix times a vector
s = CArray.jit_contract { |i, k|    a[i,k] * b[i,k] }   # both summed, one cell
t = CArray.jit_contract { |i|       q[i,i]          }   # a trace
o = CArray.jit_contract { |i, j|    p[i] * r[j]     }   # an outer product, nothing summed
```

The result is allocated and returned, its axes being the free indices in the order the block named them -- so the parameter list is where the axis order is stated, and `{ |j, i, k| ... }` gives the transpose. Assigning into an array of your own says where to put it instead:

```ruby
CArray.jit_contract { |i, j, k| c[i,j] = a[i,k] * b[k,j] }
```

which must name exactly the free indices, and still does not decide what is summed.

No extent is given, because each index's extent is fixed by the axes it addresses. An index whose axes disagree is refused, which is the shape check a contraction exists to do:

```
`k` addresses axes of different extents: `a` axis 1 is 4, `b` axis 0 is 5
```

Neither form decides what is summed. So a sum along an axis is not a contraction, and is refused:

```ruby
CArray.jit_contract { |i, k| total[i] = a[i,k] }
#=> `k` appears once, so it is free and must be on the left. A contraction
#   sums the indices that repeat; to sum one that does not, write the loop
#   with jit_for, or use sum(axis:)
```

There is nothing in `a[i,k]` standing in for a sigma, and summing anyway would be the `=` quietly meaning something it does not say. `sum(axis: 1)` is that operation, and it is faster than anything written here.

### Naming the result's axes

That a repeated index is summed is a statement about *dimensions*, which is the world the notation comes from: two dimensions met is an inner product, and there is no other reading. An index that numbers things -- a point, a sample, a batch -- is not a dimension. `x[p,k] * y[p,k]` repeating `p` says "the same point", not "sum over points", and the convention cannot tell the two apart. Naming the result's axes says which is meant:

```ruby
n = CArray.jit_contract(:p) { |k| x[p,k] * y[p,k] }               # one number per point
d = CArray.jit_contract(:a) { q[a,a] }                            # the diagonal, not the trace
r = CArray.jit_contract(:b, :i, :j) { |k| u[b,i,k] * v[b,k,j] }   # a batch of products
```

The arguments are the result's axes, in that order. What they say is which indices are free; they do not say what a repetition means, and a repetition still means a sum. So the whole of it is the convention's rule with a clause added:

**An index that repeats is summed; one that appears once is free; and a named one is free however often it appears.**

The third clause is what puts the per-point quantity and the diagonal inside the notation instead of outside it -- `q[a,a]` is the trace under the convention and the diagonal when the axis is named.

A free index then needs somewhere to go, and there are three places: the argument list, the left-hand side, or -- with neither -- the result's axes, which are the free indices in the order the block's parameters named them. So a parameter at a single position is refused once the axes are named. It is free, by the second clause, and the axes are already stated:

```
`k` appears once, so it is free rather than summed. A contraction sums the
indices that repeat; name it as an axis of the result
(`CArray.jit_contract(:i, :k)`) to keep it, or use sum(axis:) to sum along
the axis
```

With every index named there is nothing left to sum, and the block takes no parameters at all.

This is the split `einsum` makes with `->`: `'ii'` is the trace and `'ii->i'` the diagonal, `'pk,pk'` is one number and `'pk,pk->p'` one per point. The argument list is that arrow's right-hand side.

Naming is allowed where the convention would have reached the same answer, which is how the result's axes are put in another order:

```ruby
CArray.jit_contract(:j, :i) { |k| a[i,k] * b[k,j] }   # the product, transposed
```

An index cannot be both, and saying so twice is refused. Everything else is as it is under the convention: the extents come from the axes, an index whose axes disagree is refused, and assigning into an array of your own says where the result goes.



An array that is both written and read is a recurrence rather than a contraction, and is refused with a pointer at `jit_for` too.

There is no BLAS for an arbitrary contraction, which is rather the point: this compiles to a plain nest of loops and is slower than a tuned GEMM, but it is one line and it exists.

Its sum is split into partial ones, as `jit_for`'s reduction is and as CArray's own reduce kernels are. A contraction is a sum with no loop written anywhere for its order to agree with -- the notation says which indices are summed and nothing about in what order -- so there is nothing being overridden, which is a weaker claim than the one `jit_for` makes over a loop somebody wrote. It is also the whole of the difference between a contraction and that loop: a 400 x 400 x 400 product took 47 ms serial against `jit_for`'s 16, and takes 16 split (`benchmark/contraction.rb`).

`CArray::JIT.reassociate = false`, and `CARRAY_JIT_REASSOCIATE=0` for a whole process, ask for the serial order here as they do everywhere -- which is the order a Ruby loop takes, and what to use to compare one against the other. Unlike `jit_for`, `jit_contract` has no per-call licence: a contraction names no loop, so there is no loop at the call site to license.
