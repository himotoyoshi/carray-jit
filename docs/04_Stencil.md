# Stencils

A stencil is every cell from the ones around it, and `jit_stencil` is the
spelling where the loop is implied:

```ruby
smoothed = CArray.jit_stencil(image) { |a|
  0.25 * (a[-1, 0] + a[1, 0] + a[0, -1] + a[0, 1])
}
```

The arrays are given rather than closed over, and the block's parameters are
windows onto them, in that order. `a[0, 0]` is the cell the loop is on and
`a[-1, 1]` its neighbour, so the offsets are the stencil as it is drawn. The
block's value is what the cell gets, as `jit_map`'s is, and what comes back is
an array of the same shape.

The offsets are written out — a literal, or arithmetic over literals — because
the radius has to be known before the loop runs; see [what is not a
stencil](#what-is-not-a-stencil). The weights need not be:
`w[-1] * coef[0] + w[0] * coef[1]` reads those from an array like any other
captured value.

Written with the indices named, the same thing is
[`jit_for`](03_Extents.md)'s:

```ruby
rows, columns = image.dim
smoothed = CArray.double(rows, columns)
CArray.jit_for(1...(rows-1), 1...(columns-1)) { |i, j|
  smoothed[i, j] = 0.25 * (image[i-1, j] + image[i+1, j] +
                           image[i, j-1] + image[i, j+1])
}
```

What the window is for is not the four lines. It is the border.

## The border is an argument

With the indices named, what `image[i-1, j]` means at `i = 0` has nowhere to
be said. So the extents say it by not going there, and the border keeps
whatever the output array held — zeros, usually, which cannot be told from
zeros that were computed. A window has nowhere to write an index and so has
somewhere to put the question:

```ruby
CArray.jit_stencil(image, border: :mask)    # the cell is UNDEF        (default)
CArray.jit_stencil(image, border: :skip)    # the cell is left as found
CArray.jit_stencil(image, border: :zero)    # a read outside gives 0
CArray.jit_stencil(image, border: :clamp)   # a read outside gives the nearest cell
CArray.jit_stencil(image, border: :wrap)    # a read outside comes back the other side
```

The default is `:mask` because CArray can say "not computed", and that is
what those cells are. `:skip` is the older spelling's behaviour, for when the
border is yours to fill.

The other three are answers about the read rather than about the cell, so the
border cells are computed after all — `:wrap` is what makes a Game of Life
board a torus, and `:clamp` what an image filter usually wants at the edge.

## What it costs

Two loops, not one with a question in it. The interior is the loop the
written-out spelling compiles to, with nothing about the border in it; the
frame is walked afterwards, by the same statements with the rule woven into
their reads. Over a 2000x2000 five-point stencil:

```
  jit_for over the interior, by hand      1.13 ms   0.28 ns/cell
  jit_stencil, border: :skip              1.13 ms   0.28 ns/cell
  jit_stencil, border: :clamp             1.19 ms   0.30 ns/cell
  jit_stencil, border: :wrap              1.20 ms   0.30 ns/cell
  the same clamp written inside one loop  3.20 ms   0.80 ns/cell
```

The window costs nothing to run: the interior is the same loop, and the same
answer bit for bit. The border costs about five per cent, because the frame is
0.2% of the cells — and writing the same rule into the one loop costs 2.7x,
because then every cell pays for what only the frame needed.

## Several arrays, and everything else

Each array given gets a window, in the order the block names them; the names
shadow whatever they hold outside, as `CArray.fuse`'s do.

```ruby
CArray.jit_stencil(u, k) { |u, k| u[0,0] + k[0,0] * (u[-1,0] + u[1,0] - 2.0*u[0,0]) }
```

An array the block closed over rather than was given has no window, and is
read at the cell — what a bare name means wherever the loop is this
compiler's. A captured scalar is a scalar.

A missing cell reaches as far as the window does: `a[-1, 0]` over a cell whose
neighbour is UNDEF gives UNDEF, which is the propagation the rest of this
compiler already does.

## The array that comes back

Typed from the block's value, as `jit_map`'s result is, unless you say
otherwise:

```ruby
CArray.jit_stencil(image, type: :float32)      # collect into float32
CArray.jit_stencil(image, into: edges)         # write into an array of yours
```

`into:` takes an array of the stencil's own shape and returns it; the type is
then that array's. Passing both is refused — the array already says what type
it is.

## What is not a stencil

- **A computed offset.** `a[k, 0]` where `k` is a value is refused: the
  offsets are what the radius is read from, and the radius is what lets the
  interior be walked without asking, at every cell, whether it is still
  inside. A subscript the kernel works out is [`jit_for`](03_Extents.md)'s,
  and so is a window whose width is decided when the program runs.

  Arithmetic over literals is not a computed offset — `a[-1-1, 0]` is
  `a[-2, 0]`, folded where the block is read, and a stencil drawn from a
  formula is usually written that way. What may not appear is anything that
  has to be *read* to be known, a captured integer included: those arrive
  with the call, and one compiled kernel serves every value of them, so a
  window built from one would have a radius the loop does not know.
- **A recurrence.** `smoothed[i] = alpha * price[i] + (1-alpha) * smoothed[i-1]`
  reads a cell this loop wrote. A window reads the array as it was, so that
  is not a stencil however much it looks like one — it is `jit_for`'s, and the
  direction of its extent is what records the dependency.
- **Writing.** A stencil produces a value. A block that writes several arrays
  is [`jit_each`](07_ElementWise.md)'s.
- **Arrays of different shapes.** They must agree; a stretched axis has no
  neighbour to reach.
