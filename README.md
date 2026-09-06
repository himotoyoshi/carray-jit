# carray-jit

JIT compilation of CArray kernels written in Ruby.

This library was written to make explicit, cell-by-cell work on CArray arrays fast. A subset of Ruby chosen for numerical computation is JIT-compiled and evaluated as a C-level loop over CArray arrays: a cell that reads its neighbours, a recurrence, a loop written out. The aim is to combine that with CArray's already fast vectorized arithmetic and reductions, and so speed up numerical computation with CArray as a whole.

The block is read with Prism, translated to C if it falls inside that subset, compiled with the system C compiler and called through Fiddle. The compiled object is cached on disk, so a kernel is compiled once.

## Status

A companion gem to CArray, and it follows CArray. The surface is not settled until CArray 3.1.

## Features

- **A JIT compiler for C-level loops.** A block becomes one C function over CArray's own memory, built by the system C compiler and called through Fiddle.
- **Ordinary Ruby, and enough of it.** The source is parsed with Prism -- no DSL, no `eval` -- and every operation means what Ruby means by it, apart from the order a reduction takes its terms in. The subset is enough to state a numerical algorithm; what falls outside it is refused by name and line, not run as a Ruby loop.
- **A method for each shape.** `jit_for` for recurrences and loops written out, `jit_stencil` for windows at any rank, `CArray.jit_contract` for contraction over a repeated index, `jit_each` and `jit_map` for a pass that reaches no neighbour.
- **View- and mask-aware.** Columns, transposes and slices of slices are written in place without a copy, and masks propagate as CArray propagates them.
- **Pure C functions, in and out.** `jit_extern` binds one from a library and a kernel calls it by address; `jit_function` compiles one from a block and hands back a C function pointer.
- **The backend for `CArray.fuse`.** An array expression compiles instead of being walked a node at a time, without being asked and without changing the answer.
- **Compiled once, across processes.** The shared object is cached on disk and reused by later runs.

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

## Example

```ruby
# Legendre polynomials at x = 0.5, by the recurrence that defines them.
# No array expression states this: P[i] needs P[i-1], which the same
# loop has just written.

x = 0.5
legendre = CArray.double(24)
legendre[0] = 1.0                     # P_0(x) = 1
legendre[1] = x                       # P_1(x) = x

CArray.jit_for(2...24) { |i|          # i is the loop index: 2, 3, ... 23
  w  = x * legendre[i-1]              # a block local; its type is inferred
  wy = w - legendre[i-2]              # reaching back two cells
  legendre[i] = wy + w - wy/i         # the cell this pass writes
}

legendre[0..5].to_a
#  => [1.0, 0.5, -0.125, -0.4375, -0.2890625, 0.08984375]
```

`CArray.jit_for`, `CArray.jit_each` and `CArray.jit_map` are CArray's own names: without this gem they raise and point at `CArray.fuse`, which computes an array expression without a compiler. This gem is the compiler. An expression over whole arrays wants `CArray.fuse` and not these, and gets compiled anyway where this gem is installed.

## Documentation

* [Introduction](docs/00_Introduction.md) — what carray-jit is: the gap it fills beside CArray, the subset a block is written in, and where a kernel gets its data
* [Getting started](docs/01_GettingStarted.md) — the block, its extents, what the three methods return, and where a kernel stands beside `a + b * c` and `CArray.fuse`
* [The shapes a kernel takes](docs/02_Shapes.md) — work that reaches no neighbour, extents and subscripts, stencils, reductions, and contraction over a repeated index
* [What may be in a block](docs/03_Blocks.md) — locals and types, branches, raising, the types that are not just a number, calling C, and the recognized subset with what it refuses
* [Compiling, caching and inspecting](docs/04_Compiling.md) — what the first call costs, where kernels are kept, reading the generated C, the `carray-jit` command, and what the suite checks
* [Design notes](docs/05_DesignNotes.md) — decisions that were not obvious, and why
* [Cheatsheet](docs/06_Cheatsheet.md) — the seven `jit_` methods and `CArray.fuse` on one page, to look up rather than to read

## Contributing

Bug reports and feature requests are welcome — please open an issue.

**Before opening a pull request, read [CONTRIBUTING.md](CONTRIBUTING.md).** It is short, and it says which form a contribution is best sent in. A small, self-contained bug fix is fine as a pull request. Anything larger is better started as an issue: code here gets rewritten as a matter of course, so a patch for a larger change is likely to end up reimplemented rather than merged, and describing the problem gets you further than writing one.

## Credits

carray-jit was designed and reviewed by a human developer; the implementation was produced in collaboration with AI coding tools.

## License

MIT
