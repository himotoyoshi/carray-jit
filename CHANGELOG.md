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

- Change: the refusal for a block whose source cannot be read names
  `RubyVM.keep_script_lines = true` and `CArray::JIT.compile`, which takes a
  kernel as text. It named `source:`, which is a keyword no entry point
  takes; the guide said the same.

- Change: an extent that counts down as a `Range` -- `(n-2)..0` -- raises
  `CArray::JIT::Unsupported` naming `(n-2).step(0, -1)`, the spelling Ruby
  iterates backwards with. Ruby gives such a Range no elements, so the
  kernel ran no passes and said nothing, which is what the guide says this
  refusal exists to prevent. An empty range whose ends agree (`0...0`) is a
  count of zero as before.

- Change: `CArray#jit_init` given a block that takes a splat or an optional
  parameter says so, where it said "the block names -1 indices".

- Change: `CArray.jit_contract` refuses an index that stands inside a
  subscript the kernel works out -- `a[i, idx[k]] * v[k]` -- saying that a
  contraction counts positions and this one is a position of `idx`. It was
  read as an index appearing once, so the sum the notation asks for did not
  happen and the result came back a whole matrix. Write such a gather with
  `CArray.jit_for`.

- Change: a local assigned before the summand of a `CArray.jit_contract`
  block is refused saying so -- a contraction is one expression, which is
  why it takes no local array either. It was refused as "`u` is read before
  it is assigned", about a local assigned on the line above.

- Fix: `CArray.jit_contract` takes a summand that calls a function made with
  `CArray.jit_function` or `CArray.jit_extern`, which the docs say it does;
  it was refused as an unsupported method. What the function hands back
  types the result the contraction is collected into.

- Fix: a cell of a local array written under an `if` or a `while` whose
  condition read a missing cell is masked, as a plain local and a cell of an
  array now are. It was left present deliberately; the rule the docs give
  for it is the one the other two keep.

- Fix: a local assigned under an `if` or a `while` whose condition read a
  missing cell is masked, as a cell written there already was. It came back
  a number like any other, so `found = -1; ...; if a[i, j] > x then found =
  j end; out[i] = found` reported a position found under a mask. A condition
  that asks about the mask itself (`a[i] == UNDEF`) still masks nothing.

- Change: a cache directory owned by another user is refused, as one other
  users can write to already was; everything in it is `dlopen`ed. A cache
  root that is a symlink is followed as before, and the owner of the
  directory it lands on is what is asked about. Set `CARRAY_JIT_CACHE` to a
  directory of your own where this refuses.

- Fix: a build no longer fails with "could not load freshly compiled" when
  another process evicts its object in the moment between the build and the
  load. It opens the object before publishing it to the cache. Reachable
  where `CARRAY_JIT_CACHE_LIMIT` is smaller than the number of processes
  building at once: with five of them, a limit of 2 lost every one.

- Fix: a build whose compile fails leaves no `.c` behind in the cache. Such
  a file was never looked up -- a cache hit is an object -- and eviction
  passes over it, so one stayed for good, and one more for every kernel of
  every run against a toolchain that cannot compile.

- Change: a compiler this process cannot find -- `CARRAY_JIT_CC` naming
  something that is not there -- raises `CArray::JIT::CompilationError`
  saying so and naming the variable, where it raised `Errno::ENOENT` from
  the spawn with the program name and nothing else.

- Fix: two threads of one process compiling at the same time no longer
  raise `Errno::ENOENT`; three threads in four did. A build now takes a lock
  for the length of the compile, so the second thread finds the object the
  first one left and reuses it rather than building its own. Compiling two
  different kernels in two threads is that much less parallel -- four of
  them took 970 ms here against 800.

- Change: the docs now say that a negative Float to a fractional power is
  `NaN`, as `pow` and CArray answer, where Ruby answers a Complex. This was
  already the behaviour; a whole-number exponent or a non-negative base is
  Ruby's number.

- Change: the docs now say that an Integer compared with a Float is
  compared as two doubles, as CArray compares them, so past 2^53 the answer
  can differ from Ruby's exact comparison. This was already the behaviour;
  below 2^53 nothing differs.

