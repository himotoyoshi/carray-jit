# Changelog

Releases are recorded here from 0.1.0, which is the first.

<!-- Newest first, at both levels: a new release section goes above the
     ones below it, and a new entry goes directly under its own release
     heading -- not at the end of the section. The kind of change is
     carried by the `- Fix:` / `- Change:` / `- New:` that opens the
     entry; there are no per-kind subheadings.

     An entry says three things and stops: what changed, what to do about
     it (the migration, the replacement, the condition under which nothing
     changes), and what is excluded. It does not say how the code was
     broken, name the internals that were fixed, break down where the
     speed came from, or argue the design -- those belong in the commit
     message. Two to six lines.

     The version here is this gem's own and is not CArray's. Which CArray
     a release needs is said in the gemspec, and an entry says so only
     when the answer changes. -->

## 0.1.0 (unreleased)

- New: `CArray.jit_for`, `CArray.jit_each` and `CArray.jit_map` compile their
  block rather than running it. The block is read with Prism, translated to C
  if it falls inside the recognized subset, compiled with the system C
  compiler and called through Fiddle. `jit_for` takes the loop extents and
  names the indices, so a cell may reach the ones around it -- a recurrence, a
  stencil written out; `jit_each` writes into arrays of yours and `jit_map`
  hands the value back, both at the cell with no index named. CArray 3.0.1
  defines these three names and raises there; installing this gem is what
  makes them compile.

- New: a block outside the subset raises `CArray::JIT::Unsupported`, naming
  the construct and where it is, rather than falling back to a Ruby loop.
  Nobody calls these methods except to make a per-cell computation fast, so
  quietly doing the slow thing would answer a question that was not asked.
  What the subset holds is in
  [docs/03_Blocks.md](docs/03_Blocks.md#the-recognized-subset).

- New: every operation in a kernel means what Ruby means by it -- integer
  division floors, `%` is not `fmod`, a Complex divides by Smith's method in
  the order `complex.c` writes it. The exception is the order a reduction
  takes its terms in: an accumulator is split into partial sums, which is
  faster and usually the more accurate answer. `reassociate: false` on
  `jit_for`, `CArray::JIT.reassociate = false`, or `CARRAY_JIT_REASSOCIATE=0`
  for a whole process, asks for the serial order, and then the kernel agrees
  with the Ruby loop bit for bit. `**` on a Complex is the one documented
  exception.

- New: `CArray.jit_stencil` runs a block over windows onto its arrays, with
  `border:` saying what happens at the edge -- `:mask` by default, because
  CArray can say "not computed" and a border of zeros cannot be told from
  zeros that were computed. `CArray.jit_contract` runs a contraction over a
  repeated index, summing over the indices that do not appear on the left.

- New: `CArray.jit_extern` names a C function someone else compiled by quoting
  its declaration, and `CArray.jit_function` compiles a body of your own. Both
  hand back an object a kernel calls by address rather than per cell through
  Fiddle, and either can be called from Ruby too.

- New: `CArray.fuse` is compiled where this gem is installed, without asking
  for it and without changing what it computes. The gem registers an
  expression evaluator with CArray at load; a program that only writes
  `CArray.fuse { ... }` gets the same answer with or without it.

- New: compiled kernels are cached on disk, in `~/.cache/carray-jit` unless
  `XDG_CACHE_HOME` or `CARRAY_JIT_CACHE` says otherwise, so a kernel is
  compiled once rather than once per run. Entries are kept apart by this gem's
  version, the CArray version they were built against, and the architecture:
  a kernel is handed CArray's memory, on layouts CArray decides, so one
  compiled against another version is rebuilt rather than reused.
  `CARRAY_JIT_NO_CACHE` keeps the cache in a temporary directory that goes
  away with the process, and `CARRAY_JIT_CC` names a different compiler.

- New: the `carray-jit` command reports and looks after that cache --
  `status`, `list`, `show`, `clear`. It loads the compiler and nothing else,
  so a cache can be inspected or cleared when CArray itself will not load.

- New: needs CArray 3.0.1 or later in the 3.0 series, and Ruby 3.2 or later.
  The floor is where `ca_call_cslab_N`, the expression evaluator hook,
  `__kernel_body__` and `BUILD_FLAGS` arrive. The ceiling is the next minor
  because a kernel reaches CArray's C by address and pastes its kernel bodies
  into generated C, neither of which the frozen author surface covers.
