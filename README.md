# carray-jit

JIT compilation of per-cell CArray kernels. Write the loop in Ruby, and it
runs at the speed of C.

## Status

Prototype.

## What it is for

CArray has kernels for the operations someone already wrote in C: arithmetic,
reductions, sorts, scans. Those are fast, and this does not replace them --
`sum(axis: 1)` beats a hand-written sum here, and BLAS beats a hand-written
matrix multiply.

What this is for is the operations nobody wrote in C. A tridiagonal solve, a
domain-specific recurrence, a stencil with the boundary rule your problem
actually has. Until now those left two choices: write the loop in Ruby and
accept 100x, or write a C extension gem. There was nothing in between.

The Thomas algorithm is fifteen lines of Ruby here, and runs at 9.3 ns per
element -- against 700 ns for the same loop interpreted, and within a factor
of two of LAPACK's `?gtsv`, which solves a harder problem. That is the whole
claim: not a faster CArray, but a shorter road from an algorithm to a fast
one.

## Features

- **recurrences** -- each cell from the ones before it, in whichever direction
  the dependencies require
- **stencils** -- each cell from its neighbours, at any rank, with the edge
  named rather than left out: `jit_stencil(image) { |a| a[-1,0] + a[0,1] }`
- **reductions** -- inner loops per output cell, so sum, maximum, product and
  a matrix multiply are all just loops
- **contractions** -- `CArray.contract { |i, j, k| c[i,j] = a[i,k] * b[k,j] }`,
  Einstein's convention: an index appearing twice is summed
- **element-wise expressions** -- `jit_each { out = a + b * c }`, or
  `jit_map { a + b * c }` for the value back, in one pass, no intermediate
  arrays
- **views** -- a matrix column, a transpose, a slice of a slice, written in
  place without a copy
- **masks** -- propagated as CArray propagates them, and testable outright
  with `a[i] == UNDEF`
- **C functions** -- `j0.call(x)` inside the kernel, bound from any library
  Fiddle can open, called at C speed rather than through Fiddle; or written in
  Ruby and compiled, which gives a pure-C function pointer to hand back out

## Install

```
gem install carray-jit
```

Or add it to your `Gemfile`:

```ruby
gem "carray-jit"
```

Requires:

- Ruby >= 3.2
- CArray >= 3.0.1, < 3.1
- A C compiler
- Prism and Fiddle (both ship with Ruby; Fiddle is a bundled gem)

## Quick example

```ruby
x = 0.5
legendre = CArray.double(24)
legendre[0] = 1.0
legendre[1] = x

CArray.jit_for(2...24) { |i|
  w  = x * legendre[i-1]
  wy = w - legendre[i-2]
  legendre[i] = wy + w - wy/i
}
```

The block is parsed with Prism, translated to C if it falls inside a
recognized subset, compiled with the system C compiler and called through
Fiddle. It runs one to two orders of magnitude faster than the same loop
written in Ruby, and **every operation in it means what Ruby means by it** --
integer division floors, `%` is not `fmod`, a Complex divides by Smith's
method in the order `complex.c` writes it. What an implementation is free to
choose is the order a *reduction* takes its terms in, and it does: an
accumulator is split into partial sums, which is faster and usually the more
accurate answer. `reassociate: false` asks for the serial order instead, and
then the kernel agrees with the Ruby loop bit for bit. (`**` on a Complex is
the one documented exception; see
[Complex arrays](docs/12_Types.md#complex-arrays).)

`CArray.jit_for`, `CArray.jit_each` and `CArray.jit_map` are named by CArray, and say so
without this gem: called with no compiler installed they raise, and point at
`CArray.fuse`, which computes an array expression without one. What this gem
installs is the compiler. The `jit_` in the name is the warning that the
block goes to it, and that there are rules about what may be in it.

An expression over whole arrays wants `CArray.fuse` and not these -- it needs
no compiler, has no subset to stay inside, and gets compiled anyway where this
gem is installed. What these are for is what an expression cannot say: a cell
that reaches its neighbours, a recurrence, a loop written out.

## Documentation

* [Getting started](docs/01_GettingStarted.md) — the block, its extents, what the three methods return, and where they come from
* [Four ways to compute an expression](docs/02_FourWays.md) — where a kernel stands beside `a + b * c` and `CArray.fuse`, in time and in memory
* [Extents, steps and subscripts](docs/03_Extents.md) — which cells the loop touches and in which order, and what is checked before it runs
* [Stencils](docs/04_Stencil.md) — every cell from the ones around it, with the loop implied and the edge said at the call
* [Reductions](docs/05_Reductions.md) — an inner loop per output cell, and the order it takes its terms in
* [Contraction](docs/06_Contraction.md) — Einstein's convention: an index appearing twice is summed
* [`jit_each` and `jit_map`](docs/07_ElementWise.md) — the spellings for work that reaches no neighbour, a `CScalar`, and who drives the loop
* [Locals, types and postfix math](docs/08_Locals.md) — what Ruby having no types costs, and what it does not
* [Calling a C function](docs/09_CFunctions.md) — one bound from a library, or one of your own compiled from a block
* [Branches, and asking whether a cell is missing](docs/10_Branches.md) — `if` in statement position, and `a[i] == UNDEF`
* [Raising from a kernel](docs/11_Raising.md) — `raise "..."` in a block, and how the message gets back
* [Booleans, complex numbers, unsigned 64-bit and masks](docs/12_Types.md) — the types that are not just a number
* [The recognized subset](docs/13_Subset.md) — what may be in a block, and what is refused by name
* [Known limitations](docs/14_Limitations.md) — what it does not do, and the one thing worth doing next
* [Inspecting a kernel](docs/15_Inspecting.md) — reading the generated C, the `carray-jit` command, the environment variables
* [What compiling costs](docs/16_Compiling.md) — the first call, the cache, and where the objects are kept
* [Design notes](docs/17_DesignNotes.md) — decisions that were not obvious, and why
* [Testing](docs/18_Testing.md) — what the suite checks a kernel against, and the tridiagonal case it is built around

[examples/applications/](examples/applications) holds small programs that use
this to do something -- a Game of Life, an implicit heat equation, edge
detection, quality control on a sensor record -- each measured against the
Ruby loop or the array expression it replaces.
[examples/features/](examples/features) is a tour of the documentation above,
one file per feature. `rake examples` runs them all.

## Testing

```
rake test
rake benchmark
```

What the suite checks a kernel against, and why the float comparisons are
exact rather than within a tolerance, is in [Testing](docs/18_Testing.md).

## Contributing

Bug reports and feature requests are welcome — please open an issue.

## Credits

carray-jit was designed and reviewed by a human developer; the implementation
was produced in collaboration with AI coding tools.

## License

MIT
