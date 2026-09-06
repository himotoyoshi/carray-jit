# Getting started

The block's parameters are the loop indices. Arrays and scalars are the variables it closes over -- `legendre` and `x` here -- so nothing is named twice, and the body reads like the Ruby loop it replaces.

An extent is a `Range`, an `Integer` standing for `0...n`, or an `Enumerator::ArithmeticSequence` -- what `(high - 1).step(low, -1)` returns -- one per index. A whole array is therefore `CArray.jit_for(*array.dim) { ... }`.

```ruby
CArray.jit_for(1...(rows-1), 1...(columns-1)) { |i, j|
  out[i, j] = 0.25 * (src[i-1, j] + src[i+1, j] + src[i, j-1] + src[i, j+1])
}
```

`jit_for` returns the compiled kernel, whose `#c_source` is the C that ran. So does `jit_each`, the sibling method for work that reaches no neighbour and so needs neither an index nor an extent.  `jit_map` is that same method with its value asked for, and returns the array of results instead.

[examples/applications/](../examples/applications) holds small programs that use this to do something -- a Game of Life, an implicit heat equation, edge detection, quality control on a sensor record -- each measured against the Ruby loop or the array expression it replaces. [examples/features/](../examples/features) is a tour of everything in these docs, one file per feature. `rake examples` runs them all.

## Where the methods come from

`CArray.jit_for`, `CArray.jit_each` and `CArray.jit_map` are named by CArray, which defines them to raise: they say that they compile their block, that the compiler is this gem, and that it is not installed. Installing it replaces them with the ones that compile.

The name carries the rest. `jit_` says the block is read rather than run, and so has rules about what may be in it; a method called `per_cell` would not, and the subset would be something you found out about later. It also marks which methods need the compiler and which do not: an expression over whole arrays is `CArray.fuse`'s, and that one needs nothing installed.

The line between these two falls where the block's names fall -- a block that names indices is `jit_for`'s, a block that names none is `jit_each`'s -- and each turns the other's block away rather than quietly doing something with it.

## No fallback

A block outside the compilable subset raises `CArray::JIT::Unsupported`, and so does one written with no compiler installed. Neither quietly runs the block as a Ruby loop instead.

Nobody writes `jit_for` except to make a per-cell computation fast, so running it a hundred times slower would answer a question that was not asked, and would hide the difference behind a call that looks the same either way. An expression that can be written without a loop is better written as `CArray.fuse`, which is one pass with or without this gem.

## Four ways to compute an expression, and what separates them

CArray can evaluate `out = (a + b) * (c - a) + b * c - a` four ways now, and the line between them is not a factor -- it is what `n` gets multiplied by. `CArray.fuse` builds the expression rather than evaluating it a step at a time, and CArray walks what it built; requiring this gem registers a second evaluator (`CArray::JIT::Expression`), so an expression over an array worth compiling for is compiled instead. Where that line falls is CArray's to decide, not this gem's -- ten thousand cells today. So `fuse` is two rows here, and which one you get depends on whether the gem is installed.

```
n = 4,000,000
                                 a + b * c      the longer expression
  a + b * c ...                   1.30 ns/el          4.42 ns/el
  CArray.fuse, walked             0.99 ns/el          2.13 ns/el
  CArray.fuse, compiled here      0.74 ns/el          0.66 ns/el
  jit_each { out = ... }          0.32 ns/el          0.30 ns/el
```

An expression of `k` operations is `k` passes over the data, and walking it rather than materialising it does not change that -- it changes what each pass costs, which is why the first two rows still grow with the expression, one more steeply than the other. Compiled, the expression is one pass however long it is, which is why the last two rows do not move at all.

Memory separates them again, on a different line. Summing `(a + b*1) + (a + b*2) + ...`, peak resident over two arrays of eight million doubles, one array being 61 MB (`benchmark/footprint.rb`):

```
  terms                               1      2      3      4      6
  a + b*k, summed                  +123   +245   +367   +488   +611
  fuse walked, leaning left        +122   +184   +185   +183   +184
  fuse walked, leaning right       +123   +184   +246   +306   +428
  fuse compiled, leaning left       +62    +61    +61    +62    +61
  fuse compiled, leaning right      +61    +62    +63    +62    +62
  jit_each                           +0     +1     +1     +1     +1
```

**CArray** holds one array per term, exactly: each waits as an array until it is combined.

**`fuse` walked** answers to the shape rather than the size, and the shape is which way the tree leans: a binary operation pulls its left operand into the buffer it was handed and takes a scratch only for its right, so leaning left descends for free and leaning right holds one buffer per level. The two rows are the same arithmetic written two ways, and they are not the same measurement. The scratch comes from an arena that keeps buffers warm rather than freeing them, so the peak is also what is still held afterwards.

**`fuse` compiled** holds the result and nothing else: one array, whatever the expression says and whichever way it leans -- there is no operand to stage when every operation is in one loop.

**A compiled kernel** holds nothing at all, because it was given the array to write into: a value never leaves a register between one operation and the next.

Only the columns are comparable, not the rows against some other program's numbers: a peak belongs to a process, and the floor moves with whatever it loaded and allocated first.

| | needs | passes | intermediates | reaches a neighbour |
| --- | --- | --- | --- | --- |
| `a + b * c` | -- | one per operation | one per operation | -- |
| `CArray.fuse`, walked | -- | one per operation | one per right-spine level | -- |
| `CArray.fuse`, compiled | a C compiler, or it walks | **one** | **none** | -- |
| `CArray.jit_each` | a C compiler | **one** | **none** | no |
| `CArray.jit_for` | a C compiler | **one** | **none** | **yes** |

The last two need a compiler outright: without one they raise rather than run slowly, because a block written for them is written to be compiled and a Ruby loop over a million cells is not an answer.  `CArray.fuse` never raises for the want of one -- it asks whatever evaluator is registered and walks the expression itself when the answer is nobody, which is what makes it the thing to write where an expression over whole arrays is the whole of it.

The last two are the same machinery and differ in what can be said, not in speed: a recurrence, a stencil and a reduction are `jit_for`'s and are not one pass in any of the others -- they are not expressible in them at all.

What the table does not show is the compiling, which is about 250 ms the first time and 4 ms in a later process that finds the object on disk. For one pass over a small array the plain expression wins on wall clock and always will; see [What compiling costs](04_Compiling.md#what-compiling-costs-and-where-kernels-are-kept) for where the line falls.
