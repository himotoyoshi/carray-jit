# Getting started

The block's parameters are the loop indices. Arrays and scalars are the
variables it closes over -- `legendre` and `x` here -- so nothing is named
twice, and the body reads like the Ruby loop it replaces.

An extent is a `Range`, an `Integer` standing for `0...n`, or an
`Enumerator::ArithmeticSequence` -- what `(high - 1).step(low, -1)` returns --
one per index. A whole array is therefore
`CArray.jit_for(*array.dim) { ... }`.

```ruby
CArray.jit_for(1...(rows-1), 1...(columns-1)) { |i, j|
  out[i, j] = 0.25 * (src[i-1, j] + src[i+1, j] + src[i, j-1] + src[i, j+1])
}
```

`jit_for` returns the compiled kernel, whose `#c_source` is the C that ran.
So does `jit_each`, the sibling method for work that reaches no neighbour and
so needs neither an index nor an extent.  `jit_map` is that same method with
its value asked for, and returns the array of results instead.

[examples/applications/](../examples/applications) holds small programs that use
this to do something -- a Game of Life, an implicit heat equation, edge
detection, quality control on a sensor record -- each measured against the
Ruby loop or the array expression it replaces.
[examples/features/](../examples/features) is a tour of everything in these
docs, one
file per feature. `rake examples` runs them all.

## Where the methods come from

`CArray.jit_for`, `CArray.jit_each` and `CArray.jit_map` are named by CArray, which defines
them to raise: they say that they compile their block, that the compiler is
this gem, and that it is not installed. Installing it replaces them with the
ones that compile.

The name carries the rest. `jit_` says the block is read rather than run, and
so has rules about what may be in it; a method called `per_cell` would not,
and the subset would be something you found out about later. It also marks
which methods need the compiler and which do not: an expression over whole
arrays is `CArray.fuse`'s, and that one needs nothing installed.

The line between these two falls where the block's names fall -- a block that
names indices is `jit_for`'s, a block that names none is `jit_each`'s -- and
each turns the other's block away rather than quietly doing something with it.

## No fallback

A block outside the compilable subset raises `CArray::JIT::Unsupported`, and
so does one written with no compiler installed. Neither quietly runs the block
as a Ruby loop instead.

Nobody writes `jit_for` except to make a per-cell computation fast, so running
it a hundred times slower would answer a question that was not asked, and
would hide the difference behind a call that looks the same either way. An
expression that can be written without a loop is better written as
`CArray.fuse`, which is one pass with or without this gem.