- Change: the docs now say that `Math.sqrt`, `log`, `log2`, `log10`, `asin`,
  `acos`, `acosh` and `atanh` answer `NaN` outside their domain, as `math.h`
  does, where Ruby raises `Math::DomainError`, and that `Math.sqrt(-0.0)` is
  `-0.0`. This was already the behaviour. `Math.gamma` still raises as Ruby
  does. Test the argument in the block where it may leave the domain.

- Fix: multiplying two Complex numbers, or a real number by a Complex
  (`x * z`), gives Ruby's answer where an infinity meets a zero:
  `0.0 * Complex(Float::INFINITY, 0.0)` is `0.0+0.0i`, where it was
  `NaN+NaN*i`. Finite products are unchanged, `cmplx64` included, and
  `z * x` still scales each part as it did.

- Fix: `%` by a float zero raises `ZeroDivisionError`, as Ruby's does --
  `x % 0.0`, `x % -0.0`, an integer cell `% 0.0` -- in a kernel and in a
  `CArray.jit_function` alike. It answered `NaN`, which is what CArray's `%`
  answers and not what the docs promised. A float `/` by zero is still an
  infinity, as it is in Ruby.

- Change: arithmetic between two booleans -- `flag[i] * flag[i]`, `+`, `-`,
  `/`, `%` -- raises `CArray::JIT::Unsupported` where the operator stands,
  as `true * true` raises in Ruby. Used as a condition it compiled and ran.
  `&`, `|` and `^` on booleans are unchanged.

- Fix: `min(w)` and `max(w)` over a floating local array keep the first of
  two cells that compare equal, as CArray's `min` and `max` do, so `0.0`
  and `-0.0` come back in the order they stood; which zero came back was
  left to the C library. NaN is still skipped, and an array of nothing but
  NaN still answers `NaN`.

- Fix: `floor`, `ceil`, `round`, `truncate` and `to_i` on a Float raise
  `FloatDomainError` for a NaN or an infinity, as Ruby does, and `RangeError`
  for a result past int64; they gave a clamped or arbitrary number. Written
  straight into a float cell, or returned from a `CArray.jit_function`
  declared `double`, the result is Ruby's however large -- `1e20.floor` is
  `1e20`. A loop doing little but rounding runs slower for the check.

- Fix: `.abs` on an integer compiles in `CArray.jit_for`, `CArray.jit_map`,
  `CArray.jit_function` and the other entry points; it raised
  `CArray::JIT::CompilationError` unless the kernel also allocated a local
  array. `(-2**63).abs` in an int64 wraps to itself, as other int64
  overflow does. Float and complex `.abs` are unchanged.

- Change: a subscript that walks with one index and adds another --
  `a[i + r]`, `r` an inner loop's index -- is refused as the block is read,
  with a message that says so and that the sum put in a local first
  (`k = i + r`, then `a[k]`) is checked at each cell and runs. It was
  refused at the call, for a reason about an inner loop's range. The
  exception is `CArray::JIT::Unsupported`, as it was.

- Change: a `CArray.jit_function` body that subscripts a pointer parameter
  with a literal outside the length its declaration gave -- `v[7]` or
  `v[-1]` against `double v[2]` -- raises `CArray::JIT::Unsupported` as the
  body is read. It compiled, and wrote or read past what the caller was
  held to. A computed subscript, and any subscript on a pointer declared
  without a length, are unchecked as before.

- Fix: an inner loop stepping by more than one over a start written over
  another index -- `2.times { |p| (p...8).step(3) { |k| ... } }` -- is held
  to the cells every pass reaches, not only the pass from the earliest
  start. A subscript one pass took past the end of an array was let through
  and written; it is now refused as the call is prepared. A step of one, and
  a start that does not move, are read as before.

- Fix: a local array whose shape is written over captured integers --
  `CArray.double(n, m)` -- raises `ArgumentError` when its lengths each fit
  but their product does not count in bytes. Such a product wrapped to a
  small number, the kernel allocated that, and subscripts in range on every
  axis wrote past it. A shape of one axis, or of lengths whose product
  fits, is unaffected.

- Fix: `CArray::JIT.clear_registry` now forgets the functions
  `CArray.jit_function` compiled, as it already did kernels, so the next
  call reads them back from the cache on disk.

- Fix: a block run through `eval` -- in a console, or from code that builds
  its kernels as text -- no longer stays in memory for the life of the
  process once nothing refers to it. On Ruby 3.2 it still does.

