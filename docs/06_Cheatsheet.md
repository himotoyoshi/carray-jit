# Cheatsheet

Eight entry points: the seven `jit_` methods this gem puts on `CArray`, and
`CArray.fuse`, which is CArray's own and gets the compiler from this gem being
installed. Every example here runs as written.

## Which one

| What you are doing | Write |
|---|---|
| An expression over whole arrays | `CArray.fuse` |
| The same, in one pass with no intermediates | `CArray.jit_each` |
| The same, and you want the result back | `CArray.jit_map` |
| A cell reads its neighbours, or the one computed before it | `CArray.jit_for` |
| A cell reads a window, and the edge needs a rule | `CArray.jit_stencil` |
| An index repeats and is summed | `CArray.jit_contract` |
| An index repeats and is *not* summed -- a point number, a batch | `CArray.jit_contract(:p)`, naming the result's axes |
| Call a C function someone else compiled | `CArray.jit_extern` |
| Compile a C function of your own | `CArray.jit_function` |

The dividing line among the first four is **what reaches what**. Element-wise
work reaches no neighbour, so it names no index and needs no extent. A cell
that reaches another cell has to say which one, which is what an index is for.

---

## Whole arrays

```ruby
out[] = CArray.fuse { a + b * 2 }
```

Needs no compiler. Without this gem CArray walks the expression; with it, the
expression is compiled instead, without being asked and without changing the
answer. An expression the compiler cannot address goes back to CArray. This is
the only entry point here that is not `jit_`-prefixed, and the only one that
works with no compiler on the machine.

## Cell by cell

```ruby
CArray.jit_each { out = a + b * 2 }        # writes; returns the kernel
larger = CArray.jit_map { a > b ? a : b }  # returns a new array
```

Arrays are the names the block closes over -- nothing is named twice. Every
name is a *cell*: `out = ...` writes the cell of the array `out` names outside.
A name that is not an array out there is an ordinary local.

`jit_each` writes and hands back the kernel; `jit_map` allocates the result,
typed from the block's last value, and hands that back. Neither takes block
parameters.

## Naming the index

```ruby
CArray.jit_for(1...6) { |i| x[i] = x[i-1] * 2 }
```

The parameters are the loop indices and the arguments are their extents, one
each, an Integer `n` standing for `0...n`. Naming an index is what lets a cell
reach `x[i-1]`, and reaching a cell the kernel will later write is what fixes
the direction the axis runs -- derived from the dependencies, not chosen.

An inner loop counts up with `(a...b).each` or `n.times`, and by a stride with
`a.step(b, s)` -- `(n-1).step(0, -1)` for a sweep back down a row. Its index
addresses writes as well as reads, which is a cell's own workspace:

```ruby
CArray.jit_for(rows) { |i|
  (0...width).each { |k| work[i, k] = ... }          # fill the row
  (width-1).step(0, -1) { |k| ... work[i, k] ... }   # and walk back down it
}
```

`x.nan?` and `x.finite?` are the guards; `infinite?` is refused, answering
nil or ±1 rather than a boolean.

An operator assignment is the assignment it stands for: `total += a[i]`,
`work[i, k] *= 2.0`, `counts[bin[i]] += 1`.

`reassociate:` says whether a reduction's accumulator may be split into partial
sums. Default is `CArray::JIT.reassociate` (`true`). Pass `false` for the
serial order -- a compensated summation, or checking against the loop.

## Windows

```ruby
smoothed = CArray.jit_stencil(image) { |a|
  0.25 * (a[-1, 0] + a[1, 0] + a[0, -1] + a[0, 1])
}
```

Arrays are **given**, not closed over, and the parameters are windows onto them
in that order: `a[0, 0]` is the cell, `a[-1, 1]` a neighbour. The block's value
is what the cell gets.

| Keyword | Meaning |
|---|---|
| `border: :mask` | a cell whose window falls off is `UNDEF` -- not computed (default) |
| `border: :skip` | that cell is left as it was found |
| `type:` | the data type to collect into; without it, the block's value's |
| `into:` | write into an array of yours, which then decides the type |

`type:` and `into:` together are refused.

## Contraction over a repeated index

```ruby
c = CArray.jit_contract { |i, j, k| a[i,k] * b[k,j] }   # a matrix product
    CArray.jit_contract { |i, j, k| c[i,j] = a[i,k] * b[k,j] }
n = CArray.jit_contract(:p) { |k| x[p,k] * y[p,k] }    # the axes named: one per point
d = CArray.jit_contract(:a) { q[a,a] }                 # the diagonal, not the trace
```

