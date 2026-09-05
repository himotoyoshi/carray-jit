# Booleans, complex numbers, unsigned 64-bit and masks

## Boolean arrays

A boolean CArray is a byte holding 0 or 1, and Ruby reads that byte as `true`
or `false`. A kernel is the cell loop, so the cell's reading is the one it
takes: `flags[i]` is a condition, not a number.

```ruby
CArray.jit_for(n) { |i|
  result[i] = flags[i] ? source[i] : -source[i]
}
CArray.jit_for(n) { |i| flags[i] = source[i] > threshold }
```

`if flags[i]`, `!flags[i]`, `flags[i] && others[i]`, `flags[i] == others[i]`
and `flags[i] == true` all mean what they mean in Ruby. Storing normalises to
0 or 1, because that is CArray's contract for the type and a kernel is not
where it stops holding; `flags[i] = 1` and `flags[i] = 0` are accepted, as
CArray accepts them.

Two things are refused rather than compiled:

```ruby
result[i] = flags[i] + 1
#=> cannot combine types boolean and double

result[i] = flags[i] == 1 ? 9.0 : 0.0
#=> a boolean cell compares with `true` and `false`, not with a number: in
#   Ruby `flags[i] == 1` is false whatever the cell holds
```

The first is what Ruby says at the cell -- `true + 1` raises -- although the
array-level `flags + 1` promotes to integers. Both spellings of a kernel take
the cell rule, since both are the cell loop.

The second Ruby answers rather than refuses, and its answer is always false.
Compiling it would be compiling a bug, and an easy one to write: the reference
implementation this project started from had `@flag[addr] == 1` in it, and
returned NaN for every cell because of it.

## Complex arrays

`cmplx64` and `cmplx128` are read, computed in and written like any other
type. C99 lays a complex out as its two reals in order, which is what CArray
stores, so a cell is read in place rather than assembled.

`cmplx64` computes in `float _Complex`, as `float32` computes in `float`:
a cell is read narrow, worked on narrow, and stored narrow. That is what
CArray's own cmplx64 kernels do -- their generated `+` adds in `cmplx64_t` --
so the two agree.

Most of the math family follows: `csqrtf` and `cabsf` rather than the double
ones, as CArray computes them, and `sinf` rather than `sin` for a `float32`.
A libm transcendental is written to complete at its own width, so asking it
the narrow question gets the narrow answer.

Three things do not follow, and none of them is an omission. The rule behind
all three is one line: **an expression that cancels borrows the wider type;
one that does not is computed at the operand's width.**

**`log` and `**` stay wide.** `clog(z)` needs `log|z|`, and on the unit circle
that is the difference of two numbers near one. Computed in `float` the
magnitude rounds to exactly one and the real part of the answer is not
rounded but lost -- measured over four thousand points of the unit circle,
the error is 3.2e-08 where the answer itself is 3.7e-08. `**` inherits it,
`cpow` being `cexp(z * clog(a))`; with a constant base the `clog` is exact
and the damage stops, but the base is not always constant. Reached in double
and rounded back, the same measurement gives 1.3e-15.

**Multiplying two complex numbers stays wide,** and so does dividing them:
`(ac - bd)` and Smith's method both subtract numbers of the same size. Adding
and subtracting do not cancel past the one rounding a store makes anyway, and
stay narrow.

Division is also the one operation where a kernel has never agreed with
CArray. It follows Ruby -- Smith's method in the order `complex.c` writes it
-- where CArray's `cmplx128` divide is the C library's `__divdc3`, and the
two disagree in every cell. For `cmplx64` they now agree, both of them
reaching the answer in double and rounding once; that is a coincidence of the
widths rather than a change of reference.

```ruby
CArray.jit_for(n) { |i|
  spectrum[i] = signal[i] * Complex(0.0, -1.0) + offset
}
CArray.jit_for(n) { |i| power[i] = spectrum[i].abs }
```

`real`, `imag`, `conjugate`, `arg` and `abs` are the way between the two
worlds -- three of them hand back a Float, which is what lets a complex
kernel write into a real array. `Complex(x, y)` is the way in from two real
arrays. Storing a Complex into a real array is refused, as Ruby refuses it.