- Fix: a kernel over a masked array read and wrote the wrong cells of its
  mask, and on a large enough array wrote past the end of it, when an
  unmasked operand whose number of axes differs from the kernel's -- a row
  added across a grid, or a contraction's operand -- sorted by name before
  the masked one. Kernels whose operands all share the kernel's rank, and
  kernels over no masked array, were not affected.

- New: a local array may be larger than a stack frame should hold, and its
  shape may be written over an integer the block captured --
  `CArray.double(n)`, which was refused. Either way the kernel allocates the
  array once at its entry and frees it at its exit, so a constructor written
  inside the cell loop is still one allocation; 4 KiB for one array and
  16 KiB for one kernel's arrays together now say where an array lives rather
  than whether it is allowed, and nothing is refused for its size. A kernel
  whose arrays all fit in the frame emits the C it emitted before. Where the
  length is one the kernel works out, every subscript on that axis is checked
  where the cell is reached rather than as the block is read, and a C
  function takes the array only through a pointer that declares no length
  (`const double *v`, not `const double v[3]`). The same block at two lengths
  is one compiled kernel: the length travels as an argument and is not in the
  C. A shape that comes to zero or less raises `ArgumentError` when the
  kernel runs, and an allocation the system refuses raises `NoMemoryError`,
  both naming the array and what its shape came to. A `jit_function` body
  allocates nothing -- it is called once per cell -- and refuses such an
  array, naming the pointer parameter to take it through instead.

- New: a kernel that carries masks takes a local array, which it refused
  before. Every local array of such a kernel is declared with a shadow of one
  byte a cell beside its cells, and a cell carries a mask the way a plain
  local does: what the expression written into it carried. So a window copied
  into a workspace keeps its holes. `w[k] = UNDEF` marks a cell and
  `w[k] == UNDEF` asks about one; the zeroed spellings clear the shadow with
  the cells, so a cell starts every pass present, while `CArray.empty` leaves
  both unspecified. The shadow counts against the 4 KiB an array is held to
  and the 16 KiB a kernel is, so an array that fits by its cells alone may
  not fit once it carries masks. Two things still refuse such an array:
  `sum`, `min`, `max` and `sort`, because what they should do with a missing
  cell is not decided, and a C function, because a mask travels in no C
  declaration -- both say so where they used to be refused for having no mask
  at all. A kernel that carries no masks emits what it emitted before, and a
  compiled function's body carries none at all.

- Change: `min(w)` and `max(w)` over a floating local array answer `NaN` when
  every cell is `NaN`, where they answered `Infinity` and `-Infinity`. This
  follows CArray 3.0.2, which made the same change to its own `min` and `max`;
  the gemspec already asks for that version. An array holding at least one
  number answers as before, a `NaN` still losing to any number, and an integer
  local array is unchanged.

- New: an inner loop's range may be written over another index --
  `3.times { |p| (p+1...3).each { |r| ... } }`, the shape a triangular loop
  takes -- where that index is one of the loops around it. Forward
  elimination and Neville's interpolation are the two this was wanted for,
  and both now read as they do on paper rather than as a full loop with an
  `if` inside it. The C was always emitted; what stood in the way was the
  call, where each index's range is worked out so that a subscript can be
  held to its array. A range over another index has no single pair of
  numbers to be, so it is read as an interval, at its widest: every pass the
  loop could take and sometimes more. Where that refuses a reach the loop
  never makes, the message says which index the range was written over and
  that it was read at its widest. A range over a local variable, a sibling
  loop's index or a deeper one is still refused.

- Fix: a local array indexed by an inner loop whose range is not known until
  the kernel runs -- a bound that is a captured integer, and now a range
  written over another index -- is checked where the cell is reached. Such a
  subscript was checked nowhere: the check that reads the loop's range could
  not settle it, and the check at the access did not cover an index, so a
  write past the end of the array went into the block's stack frame. It now
  raises `IndexError` as every other unsettled subscript does.

- Fix: in a `CArray.jit_each`, `CArray.jit_map` or `CArray.jit_stencil`
  block, an array handed to a C function whole -- and read in no other way --
  is no longer lined up with the operands. One whose length differed from
  theirs used to fail with `broadcast_to: cannot broadcast axis 0`, which
  named an axis and said nothing about the call it was written for; a set of
  weights four cells long may now stand beside a thousand cells of operand.
  What decides which arrays those are is the declaration, not the spelling: a
  parameter taking a number by value reads the cell, so that array is walked
  and lines up as before, and an array both read by cell and handed over is
  an operand too.

