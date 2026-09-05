# carray-jit

JIT compilation of CArray kernels written in Ruby.

This library was written so that an algorithm CArray alone cannot express --
one that leaves no choice but a Ruby loop -- runs fast. The loop is written as
a block in a carefully chosen subset of Ruby, compiled to a C kernel over
CArray arrays, and run at native C speed: a cell that reads its neighbours, a
recurrence, a loop written out. CArray already has C kernels for arithmetic,
reductions, sorts and scans, and those remain faster than the same thing
written here. Combining them with a kernel for the part that has no array
form is what makes a whole algorithm fast.

The block is read with Prism, translated to C if it falls inside that subset,
compiled with the system C compiler and called through Fiddle. The compiled
object is cached on disk, so a kernel is compiled once.

## Status

Prototype.

## Features

- **The block is ordinary Ruby**, read with Prism rather than evaluated or
  assembled from a DSL, and every operation in it means what Ruby means by it.
- **It covers the shapes an array expression has no form for** -- recurrences,
  in whichever direction the dependencies require; stencils at any rank, with
  the edge named rather than left out; reductions as an inner loop per output
  cell; contractions in Einstein's convention; and element-wise passes in one
  go, with no intermediate arrays.
- **Views and masks are cells like any other.** A matrix column, a transpose,
  a slice of a slice, written in place without a copy. Masks propagate as
  CArray propagates them, and `a[i] == UNDEF` asks outright.
- **C functions are called by address.** `j0.call(x)` inside a kernel, bound
  from any library Fiddle can open, or written in Ruby and compiled to a pure
  C function pointer to hand back out.
- **A kernel is compiled once.** The shared object is cached on disk, keyed by
  the generated C, the compiler and its flags.
- **Nothing happens silently.** A block outside the subset raises rather than
  running as a Ruby loop, and the C that ran is there to read.

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

Every operation in the block means what Ruby means by it -- integer division
floors, `%` is not `fmod`, a Complex divides by Smith's method in the order
`complex.c` writes it. The exception is the order a reduction takes its terms
in: the accumulator is split into partial sums, which is faster and usually
more accurate. `reassociate: false` asks for the serial order, and then the
kernel agrees with the Ruby loop bit for bit. (`**` on a Complex is the one
documented exception; see [Complex arrays](docs/03_Blocks.md#complex-arrays).)

`CArray.jit_for`, `CArray.jit_each` and `CArray.jit_map` are CArray's own
names: without this gem they raise and point at `CArray.fuse`, which computes
an array expression without a compiler. This gem is the compiler. An
expression over whole arrays wants `CArray.fuse` and not these, and gets
compiled anyway where this gem is installed.

## Documentation

* [Getting started](docs/01_GettingStarted.md) — the block, its extents, what the three methods return, and where a kernel stands beside `a + b * c` and `CArray.fuse`
* [The shapes a kernel takes](docs/02_Shapes.md) — work that reaches no neighbour, extents and subscripts, stencils, reductions, and Einstein's convention
* [What may be in a block](docs/03_Blocks.md) — locals and types, branches, raising, the types that are not just a number, calling C, and the recognized subset with what it refuses
* [Compiling, caching and inspecting](docs/04_Compiling.md) — what the first call costs, where kernels are kept, reading the generated C, the `carray-jit` command, and what the suite checks
* [Design notes](docs/05_DesignNotes.md) — decisions that were not obvious, and why

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
exact rather than within a tolerance, is in [Testing](docs/04_Compiling.md#testing).

## Contributing

Bug reports and feature requests are welcome — please open an issue.

## Credits

carray-jit was designed and reviewed by a human developer; the implementation
was produced in collaboration with AI coding tools.

## License

MIT