**An index that repeats is summed**, however often it repeats. One that appears
once is free and becomes an axis of the result, in the order the block named
them -- so `{ |j, i, k| ... }` is the transpose. **An index named in the
arguments is free however often it appears**, which is the third clause and
what puts the diagonal and the per-point quantity here rather than in a loop.

Naming one axis names them all: the argument list is the result's axes and
their order, so a parameter left at a single position is refused there as it is
under the convention. No extent is given: each index's extent comes from the
axes it addresses. The sum is split into partial sums, as `jit_for`'s reduction
is -- `CArray::JIT.reassociate = false` is the serial order, and a contraction
has no per-call licence of its own.

Assigning into an array of yours says where to put it and in what order its
axes lie. It does **not** decide what is summed -- so `total[i] = a[i,k]` is
refused, because nothing in `a[i,k]` stands in for a sigma. That is `sum(axis:)`.

## C functions

```ruby
j0 = CArray.jit_extern("double j0(double)", from: "libgsl")
sq = CArray.jit_function("double (*)(double)") { |t| t * t }

CArray.jit_each { out = j0.call(x) }
```

`jit_extern` compiles nothing -- Fiddle finds the address, and the kernel calls
it directly rather than reaching it per cell through Fiddle. `from:` names the
library; `nil` searches the process. `jit_function` compiles a body of your
own, callable from a kernel, from Ruby, and by a C library that knows nothing
about either -- and from another `jit_function` body, which is the one thing
such a body may reach outside its parameters.

A signature is written in C's own spellings: `float` and `double`, the
exact-width integers `int8_t`..`int64_t` and `uint8_t`..`uint64_t`, and the
platform's own words `size_t`, `ssize_t`, `ptrdiff_t`, `intptr_t` and
`uintptr_t`. A word is whatever the platform made it, so `size_t` computes as
a `uint64` and `size_t counts[]` takes a `uint64` array where that word is 64
bits; `uint64_t` is the spelling that says the width itself.

---

## What comes back

| Method | Returns |
|---|---|
| `fuse` | a lazy expression; assign it to materialise |
| `jit_each` | `CompiledKernel` -- the value is in the arrays it wrote |
| `jit_map` | a new `CArray`, typed from the block's value |
| `jit_for` | `CompiledKernel` |
| `jit_stencil` | `into:` when given, otherwise a new `CArray` |
| `jit_contract` | a new `CArray`, or the `CompiledKernel` when the block assigns |
| `jit_extern` | `CFunction` |
| `jit_function` | `CFunction` |

Every `CompiledKernel` answers `#c_source` with the C that ran.

## Compiler required

| | Without a C compiler |
|---|---|
| `fuse` | works -- CArray walks it, same answer |
| the seven `jit_` methods | `CArray::JIT::Unsupported` |

That is what the prefix says. A block outside the subset is refused by name and
line rather than run as a Ruby loop: nobody reaches for a compiler except to
make something fast, so quietly doing the slow thing would answer a question
that was not asked.

## What gets refused

| | |
|---|---|
| `jit_for` with a block naming no index | element-wise -- that is `jit_each` |
| `jit_each` / `jit_map` with block parameters | an index means `jit_for` |
| `jit_stencil` with no array given | the arrays are arguments, not closures |
| `jit_stencil` with both `type:` and `into:` | `into:` already decides the type |
| a contraction summing an index that appears once | name the axes; with nothing named it is free |
| a left-hand axis the argument list leaves out | the list is all of the result's axes |
| an index whose axes disagree in extent | the shape check a contraction exists to do |
| an array both written and read in a contraction | a recurrence -- write it with `jit_for` |
| a block naming a construct outside the subset | refused by name and line |

## Knobs

```ruby
CArray::JIT.reassociate          #=> true, for jit_for reductions and every contraction
CArray::JIT.reassociate = false  # serial accumulation everywhere

CArray::JIT.cache_directory      #=> ~/.cache/carray-jit/<version>
CArray::JIT.cache_root = "tmp/jit"   # this application keeps its own
CArray::JIT.cache_entry_count
CArray::JIT.cache_byte_size
CArray::JIT.clear_cache
```

A kernel is compiled once: the shared object is cached on disk, keyed by the
generated C and the compiler that built it, so a later process finds it there.
See [Compiling, caching and inspecting](04_Compiling.md).