- Change: a `CArray.jit_each` or `CArray.jit_map` block whose *only* array is
  handed to a C function whole is now refused, naming the array and saying
  that it does not settle how many cells there are to compute.
  `CArray.jit_map { DOT4.call(w, w) }` used to answer an array as long as `w`
  -- a length that came from an array nobody walks -- and the same block under
  `jit_each` failed inside Fiddle with `unknown symbol "ca_call_cslab_0_r"`.
  `CArray.jit_for` with a count takes these, as it always did.

- New: a local array may have more than one axis --
  `CArray.double(3, 4)`, `CArray.new(:float64, [2, 3, 4])` -- in any of the
  five places one can be made. The shape is written out as it always was, so
  the strides are constants: `m[r, c]` is `m[(r) * 4 + (c)]`, one subscript
  per axis, and each axis is checked against its own extent. That is what
  flattening by hand gives up -- `m[r * 4 + c]` with a column of 4 reads a
  cell of the next row and says nothing, where `m[r, c]` is refused by name
  and a computed column raises. The stack limits count cells rather than
  axes, so `CArray.double(32, 32)` is 8 KiB and past the 4 KiB an array is
  held to. Handed to a C function the array goes as the flat run of cells it
  is, row after row, so a `double[3][4]` reaches `const double a[12]` and the
  length is matched over every cell. The four intrinsics still take one axis.

- New: a `CArray.jit_function` body may make a local array and use
  `sum`/`min`/`max`/`sort` over one, which completes the four entry points.
  A body closes over nothing, so this is the only place scratch space could
  come from other than an extra parameter -- and a signature settled
  elsewhere, a callback's, has no room for one. The array is declared at the
  head of the function, a recursive body gets one per call, and a body hands
  one to another compiled function under the same rules a kernel does. The
  helpers an intrinsic needs travel with the body: carried in its own file
  when it is compiled alone, and merged into the kernel's preamble when it is
  pasted, one helper per element type and length however many bodies want it.
  The stack limits stay per function -- 4 KiB an array, 16 KiB a body -- and a
  chain of pasted functions is not counted, so a deep chain stands as many
  frames as it has; that is the bargain a deep recursion already takes. Still
  excluded: more than one axis, and a contraction.

- New: a local array may be handed to a C function -- one from
  `CArray.jit_function` or `CArray.jit_extern` -- wherever the declaration
  takes a pointer, from any of the four entry points that make one. What the
  declaration says is matched as the block is read rather than at the call,
  both the element type and the length being written in the block: an exact
  element type, and at least as many cells as a sized declarator asks for.
  A parameter that is not `const` may be written through, and the line after
  the call reads what the callee left; the zeroed constructors still clear at
  the line, so nothing carries into the next cell. Passing one array to two
  parameters is fine, the declarations carrying no `restrict`. Note that a
  borrowed function which keeps the pointer past the call is left pointing at
  a stack frame that has gone, and that a declaration carrying no length --
  `const double *x` -- gives nothing to check against. Still excluded: a
  `jit_function` body, more than one axis, and a contraction.

- New: a local array, and the four intrinsics over one, may be written in a
  `CArray.jit_each`, `CArray.jit_map` or `CArray.jit_stencil` block as well as
  in `CArray.jit_for`. These are the spellings that wanted one: a block with
  no index cannot pick a row of a captured array, so a `jit_stencil` median
  filter had nowhere to put its window -- it is now nine doubles on the cell's
  stack and `sort(w)`. `border: :mask` takes one, the frame being marked
  before the loop runs rather than carried through it. A name the block makes
  an array under is refused where the block also closes over an array of that
  name, since in these spellings an assignment writes that array's cell;
  rename one of the two. A `jit_map` block may not end by making an array, its
  value having to fit in a cell. Still excluded: a `jit_function` body, a
  contraction, more than one axis, passing one to a C function, and a kernel
  that carries masks.