The fifteen math functions CArray computes on a complex array -- `sqrt`,
`exp`, `log`, the six trigonometric, the six hyperbolic -- compile to their
C99 `c`-prefixed forms. The ones a complex CArray refuses are refused here
too: `log10`, `log2` and `cbrt` have no complex form in C99, and `atan2` and
`hypot` are about the plane a complex number already is.

Ruby's Complex arithmetic is not C's, in ways that show up in the last bit
and in the sign of a zero, so three of the four operators are compiled to
match Ruby rather than to C's operator:

- A Complex **added to** a real number keeps its imaginary part exactly as it
  was, rather than having a zero added to it: Ruby's own `f_add` returns the
  other operand as it stands when one of them is the exact Integer zero a
  real operand carries. `Complex(1.0, -0.0) + 2.0` is `3.0-0.0i`; widening
  the `2.0` to a complex first would make it `3.0+0.0i`.
- `z * x` **scales each part**, while `x * z` coerces and multiplies out in
  full -- so Ruby's two answers differ from each other, and each is
  reproduced its own way.
- **Division** is Smith's method in the order `complex.c` writes it, which is
  not the order the C library's `__divdc3` arrives at.

Subtraction is the one that needs no help: there the zero really is
subtracted, in Ruby as in C.

`**` is the one operation here whose answer is **not** the Ruby loop's to the
last bit. Ruby raises a Complex to a power by binary powering, with exact
answers along the axes; `cpow` goes round through `exp` and `log`. Measured
over four hundred values, the two are within three machine epsilons at `** 2`
and fourteen at `** 7` -- growing with the exponent, as a sequence of
multiplications would. Where the answer overflows they stop agreeing about
the parts at all: Ruby's squaring overflows both of them, while `cpow`
overflows the magnitude and multiplies a zero cosine into one part.

That is accepted rather than reproduced. `complex.c`'s algorithm has changed
between Ruby versions -- the exact-answers-along-the-axes case arrived in
3.3 -- so reproducing it would tie a compiled kernel to the interpreter that
compiled it, which is a worse trade than a few last bits.

`z * z` is exact, and cheaper than the library call, so a square is worth
writing out. It is not the same expression as `z ** 2` on the axes, where
Ruby's power returns an exact zero for the part the multiplication computes a
signed zero for.

What *is* refused on a Complex is what **Ruby itself refuses**: ordering
comparisons, `%`, `floor` and its family, `to_f`, the bit operators, and
storing one into a real array. `==` and `!=` work, as they do in Ruby.

That is the whole line. A construct Ruby answers is compiled, even where the
answer costs something to reproduce:

- `Complex(x)` is taken for `Complex(x, 0.0)`. In Ruby the two are `==` but
  not identical: the shorter one's imaginary part is an exact Integer zero,
  which an addition returns the other operand untouched for, so
  `Complex(1.0) + Complex(2.0, -0.0)` keeps a sign of a zero that
  `Complex(1.0, 0.0) + Complex(2.0, -0.0)` loses. Nothing else tells them
  apart -- multiplication, division and the infinities all agree -- and
  carrying an exactly-zero imaginary part through the type lattice to
  reproduce that one case would cost more to read than it is worth.
- A **real** number answers `real`, `imag`, `conjugate` and `arg` too, and a
  kernel answers them the same way. Three of them compute nothing. `arg` is
  the one whose class Ruby leaves to the value -- an Integer zero for a
  number that is not negative, `Math::PI` for one that is -- so it is a Float
  throughout here; the number is the same either way. It is read off the sign
  bit, as Ruby reads it, so `-0.0.arg` is pi although `-0.0 < 0` is false.

## Masks

A masked cell means "no value here". A plain CArray has no mask at all -- one
comes into being only once a cell is actually marked -- so a kernel over
unmasked arrays touches no masks and creates none.

When some array does carry one, the mask propagates the way CArray's own
operators propagate it: any cell that fed a result masks that result, and an
array that is written gets a mask if it did not have one.

