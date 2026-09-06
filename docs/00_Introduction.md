# Introduction

carray-jit compiles a Ruby block into a C kernel that runs over CArray arrays. The block is not evaluated and is not a DSL: it is ordinary Ruby, read as source, translated to C, compiled by the system C compiler and called through Fiddle. What it computes is what the same block would have computed had Ruby run it, one cell at a time, at the speed of compiled C.

## What CArray leaves out

CArray works on a whole array at once. Arithmetic and the mathematical functions apply to every element, reductions summarise along the axes you name, and sorts and scans walk the data in C. All of that is already fast, and nothing here replaces it.

What an array expression has no form for is a computation *between* elements. A cell that reads its neighbours. A cell that depends on the one computed before it. A loop whose length is not known until it runs. These are ordinary algorithms — a tridiagonal solve, a stencil with the boundary rule your problem actually has, a sieve, a recurrence from a paper — and until now writing one in Ruby meant a Ruby loop, and paying what the interpreter charges for every element.

This library is for that gap. The parts of an algorithm that have an array form stay with CArray, where they are fastest; the part that does not becomes a kernel. Together they run an algorithm end to end without dropping into a Ruby loop.

## A subset, chosen rather than found

Not every Ruby block can become C. What may appear in one is a subset — arithmetic and comparison, locals, `if` and `while`, inner loops, subscripts at computed positions, the bitwise operators, the `Math` family, `raise` — and it was chosen deliberately, wide enough to state a numerical algorithm and narrow enough that each construct in it means in C exactly what Ruby means by it. Integer division floors. `%` is not `fmod`. A Complex divides by Smith's method in the order `complex.c` writes it.

A block that steps outside the subset is refused, by name and with a line number, rather than quietly running as a Ruby loop. Nobody reaches for a compiler except to make something fast, so falling back silently would answer a question that was not asked.

## Where a kernel gets its data

A kernel reads and writes CArray arrays directly, in the memory CArray already holds them in. The arrays are the ones the block closes over, so nothing is named twice. Views are cells like any other — a column, a transpose, a slice of a slice — and are written in place without a copy. Masks propagate as CArray propagates them, and a kernel can ask whether a cell is missing.

A kernel can also call C. `jit_extern` binds a function from any library Fiddle can open, and the kernel calls it at its address rather than reaching it per cell through Fiddle; `jit_function` compiles one from a Ruby block of your own and hands back a pure C function pointer, which a kernel can call, Ruby can call, and a C library that knows nothing about either can be given.

Compiling costs something the first time and nothing afterwards: the shared object is cached on disk, keyed by the generated C and the compiler that built it, so a kernel is compiled once and reused by every later run.

## Not only the blocks you write

Installing this gem also puts the compiler behind `CArray.fuse`. An array expression written there is compiled rather than walked a node at a time — without being asked for, and without changing the answer. An expression the compiler cannot address goes back to CArray, which walks it and arrives at the same result. So a program that never writes a kernel still gets something from having the gem installed.

## How this guide is arranged

* [Getting started](01_GettingStarted.md) — the block, its extents, what the three methods return, and where a kernel stands beside `a + b * c` and `CArray.fuse`
* [The shapes a kernel takes](02_KernelShapes.md) — work that reaches no neighbour, extents and subscripts, stencils, reductions, and contraction over a repeated index
* [Supported features](03_SupportedFeatures.md) — locals and types, branches, raising, the types that are not just a number, calling C, and the recognized subset with what it refuses
* [Compiling, caching and inspecting](04_Compiling.md) — what the first call costs, where kernels are kept, reading the generated C, the `carray-jit` command, and what the suite checks
* [Design notes](05_DesignNotes.md) — decisions that were not obvious, and why
* [Cheatsheet](06_Cheatsheet.md) — the seven `jit_` methods and `CArray.fuse` on one page, to look up rather than to read

[examples/features/](../examples/features) is a tour of the same ground, one file per feature, and [examples/applications/](../examples/applications) holds small programs that use it to do something.