- New: `sum(w)`, `min(w)`, `max(w)` and `sort(w)` inside a `CArray.jit_for`
  block, over a local array of one axis. They are bare calls, the compiler's
  own names, rather than methods on the array -- `w.sum` is refused, and
  `sum = 0.0` beside `sum(w)` is still a local. `sum` accumulates in the
  element's computation type in index order; `min` and `max` skip a NaN
  wherever it stands and answer `Infinity` / `-Infinity` for an array of
  nothing but NaN, which is what `CArray#min` and `#max` answer. `sort`
  is a statement and orders the cells ascending with every NaN after every
  number, as `CArray#sort` does; the relative order of `-0.0` and `0.0` is
  not promised. Up to 16 cells it emits a comparator network with no branch
  in it, above that an insertion sort. Excluded for now: a captured array
  (a whole-array reduction is `CArray#sum`), more than one axis, two
  arguments, boolean for all four, Complex for `min` / `max` / `sort`, and
  the other entry points.

- New: a `CArray` made inside a `CArray.jit_for` block is a C array on the
  block's stack -- `w = CArray.double(9)`, `CArray.new(:int64, [256])` or
  `CArray.empty(:float64, [9])`, read and written at a subscript. One axis,
  with the length written out as an integer or integers joined by `+`, `-` and
  `*`; the zeroed spellings are cleared each time the line runs, as Ruby makes
  a fresh array there. A subscript is checked as the block is read where the
  loop's range says it can be, and at the access otherwise, raising
  `IndexError`. One array is held to 4 KiB of stack and one kernel's to 16 KiB.
  Excluded for now: more than one axis, passing one to a C function, the other
  entry points (`jit_each`, `jit_map`, `jit_stencil`, `jit_function`), a kernel
  that carries masks, and CArray's Numo/NumPy spellings (`CArray.zeros`,
  `CArray::Int64.empty`), which are refused with the carray spelling named.
  Note `CArray.float` is float32 and `CArray.complex` is cmplx64.

- Change: a block parameter that names a loop index is refused when the
  generated C already uses that name for a captured array (`p_a`, `m_a`,
  `a_s0`, `a_ms0` or `a_n0` for an array `a`), or when it contains `__` or
  starts with `carray_jit_`. Rename the index.

- Fix: a local in a kernel or `jit_function` body, or a captured variable
  starting `carray_jit_`, may be given a name the generated C also uses -- a
  kernel parameter such as `error`, a C keyword such as `int`, `a_n0` beside a
  captured array `a`, or a name containing `__`. It failed to compile, raised
  an `IndexError` for an index in range, or shared its value with another
  name; it is now renamed in the generated C only.

- Change: a kernel or `jit_function` body that reads a local after an inner
  loop's block in which the local was first assigned, or after a `while` in
  which it was first assigned, is refused with a message naming the local.
  These did not compile before either, failing in the C compiler instead.
  Give the local a value before the loop.

- Fix: two inner loops in one kernel or `jit_function` body may assign a
  local of the same name, at one type or two, and a local assigned inside a
  `while` may be read after it when it was also assigned before it. The
  first failed in the C compiler or was refused as changing type; the second
  failed in the C compiler.

- Fix: a loop in a `jit_function` body, and a `while` or inner loop in a
  kernel whose body held the kernel's first way to fail, kept running after
  an integer division by zero, a computed index out of range, `clamp` or
  `Math.gamma` had reported a failure -- so a `while` decided by the value
  handed back could run forever. Such a loop now leaves at the head of its
  next pass, and the call raises as it already did.

- Change: `CArray.jit_for`, `CArray.jit_each` and `CArray.jit_map` are this
  gem's alone. From CArray 3.0.2 they are not defined until
  `require "carray/jit"` has run, so a program that calls one without it gets
  `NoMethodError` rather than CArray's `NotImplementedError`. With the gem
  required nothing changes, against any CArray this gem accepts.

- New: `CArray#jit_init` fills an array from a formula over its indices, with
  the block compiled: `CArray.int32(1000, 1000).jit_init { |i, j| (i + j) % 2 }`
  is what the constructor block `CArray.int32(n, n) { |i, j| ... }` says,
  without the Ruby call per cell. One parameter per axis, the block's value is
  the cell, and the receiver comes back. It is the only entry point here that
  is an instance method, because the array being written is the receiver: the
  extents are its shape, so neither the index space nor the target is said
  twice, where `CArray.jit_for(n, n) { |i, j| z[i, j] = ... }` says both. A
  block outside the compilable subset raises rather than running the slow
  loop, as every other entry point here does. Reach for it where the formula
  will not go through whole-array arithmetic -- where it will, that needs no
  compiler and is faster still.

