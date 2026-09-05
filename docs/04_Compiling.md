# Compiling, caching and inspecting

## What compiling costs, and where kernels are kept

### Requirements on the array

Contiguity is not one of them. What is:

- **not an object array** -- `CA_OBJECT` holds Ruby values, not numbers
- **not a size-reinterpreting view carrying a mask** -- see [Masks](03_Blocks.md#masks)
- **writable**, when the kernel writes to it

### What compiling costs

Compiling is not free, and the shape of the trade is worth stating.
`benchmark/break_even.rb` measures it where you are; what follows is the shape
to expect, not a figure to hold this to.

Only the first time is expensive. Compiling a kernel never seen before costs a
couple of hundred milliseconds, and most of that is the operating system
checking a freshly written binary rather than the compiler working -- the same
C through `cc -O3 -fPIC -shared` by hand takes a fraction of it. After that the
object is on disk, and a new process pays single-digit milliseconds to load it.

The third level is not the compiler at all. A call that finds everything
already loaded still costs tens of microseconds, and that figure does not move
with the size of the array: it is reading the block's source, splitting the
captures, broadcasting the shapes and packing the buffers. So a kernel called
in a loop does not pay for itself at one element, and where it starts to
depends on what it is being weighed against -- which is two different
questions with two different answers.

Against **a Ruby loop** -- the reader who came here from `jit_for`, writing a
recurrence or a stencil that has no array form -- the crossing is early, at
tens of elements for a wide expression and around a hundred for one as narrow
as `a * 2 + 1`.

Against **the array expression** -- the reader choosing `jit_each` over
`a + b * c`, which already runs in C -- it is thousands, and the narrower the
expression the later it comes: what is being saved is the passes over the
data, and a narrow expression has fewer of them to save.

Below those, write the expression. The compiled kernel is for the sizes where
the passes cost more than the call does.

Which is why the cache is on by default. Turning it off with
`CARRAY_JIT_NO_CACHE` makes every run pay the compile again.

### Caching

A kernel is compiled once, and every later call takes a fast path. Three
levels, outermost first:

| Level | Key | Skips |
| --- | --- | --- |
| Block source | the block's instruction sequence | reading and parsing the file |
| Kernel | source, dtype, capture types | analysis, type assignment, code generation, `dlopen` |
| Shared object | SHA-256 of the C source and flags | the C compiler, across processes |

Measured, on a kernel called repeatedly:

```
first call (compiles)       2090 us
repeat call, block            9.2 us
repeat call, source:          6.4 us
calling the kernel directly   3.1 us
```

Nothing on that path is free enough to repeat: parsing the file a block lives
in costs about 110 us, and analysis and type assignment about 80 us together,
against roughly 3 us to call a compiled kernel. So all of it is memoized.

The block cache is keyed on the instruction sequence because CRuby hands back
the same one for every Proc made from a single block literal -- a free
identity for the block, with no source comparison needed.

What is *not* cached is the value of a captured variable: it is read from the
binding on every call, so a kernel keeps working when the value changes.
Only its class is part of the kernel key, since only the class changes the C
signature.

The remaining ~9 us is per call, not per element, so it disappears into any
array worth compiling for: at a million elements it is 0.1% of the run.

### Where compiled kernels are kept

In `~/.cache/carray-jit` (honouring `XDG_CACHE_HOME`), one directory per
version, CArray version and architecture, holding a pair of files per kernel
named by the SHA-256 of the C source, the compiler and its flags:

```
~/.cache/carray-jit/
├── 0.1.0-carray3.0.1-arm64-darwin24/
│   ├── 014f77ae....c        the generated C, kept so an object can be identified
│   └── 014f77ae....bundle   the compiled kernel, about 17 KB
└── 0.1.0-carray3.0.1-x86_64-linux/
```

A kernel is only good for the version that generated it and the architecture
it was built for, so those get their own directories. CArray's version is
there for the same reason and one of its own: a kernel is handed CArray's
memory, on layouts CArray decides, so one compiled against one version and run
against the next would answer wrongly rather than fail to load.

The two numbers say different things and move on their own clocks: the first
is the version that generated the kernel, the second the version it was
generated against. This gem is not versioned with CArray, and one release of
it meets more than one -- the dependency is `>= 3.0.1, < 3.1`, so 3.0.1 and
3.0.4 both satisfy it -- and a layout the kernel reaches into can move between
them. A new release does not
spend its cache budget on entries nothing can reach any more, and a home
directory shared between machines -- over NFS, or between Rosetta and native
-- does not have one architecture evicting the other's kernels. A directory
whose newest entry has not been touched in 30 days
(`CARRAY_JIT_CACHE_MAX_AGE_DAYS`) is removed.

```ruby
CArray::JIT.cache_root                 #=> "/home/you/.cache/carray-jit"
CArray::JIT.cache_directory            #=> ".../0.1.0-carray3.0.1-arm64-darwin24"
CArray::JIT.cache_entry_count          #=> 12
CArray::JIT.cache_byte_size            #=> 208_320
CArray::JIT.stale_cache_environments   #=> [".../0.0.9-carray3.0.1-arm64-darwin24"]
CArray::JIT.clear_cache                #=> 12   (kernels already loaded keep working)
CArray::JIT.clear_cache(everything: true)
```

It survives the process on purpose. Rebuilding a kernel costs about 60 ms to
compile, plus roughly **180 ms on macOS the first time a freshly written
binary is loaded** -- Gatekeeper checking it, not anything Ruby does. Another
process loading the same file pays 0.2 ms:

```
process A, just compiled    dlopen  177.8 ms
process B, existing file    dlopen    0.2 ms
process C, existing file    dlopen    0.2 ms
```

Set `CARRAY_JIT_NO_CACHE=1` (or `CARRAY_JIT_CACHE=none`) to put the cache in
a temporary directory that is removed at exit, at that cost per kernel per
run.

The cache is **bounded**: past `CARRAY_JIT_CACHE_LIMIT` kernels per
environment (512 by default, so about 9 MB) the least recently used are
evicted, source and object together. Reuse updates an entry's timestamp, so what a program
actually runs stays. This is the one place carray-jit deliberately parts with
RubyInline, whose `~/.ruby_inline` has no eviction at all and grows for the
life of the account.

Removing a cached object never breaks a kernel already in use: unlinking a
loaded shared object leaves its mapping intact.

Because the cache is shared across processes and across time, the key covers
the C source, the compiler *binary* (its path, size and mtime -- a stat
rather than the ~50 ms of asking it for `--version`), the flags and the
architecture. A toolchain upgrade therefore invalidates entries rather than
reusing what the old compiler produced.

An entry that will not load -- a truncated write, an OS or toolchain change
-- is deleted and rebuilt rather than raised. A cache that outlives the
process must not be able to turn one bad write into a permanent failure of
every future run. A staging file left behind by a process killed mid-compile
is swept once it is old enough to be certain nothing is still writing it.

The directory is created 0700, and a cache directory other users can write to
is refused rather than used -- everything in it gets `dlopen`ed, so a shared
writable cache would be a way to run code as you.

## Inspecting a kernel

### Seeing the generated C

```
CARRAY_JIT_DUMP=1 ruby your_script.rb
```

prints the source before it is compiled. It opens by saying where it came
from -- the file and line the block was written at, and the block itself --
because a generated file that says only what it does is hard to place months
later:

```c
/*
 *  Generated by carray-jit 0.1.0.
 *
 *  /home/you/work/legendre.rb:12
 *
 *    { |i|
 *      w  = x * legendre[i-1]
 *      wy = w - legendre[i-2]
 *      legendre[i] = wy + w - wy / i
 *    }
 */
```

That header is kept out of the hash the cache is keyed by, so two call sites
that generate the same kernel share one compiled object, and editing the lines
above a kernel does not throw its object away. The file then names the first
site that compiled it. Every kernel carries two loops and
decides between them once, outside the loop -- the contiguous form indexes a
typed pointer, which the compiler can vectorise, and the strided form is what
lets a view run without being copied first:

```c
static void
carray_jit_contiguous (char **pointers, int64_t *strides, int64_t *bounds, ...)
{
  char *const p_legendre = pointers[0];
  const int64_t legendre_s0 = strides[0];
  const double x = reals[0];

  for (int64_t i = bounds[0]; i < bounds[1]; i++) {
    double w = x * ((double *)(p_legendre))[i - 1];
    double wy = w - ((double *)(p_legendre))[i - 2];
    ((double *)(p_legendre))[i] = wy + w - wy / (double)i;
  }
}
```

Every kernel has that same signature, which is what lets one Fiddle::Function
shape serve all of them; the per-kernel detail arrives in the buffers and is
unpacked into named locals at the top, where it also reads better. Abridged
above are the ones this kernel barely uses: `reals` and `integers` for the
captured scalars, `functions` and `data` for the address of each C function
the block called and of each array it handed to one whole, `mask_pointers` and
`mask_strides` for the masks, and `error` for the one thing a cell can raise.
`bounds` carries a start, a limit and a step per axis -- which is also what a
chunk looks like, and is why CArray's sweep can call this kernel directly.

### The carray-jit command

Installing the gem provides a small command for looking after the cache. It
loads only the compiler and its cache, so it works whether or not CArray and
the compiled extension can be loaded -- the CArray version in the environment
name is the one RubyGems says a `require` would activate, which is the one a
running program would have reported itself.

```
$ carray-jit
root         /home/you/.cache/carray-jit
environment  0.1.0-carray3.0.1-arm64-darwin24
kernels      3
size         50.1 KB
limit        512 kernels

other environments:
  0.0.9-carray3.0.1-arm64-darwin24  1.2 MB  last used 2026-01-01
```

```
$ carray-jit list
5a29d9e696a2  16.5 KB  2026-09-01 13:31  /home/you/work/smooth.rb:42
fff2e2d74333  16.5 KB  2026-09-01 13:31  /home/you/work/solve.rb:17
5070c61b1a43  16.5 KB  2026-09-01 13:31  /home/you/work/solve.rb:23
```

A hash says nothing about which kernel it names, so `list` shows where the
kernel was written, and `show` prints the source -- which begins by saying the
same thing, and quotes the block it was generated from:

```
$ carray-jit show 5a29d9e6
/*
 *  Generated by carray-jit 0.1.0.
 *
 *  /home/you/work/smooth.rb:42
 *
 *    { |i|
 *      values[i] = alpha * price[i] + (1.0 - alpha) * values[i-1]
 *    }
 */

#include <stdint.h>
#include <math.h>

static void
carray_jit_contiguous (char **pointers, int64_t *strides, int64_t *bounds, ...)
{
  char *const p_values = pointers[0];
  ...
```

| Command | |
| --- | --- |
| `carray-jit` / `carray-jit status` | where the cache is and how big it is |
| `carray-jit list` | the kernels cached for this environment, and where each was written |
| `carray-jit show <prefix>` | the C source of one cached kernel, block and all |
| `carray-jit clear` | remove this environment's kernels |
| `carray-jit clear --all` | remove every environment's kernels |

### Environment variables

| Variable | Effect |
| --- | --- |
| `CARRAY_JIT_DUMP` | Print generated C to stderr before compiling |
| `CARRAY_JIT_CACHE` | Cache directory (default `~/.cache/carray-jit`), or `none` |
| `CARRAY_JIT_NO_CACHE` | Keep the cache in a temporary directory, removed on exit |
| `CARRAY_JIT_CACHE_LIMIT` | Kernels retained on disk, per environment (default 512) |
| `CARRAY_JIT_CACHE_MAX_AGE_DAYS` | Days an unused environment's directory is kept (default 30) |
| `CARRAY_JIT_CC` | C compiler (default `RbConfig::CONFIG["CC"]`) |
| `CARRAY_JIT_REASSOCIATE` | `0` makes the serial accumulator the default for the process |

## Testing

```
rake test
rake benchmark
```

Every kernel in the suite is checked against the same computation written as
an ordinary Ruby loop -- except the masked ones, which are checked against
CArray's operators -- and the float comparisons are exact rather than within a
tolerance -- a tolerance would hide the two bugs most worth catching, FMA
contraction and computing in the wrong precision. A test whose kernel reduces
says `reassociate: false`, which is what makes its answer comparable to a Ruby
loop's at all.

The tridiagonal solver in `test/test_thomas.rb` is the case the design had to
be able to express: two sweeps in opposite directions, one of them writing two
arrays that share a denominator. It is checked bit for bit against a plain
Ruby solver, and by the residual of `A x - d`.

`benchmark/thomas.rb` times it against a Ruby loop and against LAPACK. Run it
rather than reading a figure off this page: what it prints depends on the
machine it is run on, and what is worth reading is the ratio between the rows.

The Ruby loop is the comparison this gem is about. The LAPACK row is **not** a
claim that this is faster than LAPACK, and three things stand between it and
any such reading:

- `?gtsv` does LU with partial pivoting and solves systems that are not
  diagonally dominant. This solves the ones that are. Skipping the pivot is
  most of the difference.
- What is timed is `CArray::Linalg.solve_tridiagonal`, not `?gtsv` itself: the
  diagonals are passed as views, so there are contiguity copies, plus
  validation and output allocation, inside that number.
- The four arguments `?gtsv` overwrites have to be copied first, and that is
  excluded from the figure, because it is not part of solving.

What the comparison is good for is the other direction. `?gtsv` exists, so
this kernel can be checked against it, and it agrees to within rounding. The
algorithms `jit_for` is actually for, a periodic tridiagonal solve or a
domain-specific recurrence, have no LAPACK entry point to be checked against
at all.

`test/test_views.rb` covers the access tiers: a contiguous row, a strided
column, a reversal, a slice of a slice, and a gather view whose region is
transferred and written back.
