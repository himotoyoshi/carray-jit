# Changelog

Releases are recorded here from 0.1.0, which is the first. There is no
separate NEWS file: this is where to look for what changed between the
version you have and a newer one.

<!-- Newest first, at both levels: a new release section goes above the
     ones below it, and a new entry goes directly under its own release
     heading -- not at the end of the section. The kind of change is
     carried by the `- Fix:` / `- Change:` / `- New:` that opens the
     entry; there are no per-kind subheadings.

     A section is written newest-first while the release is open, and
     sorted into New, Change, Fix when it closes -- in the same commit
     that drops `(unreleased)`. Within Change, the ones that ask the
     reader to change code come first. It is a reading order rather than
     a classification: where it is not obvious, either place will do.

     An entry says three things and stops: what changed, what to do about
     it (the migration, the replacement, the condition under which nothing
     changes), and what is excluded. It does not say how the code was
     broken, name the internals that were fixed, break down where the
     speed came from, or argue the design -- those belong in the commit
     message. Two to six lines.

     It is written for someone using the library, not someone working on
     it: with no NEWS file, this is what a reader consults before
     upgrading. An entry naming something only a C extension touches says
     so in its opening words.

     Every entry has to read on its own. Entries are looked at one at a
     time and move about within a section, so none may lean on a
     neighbour ("as well", "the kernel above") or leave unnamed the
     method, class or keyword it is about.

     The version here is this gem's own and is not CArray's. Which CArray
     a release needs is said in the gemspec, and an entry says so only
     when the answer changes. -->

## 0.1.3 (unreleased)

- New: a function compiled with `CArray.jit_function` may call another one
  compiled with `CArray.jit_function`, by the name the block reaches it by --
  `hypot = CArray.jit_function("double (*)(double, double)") { |a, b|
  root.call(a * a + b * b) }`. The called body is pasted into the caller's C
  and reached by symbol, so what comes back is still one self-contained
  object with one address, and a chain of any depth arrives together with the
  messages its bodies raise. Everything else a body closes over is refused as
  before -- a number, an array, and a function bound with `jit_extern`, which
  is only an address and has nowhere in a compiled object to live.

- Change: naming a contraction's axes now replaces the convention rather than
  adding a clause to it. `CArray.jit_contract(:i, :j) { ... }` names all of
  the result's axes, so every index left out of the list is summed at however
  few positions it sits -- where before, one sitting at a single position was
  refused as a free index with nowhere to go. So `jit_contract(:i) { |k|
  a[i,k] }` is the row sums, and `contract_terms(terms, free: [])` over a
  product is its total; both were refused. (`a.sum(axis: 1)` remains the
  faster way to write a reduction, being one.) With nothing named the
  convention is unchanged: a repetition is a sum and a single position is
  free. What this makes exact is the correspondence with einsum's two modes,
  the argument list being the arrow's right-hand side; `"ik->i"` and
  `"ik,kj->"` can now be said.

  Where the block assigns into an array of yours, an axis on the left-hand
  side that the list leaves out is still refused -- it is the list falling
  short of the result rather than an index to sum, and the left-hand side is
  the one place that can be seen. The message says so in those terms now.

- New: `CArray::JIT.contraction_of` returns the number that multiplies the
  product as `:scale`, which is 1 where there is none, so
  `a[i,k] * b[k,j] * 2.0` comes back as its two terms and 2.0 rather than as
  nil. A number is not a term -- it has no indices and no cell -- but it is
  not a reason to give up on the terms either, and a caller that takes them
  apart puts it back. Written out or closed over is the same number; anything
  a name holds that is not a Numeric is still nil. This shipped in 0.1.2,
  whose entry describes the same two methods without mentioning it.

## 0.1.2

- New: `CArray.jit_contract` takes the result's axes as symbols, which says
  which indices are free: `CArray.jit_contract(:p) { |k| x[p,k] * y[p,k] }` is
  one number per point, and `CArray.jit_contract(:a) { q[a,a] }` is the
  diagonal rather than the trace. A named index stays free however often it
  appears, which is what an index that numbers things -- a point, a sample, a
  batch -- does. What a repetition means is unchanged, so the whole rule is
  that an index which repeats is summed and one that is named is free. Naming
  the axes also states their order. With no arguments nothing changes.

- New: `CArray::JIT.contract_terms` runs the contraction a structure describes
  rather than one a block writes --
  `CArray::JIT.contract_terms([[a, [:i, :k]], [b, [:k, :j]]], free: [:i, :j])`
  is a matrix product -- and `CArray::JIT.contraction_of` reads a block and
  returns the terms it is a product of, or nil when it is not one. They are
  `jit_contract` with the block taken out of the middle, for a caller that
  rearranges a contraction before running it: the terms are compiled by the
  same analyzer under the same rules, so `free:` is required and an index that
  is not named must appear at more than one position.

- New: `CArray::JIT.cache_root = "path"` puts an application's compiled
  kernels somewhere of its own, rather than in the cache shared under the home
  directory. Say it before the first kernel is compiled; the path is expanded
  where it is given. `CARRAY_JIT_CACHE` and `CARRAY_JIT_NO_CACHE` still come
  first, and `nil` restores the default.