- New: a kernel can draw random numbers, from a `CArray::Rng`. `rand =
  CArray::Rng.new(seed: 4)` and then `rand.random` in a `jit_for`, `jit_each`
  or `jit_map` block draws one double in `[0.0, 1.0)` per cell, at about
  0.8 ns; `random(rng: rand)` is the same draw spelled as
  `CArray#random!(rng:)` spells it; `rand.randomn` is a standard normal, at
  about 10 ns, and `randomn(rng: rand)` the same; and `rand.bits` is the raw
  word a draw came from. All of them read one generator, so mixing them in a
  kernel walks one sequence. The generator is CArray's and there is no entry point here: a
  block closing over one is what a kernel needs. Each has its own state, so
  two in one kernel are two sequences, and the state survives the call --
  a second kernel carries on rather than starting again. `seed:` is data
  rather than code, so every seed shares one compiled kernel. A sequence can
  begin with `a.random!(rng: rand)` and continue in a kernel: those are the
  same numbers one `random!` over both arrays would have laid down, because
  CArray hands out the generator's C and this gem pastes it. Needs CArray
  3.0.2 or newer, which is where `CArray::Rng` arrived; an older one is
  refused where the block closes over the generator, and leaves every kernel
  that draws nothing alone. A draw is refused inside `jit_function`, which
  has nowhere to keep a state; take `int64_t state[4]` as a parameter there
  and pass `rand.state`. Which draw lands in which cell is still the loop's
  order, so where that has to be settled, fill an array with
  `CArray#random!` before the call.

- Fix: `CArray.jit_each` and `CArray.jit_map` no longer refuse a block that
  hands a one-cell array to a C function. Those entries line their operands up
  with the expression's shape, and an array passed to a pointer parameter was
  lined up with the rest -- so a one-cell array holding state came back
  stretched and read-only, and the copy-back after the call raised `can not
  modify read-only array`. An array handed over by address is passed whole
  rather than walked, so it is left as it is now. `jit_for` was never
  affected, and a `CScalar` was affected the same way an array was.

- New: `CFunction#watching`, and `#clear_error` / `#report_error` beside it,
  for the window in which a compiled function's address is lent to a C
  library. `#call` answers for one call; a library given `#pointer` calls as
  often as it likes, and `f.watching { ... }` is what puts the flag down
  before that and raises what the body reported after it. A failure inside
  the block outranks the library's own complaint about the stand-in it was
  handed. Windows nest, and a `#call` made inside one leaves it armed.

- Change: a compiled function whose body has failed does no more work until
  its flag is put down again -- it returns 0 without running, and one
  declared `void` leaves its out-parameters alone. Before, it reported the
  first failure and then answered normally, so a library that kept calling
  could converge on values it was no longer entitled to. Nothing changes for
  a caller using `#call`, which puts the flag down for each call; a caller
  holding `#pointer` opens a window with `#watching` or `#clear_error`. A
  kernel is unaffected: it is handed its own error slot and never reaches
  this flag.

- New: `Math.gamma`, which is not `tgamma` and is not lowered to one: Ruby's
  answer is tgamma with a table of exact values in front of it for a whole
  number up to 23, and a `Math::DomainError` where tgamma answers a negative
  whole number or negative infinity with a NaN. Both are reproduced -- the
  table is written into the generated C, filled from the Ruby that compiled
  it, as `Math::PI` is emitted as the double Ruby would have used, and the
  error carries Ruby's class and Ruby's words. A cell with no value in it
  does not raise. Measured over the whole numbers to 26, the halves, the
  infinities and the overflow, a kernel and the Ruby loop agree in every bit.

- New: `Math.erf` and `Math.erfc`, which are 1:1 with math.h's `erf` and
  `erfc` -- Ruby calls those very functions, so a kernel and the Ruby loop
  agree to the bit, infinities included. A float32 cell is worked on narrow
  and so gets `erff`, as it gets `sinf`. There is no postfix `x.erf`:
  `CArray::CoreExtensions` does not provide one, and this compiles the
  refinement's names rather than inventing them.

- Change: the three names left in Ruby's `Math` say why they are not lowered
  rather than saying that C has no counterpart, which was untrue of all of
  them -- `lgamma`, `frexp` and `ldexp` all exist. `Math.lgamma` and
  `Math.frexp` each answer with a pair, and a cell holds one number;
  `Math.ldexp` takes an exponent where a math call here computes every
  argument in the type of its result. A name Ruby's `Math` does not have says
  that instead of guessing at a reason.