```ruby
source[2] = UNDEF
CArray.jit_for(7) { |i| result[i] = source[i-1] + source[i+1] }
#=> result[1] and result[3] are UNDEF; they are the cells that read source[2]
```

Masking follows the offsets, and each output takes its mask from its own
inputs rather than from everything the body read.

The mask of a value is built the same shape as the value. A flat union of
everything an expression touches would be wrong for a conditional:
`a[i] == UNDEF ? 0.0 : a[i]` does not read `a[i]` when the condition holds,
and Ruby's answer there is not missing. So the conditional's mask is
conditional too, and a block-local carries a mask alongside its value.

The value under a masked cell is **out of contract**: a kernel may compute
anything into it, so long as the mask ends up right (`guides/devel/05`). That
is what lets the loop stay branchless -- every cell is computed and only the
mask is reconciled, instead of a test per cell to protect data that was never
protected.

One thing cannot simply be computed and discarded: an integer division by a
zero that sits under a masked cell. CArray's own kernels skip masked cells and
so never reach their divide-by-zero check; a branchless kernel divides anyway,
so the report is gated on the mask.

Where a kernel leaves the masking implicit, the reference is CArray's
operators rather than a Ruby loop: `source[i]` hands Ruby an `UNDEF`, and
`UNDEF * 2.0` does not run. A kernel that says `== UNDEF` outright is a Ruby
loop again, and is checked as one.

A view that reinterprets the element size (`refer(CA_INT32, ...)` over a
float64 array) is refused when it carries a mask: it gets a mask of its own
shape, but one of those mask cells covers a fraction of a parent cell, so
writing one marks its neighbour, and a per-cell kernel cannot express that.

## Unsigned 64-bit

`uint64` is the one width that does not fold into the `int64_t` a kernel
otherwise computes its integers in: the values it holds above 2^63 are exactly
the ones `int64_t` cannot carry. It computes in a `uint64_t` of its own.

What that fourth type answers to is CArray, not Ruby. Ruby's Integer has no
width, so it has no opinion about what `2**64 - 1` plus one is; CArray's own
operators wrap, and so does a kernel:

```ruby
max = 2**64 - 1
u = CArray.uint64(1) { max }
one = CArray.uint64(1) { 1 }

(u + one)[0]                                #=> 0, as CArray wraps
CArray.jit_each { out = u + one }
out[0]                                      #=> 0, the same
```

`+ - * / % ** & | ^ ~ << >>`, the comparisons, unary minus and `abs` all take
the answer CArray's operators take. Two of them are worth naming:

- **`/` and `%` need no correction.** They are floored elsewhere, to agree
  with Ruby; with no sign to disagree about, C's truncation already floors.
- **`floor`, `ceil` and `round` are the number itself**, as `Integer#floor`
  is in Ruby. They do not go through a Float on the way, which is what would
  lose everything above 2^53.

Mixed with the other numeric types, the result is CArray's: an `int64`
operand joins `uint64` rather than the other way round, and a float takes both
out of the integers.

```ruby
CArray.result_type(:uint64, :int64)         #=> :uint64
CArray.result_type(:uint64, :float64)       #=> :float64
```

That order is C's usual arithmetic conversions as well. It is not
containment -- neither integer type holds the other -- but it is what both of
the languages with an opinion say.

### Giving an accumulator the type

A local has no data type of its own, so it takes Ruby's: `total = 0` is an
`int64`. Added to a `uint64` cell it would come back round the loop as a
`uint64`, and one C variable is one type, so the kernel says so:

```ruby
CArray.jit_for(1) { |i|
  total = 0
  (0...2).each { |j| total = total + source[j] }
  out[i] = total
}
#=> `total` enters this loop as an Integer and comes back round as a uint64
```

A `CScalar` is a value with a data type, so seeding from one settles it:

```ruby
seed = CScalar.uint64() { 0 }

CArray.jit_for(1) { |i|
  total = seed
  (0...2).each { |j| total = total + source[j] }
  out[i] = total
}
```

See [Locals](08_Locals.md) for what a local's type is otherwise, and
[CScalar](07_ElementWise.md) for what else one is good for.
