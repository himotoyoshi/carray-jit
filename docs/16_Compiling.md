# What compiling costs, and where kernels are kept

## Requirements on the array

Contiguity is not one of them. What is:

- **not an object array** -- `CA_OBJECT` holds Ruby values, not numbers
- **not a size-reinterpreting view carrying a mask** -- see [Masks](12_Types.md#masks)
- **writable**, when the kernel writes to it

## What compiling costs

Compiling is not free, and the trade is worth stating in numbers rather than
in the abstract:

```
compile, never seen before      247.9 ms
  same kernel, new process        4.2 ms     (the object is on disk)
  same kernel, same process      14.2 us     (already loaded)

per element: Ruby 114.0 ns, compiled 0.4 ns, saved 113.6 ns

pays for itself at
  never compiled before       2,182,000 elements
  compiled by an earlier run     37,000 elements
  already loaded                    125 elements
```

Only the first time is expensive, and most of those 248 ms are macOS checking
a freshly written binary rather than the compiler working -- the same C
through `cc -O3 -fPIC -shared` by hand takes about 50 ms. After that a kernel
costs 4 ms in a new process, so the second run of a script pays for itself at
tens of thousands of elements.

The last row is not the compiler at all. A call that finds everything already
loaded still costs about 13 microseconds, and that figure does not move with
the size of the array: it is reading the block's source, splitting the
captures, broadcasting the shapes and packing the buffers. So a kernel called
in a loop does not pay for itself at one element, and where it starts to
depends on what it is being weighed against -- which is two different
questions with two different answers:

```
(a + b) * (c - a) + b * c - a

     n    Ruby loop      plain       fuse    jit_each
     1        0.5 us     2.5 us     4.3 us      13.0 us
   100       39.6 us     2.4 us     3.6 us      12.8 us
  1000      394.3 us     5.1 us     4.6 us      11.7 us
  3000     1181.1 us    11.1 us     9.0 us      12.9 us
 10000     3934.9 us    36.8 us    28.5 us      15.8 us
```

Against **a Ruby loop** -- the reader who came here from `jit_for`, writing a
recurrence or a stencil that has no array form -- the crossing is at a few
dozen elements: tens for an expression this wide, around a hundred for one as
narrow as `a * 2 + 1`.

Against **the array expression** -- the reader choosing `jit_each` over
`a + b * c`, which already runs in C -- it is a few thousand: about 3,000 for
the expression above and nearer 9,000 for a two-operator one, because what is
being saved is the passes over the data and a narrower expression has fewer of
them to save.

Below those, write the expression. The compiled kernel is for the sizes where
the passes cost more than the call does.

Which is why the cache is on by default. Turning it off with
`CARRAY_JIT_NO_CACHE` puts every run back in the first row.

## Caching

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

## Where compiled kernels are kept

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