- New: `x.clamp(low, high)`, which answers the value or whichever bound it
  ran past. The value and both bounds have to be one class: Ruby hands back
  the receiver in one branch and a bound in the other, so `1.clamp(0.0, 3.0)`
  is an Integer and `5.clamp(0.0, 3.0)` a Float, and no type settled before
  the loop runs is both -- the refusal says which way round it is and what to
  write. Two widths of one class are not that case, so a float32 cell keeps
  its width. What Ruby raises `ArgumentError` for is raised here too: bounds
  the wrong way round, and a NaN that cannot be ordered. The class is Ruby's
  and so are the words for the first; for the NaN the message names the
  reason rather than the value, since what comes back from a kernel is a code
  and not a number. A cell with no value in it does not raise. The range
  form, `x.clamp(0.0..1.0)`, is not in the subset -- two bounds are two
  bounds.

- New: a compiled function may take and return a C99 complex --
  `CArray.jit_function("double _Complex step(double _Complex z)") { |z| z * z
  + Complex(0.0, 1.0) }`. `double _Complex`, `float _Complex` and
  `<complex.h>`'s `double complex` all read, by value or as a pointer, where
  `double _Complex v[]` takes a `cmplx128` array as `double v[]` takes a
  `float64` one. A kernel calls such a function as C calls it. A call from
  Ruby goes through a second entry point compiled beside the body, since
  Fiddle has no type to carry a complex by value in; it calls the body rather
  than repeating it, so `f.call` and `f.block.call` stay the same body run
  two ways. A function bound with `jit_extern` and declared with a complex is
  callable from a kernel but not from Ruby -- there is no source here to
  compile an entry point beside -- and says so.

- Fix: a captured Integer above 2**63-1 reaches a kernel whole. It was packed
  into the int64 slot the kernel reads its integers from, which took the value
  modulo the width and said nothing: `big / 3`, `big > 100` and `big * 1.0`
  answered from a negative number, while `+` and `*` came out right and hid it.
  Such a capture is a uint64 now -- the width CArray has for those values --
  and a value neither an int64 nor a uint64 holds is refused where the capture
  is read, naming the value.

- Change: a captured Integer above 2**63-1 meeting an integer is refused,
  where before it was absorbed into that integer's width and computed from a
  wrapped value. CArray refuses the same expression whatever the array's own
  type is -- `CArray.uint64(1) { 5 } + 2**63` raises `bignum too big to
  convert into 'long long'` -- and this follows it: a bare Integer brings no
  width, and the message names `CScalar.uint64() { big }`, which a kernel reads
  as the one-cell array it is. A Float or a Complex on the other side is
  unaffected, and so is a capture that fits an int64. A loop that adds such a
  capture to an accumulator is refused for the same reason: state the width
  once with a CScalar, for the seed and for the value.

- New: a `jit_function` body may take an unsigned 64-bit value by parameter --
  `CArray.jit_function("size_t stride(size_t n, size_t width)") { |n, w| n * w }`
  -- where before only a pointer to one could be taken. The value arrives
  whole above 2^63 and the arithmetic on it is unsigned, wrapping at the width
  as CArray's own `uint64` operators wrap. A kernel's captured scalars are
  unchanged: those travel in the kernel's own buffers, which carry doubles,
  int64s and complexes.

- Fix: a C declaration written with `ptrdiff_t` compiles. `size_t` and the
  other `<stddef.h>` names have read since 0.1.0, but the C generated for a
  body that took one declared no such type, so `CArray.jit_function("ptrdiff_t
  (*)(ptrdiff_t)")` failed in the C compiler with `unknown type name`.
  `size_t` was unaffected, by luck rather than by design.

- New: `x.nan?` and `x.finite?`, which compile to C's `isnan` and `isfinite`
  and answer what Ruby answers. `nan?` is a Float's question: an Integer and
  a Complex have no method by that name and raise `NoMethodError` in Ruby, so
  a kernel refuses both rather than answering false. `finite?` answers for an
  Integer (true, whatever it holds) and for a Complex (both parts finite, as
  Ruby asks it) as well as for a Float. `infinite?` is refused: Ruby answers
  it with nil, 1 or -1 rather than true or false, and a kernel has no nil to
  answer with -- the message names `x.abs == Float::INFINITY`, or
  `x == Float::INFINITY` where the sign is the question.