- Change: a contraction's sum is split into partial sums, as `jit_for`'s
  reduction and CArray's own reduce kernels are, which makes `jit_contract` as
  fast as the same loop written with `jit_for` rather than three times slower.
  A floating-point contraction therefore answers what the split accumulation
  answers -- usually the more accurate number, never the one a serial Ruby
  loop gives. `CArray::JIT.reassociate = false`, or `CARRAY_JIT_REASSOCIATE=0`
  for a whole process, asks for the serial order; `jit_contract` takes no
  per-call licence. Integer contractions are unaffected.

- Change: `CArray.jit_contract` sums an index that repeats however often it
  repeats, rather than refusing more than two positions. `q[i,i,i]` is the sum
  along a cube's long diagonal, and `a[i,k] * b[k,k]` sums `k` at three
  positions across two arrays. Nothing that compiled before compiles
  differently: what changes is that these are accepted instead of raising
  `CArray::JIT::Unsupported`.

- Fix: a contraction with nothing to assign into is collected into the type its
  summand computes in. `CArray.jit_contract { |i, j, k| a[i,k] * b[k,j] }` over
  float32 arrays came back int64 with every value truncated; over uint64 it came
  back int64 and wrapped; over cmplx64 it raised. The assigned form -- the same
  contraction written `c[i,j] = ...` -- was right throughout, and `jit_for`,
  `jit_each` and `jit_stencil` were never affected.

- Fix: a contraction that writes an array it also reads is refused when the
  block gave that array two names -- `y = x`, or a view of something being
  read -- as it always was when one name was used for both. It compiled and
  returned an answer that depended on the order the cells were reached in.
  `CArray::JIT.contract_terms` refuses `into:` for the same reason. Write it
  with `jit_for`, which is what a recurrence is for.

- Fix: `CArray.jit_stencil(source, into: source)` is refused rather than
  computing a pass whose cells feed the ones after them. A window that reaches
  nowhere -- one that reads only the cell it is on -- still writes in place, as
  it always did.

- Fix: assigning to a loop index inside a kernel is refused. `jit_for(3) { |i|
  i = 2; out[i] = ... }` assigned to the counter, so the loop walked somewhere
  else -- outside the array, for a value outside its extent -- while Ruby reads
  the same line as rebinding the parameter and runs the loop unchanged. Use a
  local of another name; nothing that has an index only on the right changes.

- Fix: an index named after something the generated C already uses is refused
  where it is written rather than by the compiler. `jit_contract { |int, j, k|
  ... }` reached clang as a declaration of `int`, and an index named
  `contraction` shared its identifier with the accumulator the compiler writes,
  which made the sum come out zero with nothing said.

- Fix: a C function may take a `uint64_t *` and return a `uint64_t`.
  `CArray.jit_function("void (*)(uint64_t *, int64_t)")` reached its cells as
  an opaque slot rather than an array, and a `uint64_t` return type was
  refused as "no value a compiled body can produce" -- from a table written
  before uint64 was a type a kernel computes in. A `uint64_t` parameter taken
  by value is still refused, and now says why: a value reaches a body as a
  double, an int64 or a complex, and a uint64 fits none of them whole.

- Fix: `CArray.jit_map` collects a cmplx64 value into a cmplx64 array rather
  than refusing to allocate one. Nothing else changes type: a block whose value
  is cmplx128 still gives cmplx128.

## 0.1.1

- Fix: a zero divisor in a `CArray.fuse` expression no longer turns
  compilation off for the rest of the process. `ZeroDivisionError` is raised
  as before; what has gone is the warning that followed it on stderr, and the
  expressions walked rather than compiled from then on. Nothing to do.
  `jit_for`, `jit_each` and `jit_map` were never affected.

- Fix: on macOS, a `CArray.fuse` expression holding an integer `/` or `%` is
  compiled rather than walked. The answers were right before and are
  unchanged; this is speed alone. Linux was never affected.

- Fix: on Linux, a program that compiles more than one kernel no longer
  crashes -- any two of `jit_for`, `jit_each`, `jit_map`, `jit_stencil`,
  `jit_contract` and `jit_function` reached in the same run. Nothing to do:
  cached kernels are rebuilt on first use. macOS was never affected.

## 0.1.0

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
  [docs/03_SupportedFeatures.md](docs/03_SupportedFeatures.md#the-recognized-subset).

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

- New: the `carray-jit` command reports and looks after the on-disk kernel
  cache -- `status`, `list`, `show`, `clear`. It loads the compiler and
  nothing else, so a cache can be inspected or cleared when CArray itself
  will not load.

- New: needs CArray 3.0.1 or later in the 3.0 series, and Ruby 3.2 or later.
  The floor is where `ca_call_cslab_N`, the expression evaluator hook,
  `__kernel_body__` and `BUILD_FLAGS` arrive. The ceiling is the next minor
  because a kernel reaches CArray's C by address and pastes its kernel bodies
  into generated C, neither of which the frozen author surface covers.
