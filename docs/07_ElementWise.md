# `jit_each` and `jit_map`, when nothing reaches a neighbour

Naming an index is what lets a kernel reach a neighbouring cell, and reaching
a neighbouring cell is what makes the range and the direction matter. A
computation that reaches none needs none of that, so it names no index, takes
no extent, and has a method of its own:

```ruby
CArray.jit_each { out = a + b * c }
```

That right-hand side is what the expression already means in CArray, written
exactly as it would be written anywhere else. What changes is not the
expression but how it runs: at the cell, in one pass, instead of three passes
with two arrays in between.

The assignment is Ruby's own. Every name in the block is a cell -- the loop
is this compiler's and is not written here -- so `out = ...` writes the cell
of the array `out` names outside, and a name that is not an array there stays
a local of the block's. `out[] = ...` was the spelling from when the block had
to run as Ruby, `[]=` being the only way Ruby has to say "the whole array";
the block is read rather than run, so it is refused now and says this. `a[]`
is still accepted on the right, and says what the bare name says.

### A `CScalar` is a value with a home

`CScalar` is the one-cell `CArray` it subclasses, minus the index: `s[]` is
the value, and `s[] = ...` puts one back. CArray's own operators read that one
cell for every cell of everything else, and so does this:

```ruby
gain = CScalar.double() { 2.0 }
CArray.jit_each { out = signal * gain }        # gain read at every cell
CArray.jit_each { gain = gain + 0.5 }          # and written like any cell
```

An indexed kernel reaches it too, and there the missing index is the whole
point: `s[]` and a bare `s` both mean the value, because there is no axis to
walk and so no index to write.

```ruby
CArray.jit_for(n) { |i| out[i] = signal[i] * gain[] }
```

The two routes differ in how they get there. `jit_each` stretches it as it
stretches a one-cell `CArray` -- a stride of zero -- while `jit_for` reads it
where it lies. They compute the same thing, and `s[0]` keeps working in both,
since it is still the one-cell array it is. Writing a wider expression into
one is refused, with the shapes named, exactly as CArray refuses it.

The other method is the same block with its value asked for:

```ruby
sums = CArray.jit_map { a + b }
```

The last statement is what every cell of the result gets, so there is no
output array to name and the result comes back typed from that value rather
than from the arrays. The name is the whole of the difference: the block is
read the same way, and what it may do is the same.

An assignment is a statement with a value -- Ruby's rule, not a special case
here -- so `CArray.jit_map { out = a + b }` writes `out` and hands the same
value back. Which is why the two methods are split by what returns rather than
by what is written: writing is the block's business either way.

It is the same shape of block `CArray.jit_function` takes, and not the same
thing. There, the loop belongs to whoever calls the function, so the body is
reached through a pointer and may close over nothing. Here the loop is this
compiler's and the body is inlined into it, so it costs no call and may reach
a captured value, a `Math` function or a bound C function like any other
kernel body.

### Who drives the loop

An element-wise pass is the one shape that is a *sweep* -- nothing reaches a
neighbour, nothing chooses an order -- so CArray can drive it instead. Where
this CArray has `ca_call_cslab` (3.0.1 and later), `jit_each` hands it the
compiled body and lets it acquire the operands.

The body is the same either way. The sweep entry point is a wrapper that calls
the same kernel with the chunk as its bounds, so what changes is who opens the
arrays, not what they compute.

What that is worth is memory. An operand CArray cannot walk in place -- a
gather, a lazy array -- is re-gathered 32KB at a time by the sweep, where the
tiers here move the whole box the kernel touches, and for an element-wise pass
that box is the whole array. Over two million doubles with a gather view as an
operand, both take about 1.3 ms and one of them holds sixteen megabytes of
scratch while the other holds thirty-two kilobytes. With entity operands the
two are indistinguishable, so there is nothing to weigh.

A **strided view** is the case where there is. A column, a transpose, every
other cell: the tiers address those in place, with no gather and no scatter,
so the sweep's re-gather has no whole-array copy to save you from and costs
what it costs. Over two million doubles, `0.42 ns` a cell walked in place
against `4.7 ns` swept, and no scratch either way. So the driver is chosen on
the operands as well as the shape -- the sweep runs where some operand has to
be moved whatever happens, and where none of them does.

The rank does not stand in the way, and the arrays are not reshaped to get it
out of the way. CArray's acquire reads an operand's element count and element
size and never looks at its shape, so a chunk is already a flat run of cells;
what has to be flat is the *kernel*, and it is compiled at rank one over the
same cells rather than as a nest over the axes. One such kernel then serves
whatever rank it is given, because the rank has left the loop.

Four things keep the driver here. An operand that is a **strided view**, for
the reason just measured: it is walked in place here, and re-gathered there
for nothing. A **stretched operand**, which is the one thing that cannot be
flattened: broadcasting arrives as a stride of zero on an axis, and a flat run
has no axes, so cell k of the output would stop lining up with cell k of the
operand. A body that **asks about a mask**, because a chunk
carries no per-cell mask to ask it of -- CArray ORs and propagates the masks,
but `a[i] == UNDEF` is a question about one cell. And a CArray **without the
family** at all, which is asked for by symbol rather than assumed, so an older
one falls back without the caller hearing about it.

`jit_for` never goes this way, and that is not a limitation: a kernel that
names an index reaches neighbours, chooses an order and runs inner loops, none
of which a chunked walk can offer. The two names mark the same line.

The two methods are one machinery and two names, and the names are the point:
"cell" is a position, which is what a block names when it can reach the
positions around it, and "element" is what CArray calls the same work done
cell by cell with no neighbour in it. Each method's block is turned away by
the other rather than quietly reinterpreted.

Shapes are broadcast the way CArray broadcasts them, which costs nothing here:
a stretched axis comes back as a stride of zero, and the kernel addresses by
stride anyway. The rank comes from the arrays rather than from the block, so
one expression serves whatever shape it is given.

CArray has its own answer to the intermediate arrays:
`CArray.fuse { a + b * c }` builds the expression as a structure rather than
as arrays, reading the names from where the block was written. Walked by
CArray that holds the intermediates to one buffer per level of the
expression's right spine rather than removing them -- see the table in
[Four ways](02_FourWays.md) --
and it leaves the passes alone: each operation is still its own walk over the
data.

Where this gem is installed, though, `fuse` does not walk: it is registered as
CArray's expression evaluator, and a fused expression is compiled into one
kernel like any other. So there are two fuse rows, and the difference between
them is this gem:

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

Walked, `fuse` earns more as the expression grows -- there are more
intermediates it is not allocating -- but it still grows, because the passes
are still there. Compiled, neither row grows: the expression is read once
whatever it says.

What is left between the last two is not speed. `jit_each` is handed the array
to write into, where `fuse` returns the expression and allocates when it is
asked for an array; and a block can say what an expression cannot -- a cell
reaching its neighbours, a loop written out, a reduction. Where an expression
over whole arrays is the whole of it, `fuse` is what to write, and this gem
makes it faster without being named.