- New: the operator assignments -- `+= -= *= /= %= **= &= |= ^= <<= >>=` --
  on a local, on a cell (`out[i] += e`, `work[i, k] += e`, a scatter such as
  `counts[bin[i]] += 1`), on a CScalar and through a `jit_function`'s pointer
  parameter. Each is read as the assignment it stands for, `x = x + e`, so
  the type rules, the mask propagation and the fold that splits an
  accumulator into partial sums are the ones already there: a reduction
  written `total += values[j]` is still split. `||=` and `&&=` are refused,
  being about whether a value is nil or false rather than about arithmetic.

- Change: a statement outside the subset is named as it was written --
  ``got `unless` -- write it as `if` with the condition negated`` rather than
  `got Unless`, which was this compiler's reading of it and not anything
  anyone typed. The list of what a body may hold was written out in two
  places and they had come apart; it is one place now.

- New: an inner loop counts by a stride, written the way an extent writes
  one: `(n-1).step(0, -1) { |k| ... }` is a downward sweep and
  `(0...n).step(2) { |k| ... }` a stride of two. `step` includes the index it
  is given, as Ruby's does, where a `...` range excludes it, and the stride
  is a literal because it is what says which way the loop runs. This is the
  other half of a row of workspace -- filling one and walking back down it no
  longer needs `k = width - 1 - t`, which made the position a value the
  kernel worked out and so put a bounds test on every cell of the sweep: 0.41
  ns/cell against 0.24 for the same sweep written with `step`. An accumulator
  is split into partial sums only for a loop counting by one; a stride keeps
  the serial chain, and so keeps Ruby's order. `downto`, `upto` and
  `reverse_each` are refused by name, naming `step` as what to write.

- Fix: two inner loops in one body may both be written `{ |k| ... }`. They
  are one name in the block and were one index here, so the second loop's
  range replaced the first's and a reach was checked against the wrong one --
  `a[k-1]` in a loop from 1 was refused for starting at 0 once a later loop
  started there. Each loop now counts in an identifier of its own, and the
  messages go on speaking the name the block wrote.

- New: an inner loop's index may address a write, so a cell can be given a
  row of workspace -- `(0...width).each { |k| work[i, k] = ... }` fills it,
  and `work[i, k]` reads it back inside the same cell. That is what an
  algorithm needing a few numbers per cell is written with: a small dense
  solve, a tableau, a sweep and the pass back down it, in one kernel rather
  than in several that each pay a call. The cell is bounds-checked before the
  kernel runs, as one addressed by `i` is. Inside the row the body may do as
  it likes -- sort it, walk it backwards, write at a position it works out --
  which is what a median filter needs and what no extra axis can say. Reading
  an array the kernel writes through an inner index is still refused where
  the read leaves the cell the outer indices picked: a read carrying an inner
  index addresses every axis some write walks with an outer index with that
  same index, at whatever offset, or it reaches cells another outer iteration
  owns. Where the sweep can be said as an extra axis instead --
  `jit_for(rows, 1...width)` -- that remains the faster form once the rows
  are long.

- New: a function compiled with `CArray.jit_function` may call another one
  compiled with `CArray.jit_function`, by the name the block reaches it by --
  `hypot = CArray.jit_function("double (*)(double, double)") { |a, b|
  root.call(a * a + b * b) }`. The called body is pasted into the caller's C
  and reached by symbol, so what comes back is still one self-contained
  object with one address, and a chain of any depth arrives together with the
  messages its bodies raise. Everything else a body closes over is refused as
  before -- a number, an array, and a function bound with `jit_extern`, which
  is only an address and has nowhere in a compiled object to live. The name
  may be a constant as well as a local, which is what lets a method reach
  one: `def` closes over nothing.

- Fix: a block holding a character outside ASCII no longer raises. The file a
  block sits in was read with `File.read`, which uses
  `Encoding.default_external` -- a setting that has nothing to do with a
  source's encoding: on a machine with no locale set it is US-ASCII, and the
  file came back as its own bytes under a tag that the first `rstrip` on a
  line holding a comment in Japanese raised on. The file is now read as bytes
  and given the encoding the parser gave it: UTF-8, or what a `coding` magic
  comment names on the first line or on the second where a shebang takes the
  first.

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
  before uint64 was a type a kernel computes in.

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
