# Supported features

## Locals, types and postfix math

### Locals, and what Ruby having no types costs

Types are **assigned, not inferred**: an array's dtype and a captured scalar's class fix the leaves, and everything else follows bottom-up. That is what keeps this small -- there is no type variable to solve for, because the values are right there.

Locals are the one place Ruby's dynamism shows through. A Ruby local holds whatever it was last assigned, and that can change type mid-body:

```ruby
x = 5
y = x / 2      # an integer division: y is 2
x = 1.5        # now x is a Float
```

No single C variable is both, so types are settled in one forward pass and each type gets a variable of its own:

```c
int64_t x = INT64_C(5);
int64_t y = x >> 1;        /* the integer division Ruby did */
double x__2 = 1.5;
```

Reassignment at the same type reuses the variable. A local left with different types on the two arms of a branch does not survive it, and reading it after says so.

A loop is where one forward pass is not enough: the body runs again with what the last pass left behind. So a local that goes round the loop has to be one type, and a body that changes it is refused rather than compiled as whichever type the first pass saw:

```ruby
x = 2
(0...3).each { |j| y = x / 4; x = 1.5 }
#=> `x` enters this loop as an Integer and comes back round as a Float
```

Ruby divides in integers on the first pass and in floats after; no single C variable does that. Writing `x = 2.0` settles it. A local that lives only inside the body may still change type, because it is assigned before it is read on every pass and so nothing crosses the edge.

The version before this one settled locals by joining every assignment's type and declaring the variable once. On the example above it printed the right answer -- by dividing in double where Ruby divided in integers, and then truncating 1.5 to 1 on the way back. Two errors that happened to cancel.

### Postfix math

`CArray::CoreExtensions` is a refinement that puts `sqrt`, `tanh` and the rest on `Float` and `Integer`, so that one formula reads the same whether it is applied to a scalar or to a whole array:

```ruby
using CArray::CoreExtensions

CArray.jit_for(n) { |i| out[i] = (0.0415 * (t[i] - 218.8)).tanh }
```

A per-cell kernel works on scalars pulled out of arrays, which is exactly the scalar half of that polymorphism, so a formula already written that way compiles as it stands.

Only the sixteen names that are 1:1 with math.h are accepted. The refinement's other methods are refused by name, `expm1` and `log1p` most pointedly: C has functions by those names, and they exist because `exp(x) - 1` and `log(1 + x)` lose precision for small x -- which is what the Ruby side computes. Lowering them to the C functions would quietly produce different numbers, the same trap as `%` and `fmod`.

One honesty note: carray-jit reads the block's syntax, not its meaning, so it compiles `x.sqrt` whether or not the file that wrote it said `using CArray::CoreExtensions`, since it reads the block rather than running it. Write the `using` all the same: it is what lets the same formula be handed a scalar, where it is Ruby that runs and `Float#sqrt` has to exist.

## Branches, and asking whether a cell is missing

`if` works in statement position, so a kernel can decide what to write:

```ruby
CArray.jit_for(n) { |i|
  if source[i] == UNDEF
    result[i] = 0.0
  else
    result[i] = Math.sqrt(source[i])
  end
}
```

`a[i] == UNDEF` is how Ruby already asks whether a cell is missing, and it means the same here. It compiles to a read of the mask byte, never of the value. `a[i] = UNDEF` marks a cell missing, and leaves its bytes alone. Mentioning UNDEF at all makes the kernel a masked one, whatever its arrays happen to carry.

This is only cheap because the subset is CArray's, not Ruby's: `== UNDEF` does not have to be a general comparison against a general value, it can be an idiom with a meaning of its own.

It also settles a question the implicit propagation cannot. Asking about the mask is not reading the value, so it carries no mask into what the branch writes -- which is what makes filling a hole possible:

```ruby
if source[i] == UNDEF
  result[i] = 0.0          # no cell was read; the result is present
else
  result[i] = source[i]    # a value was read, but not a masked one
end
```

Reading the *value* still propagates, including in a condition: a branch taken on `source[i] > 0.0` where `source[i]` is masked was decided by garbage, so what it writes is masked.

And it brings the reference back. A masked kernel written this way can be checked against the same loop written in Ruby, which a kernel relying on implicit propagation cannot be -- `source[i]` hands Ruby an UNDEF, and `UNDEF * 2.0` does not run.

A branch with no `else` writes nothing on the path not taken, so the cell keeps both its value and its mask -- as the same `if` would in Ruby. As an *expression*, `if` still needs an `else`, because there every cell needs a value.

`next` and `break` work in an inner loop, which is how a search is written:

```ruby
CArray.jit_for(rows) { |i|
  found = -1
  (0...columns).each { |j|
    if source[i, j] > threshold
      found = j
      break
    end
  }
  first[i] = found
}
```

`next` in the kernel block skips the cell, the way it would end a block Ruby was running: the cell keeps its value and its mask, and the loop moves on.

`break` in the kernel block is refused. Ruby's `break` in a block is not a loop exit but a return from the method the block was passed to, carrying a value, and the value is one this cannot produce. `break x` and `next x` are refused for the same kind of reason: the inner loop's own value is never used, so a value would be dropped silently.

An `each` with a `break` in it is what a `while` would have been, and it is still the better way to write a loop whose bound you know: the bound sits in the extent, so the kernel cannot fail to stop, and a cell that ran out of iterations can be told from one that converged.

```ruby
CArray.jit_for(n) { |i|
  x = a[i]
  taken = 0
  (0...cap).each { |k|                       # cap is an ordinary local
    break if (x * x - a[i]).abs <= tolerance * a[i]
    x = 0.5 * (x + a[i] / x)
    taken = taken + 1
  }
  root[i] = x
  passes[i] = taken                          # 0 means it was already there
}
```

That is bit-for-bit the same as the Ruby `while` loop it replaces, iteration counts included, and about 38x faster over 200,000 cells.

### while

Where the bound is not knowable, `while` says so:

```ruby
CArray.jit_for(n) { |i|
  guess = a[i]
  while (guess * guess - a[i]).abs > tolerance
    guess = 0.5 * (guess + a[i] / guess)
  end
  root[i] = guess
}
```

The condition is read at the top of every pass, as Ruby's is, and `next` and `break` mean inside it what they mean inside an inner loop. A local the condition reads has to be a local before the loop: the condition is read before the body is, so a name only the body assigns is not in scope where the condition wants it, and says so rather than reading whatever C left in the variable. `begin ... end while` is refused -- it is the one loop in Ruby that tests after the body, and a reader who missed the `begin` would take the first pass for a conditional one.

What it gives up is the guarantee that the loop ends. Nothing here can decide that in general, and no invented bound would help: a cap the compiler chose would be a number nobody could choose, and the loops whose bound *is* knowable already have the spelling above. So this is C's bargain, the same one a `jit_function` that recurses too deep already takes.

It bites harder than the equivalent mistake in Ruby. A kernel that does not return cannot be interrupted: the generated loop has no interrupt check in it, a signal is handled on the main thread, and the main thread is inside the call. `Ctrl-C` is not delivered until the call returns, and that is true whether or not the GVL is held -- releasing it lets *other* threads run, which `jit_for` does, but it does not give the running loop a place to notice a signal. A runaway pass ends with a signal from another terminal.

The one case that can be read off the page is refused rather than compiled:

```ruby
while true            # with no `break` and no `raise` in the body
  ...
end
```

That is not a guess about the data -- the condition is never going to be false and the body holds no way out -- so refusing it costs no program that would have worked. `while true` with a `break` in it is an ordinary thing to write and is left alone.

A loop entered on a value read from a missing cell is in the position a branch taken on one is in, and is treated the same way: it was decided by bytes that mean nothing, so what the body writes is masked. Running on those bytes costs more here than it does in a branch, though -- garbage decides how many passes there are -- so a kernel whose loop condition reads a cell that may be missing should say so with `if a[i] == UNDEF`, which is the advice masked arithmetic already gets.

`until` is not in the subset. `while` with the condition negated is the same loop, and one spelling of it is enough to keep.

Neither costs anything here. An inner loop carrying a `break` is not a fold and so is not split into partial sums to begin with -- it stays the serial chain it always was -- and a `next` in the kernel block is if-converted like any other branch: a per-cell loop with an `if` in it still compiles to `fadd.2d` and `fcmgt.2d` on the contiguous path.

## Raising from a kernel

A kernel can stop and say why:

```ruby
CArray.jit_for(n) { |i|
  raise "depth went negative" if depth[i] < 0.0
  out[i] = Math.sqrt(depth[i])
}
```

What comes back is a `RuntimeError` with that message -- what `raise "..."` gives in Ruby -- and the loop stops where it raised: the cell that raised is not written, and neither are the ones after it. The cells before it keep what the kernel wrote, as they do when a division with no divisor stops one.

The message is written out and the class is not named. Both follow from where the message goes: C has nothing to carry a string out of a cell in, so the message is registered as the kernel is compiled and the cell writes a code for it into the error slot the kernel is already watching. The raise itself happens on the Ruby side, once the loop has stopped and there is a Ruby stack to raise on. A message the block computed would have nothing registered, and a class is not a value the slot can carry.

A cell whose value is missing does not raise. `raise "..." if a[i] < 0` under a mask was decided by bytes that mean nothing, and this is the rule the division helper already keeps and that `if` keeps for what it writes.

A `jit_function` body raises the same way. It reports into the flag it already reports a division by zero into -- the one in its own compiled object where it stands alone, the kernel's slot where it is pasted -- and the message travels with the function, so `f.call(-1.0)` and the same body reached from a kernel raise the same thing. A kernel takes the messages of the bodies it pasted as its own; the codes agree because they come from the messages.

## Booleans, complex numbers, unsigned 64-bit and masks

### Boolean arrays

A boolean CArray is a byte holding 0 or 1, and Ruby reads that byte as `true` or `false`. A kernel is the cell loop, so the cell's reading is the one it takes: `flags[i]` is a condition, not a number.

```ruby
CArray.jit_for(n) { |i|
  result[i] = flags[i] ? source[i] : -source[i]
}
CArray.jit_for(n) { |i| flags[i] = source[i] > threshold }
```

`if flags[i]`, `!flags[i]`, `flags[i] && others[i]`, `flags[i] == others[i]` and `flags[i] == true` all mean what they mean in Ruby. Storing normalises to 0 or 1, because that is CArray's contract for the type and a kernel is not where it stops holding; `flags[i] = 1` and `flags[i] = 0` are accepted, as CArray accepts them.

Two things are refused rather than compiled:

```ruby
result[i] = flags[i] + 1
#=> cannot combine types boolean and double

result[i] = flags[i] == 1 ? 9.0 : 0.0
#=> a boolean cell compares with `true` and `false`, not with a number: in
#   Ruby `flags[i] == 1` is false whatever the cell holds
```

The first is what Ruby says at the cell -- `true + 1` raises -- although the array-level `flags + 1` promotes to integers. Both spellings of a kernel take the cell rule, since both are the cell loop.

The second Ruby answers rather than refuses, and its answer is always false. Compiling it would be compiling a bug, and an easy one to write: the reference implementation this project started from had `@flag[addr] == 1` in it, and returned NaN for every cell because of it.

### Complex arrays

`cmplx64` and `cmplx128` are read, computed in and written like any other type. C99 lays a complex out as its two reals in order, which is what CArray stores, so a cell is read in place rather than assembled.

`cmplx64` computes in `float _Complex`, as `float32` computes in `float`: a cell is read narrow, worked on narrow, and stored narrow. That is what CArray's own cmplx64 kernels do -- their generated `+` adds in `cmplx64_t` -- so the two agree.

Most of the math family follows: `csqrtf` and `cabsf` rather than the double ones, as CArray computes them, and `sinf` rather than `sin` for a `float32`. A libm transcendental is written to complete at its own width, so asking it the narrow question gets the narrow answer.

Three things do not follow, and none of them is an omission. The rule behind all three is one line: **an expression that cancels borrows the wider type; one that does not is computed at the operand's width.**

**`log` and `**` stay wide.** `clog(z)` needs `log|z|`, and on the unit circle that is the difference of two numbers near one. Computed in `float` the magnitude rounds to exactly one and the real part of the answer is not rounded but lost -- measured over four thousand points of the unit circle, the error is 3.2e-08 where the answer itself is 3.7e-08. `**` inherits it, `cpow` being `cexp(z * clog(a))`; with a constant base the `clog` is exact and the damage stops, but the base is not always constant. Reached in double and rounded back, the same measurement gives 1.3e-15.

**Multiplying two complex numbers stays wide,** and so does dividing them: `(ac - bd)` and Smith's method both subtract numbers of the same size. Adding and subtracting do not cancel past the one rounding a store makes anyway, and stay narrow.

Division is also the one operation where a kernel has never agreed with CArray. It follows Ruby -- Smith's method in the order `complex.c` writes it -- where CArray's `cmplx128` divide is the C library's `__divdc3`, and the two disagree in every cell. For `cmplx64` they now agree, both of them reaching the answer in double and rounding once; that is a coincidence of the widths rather than a change of reference.

```ruby
CArray.jit_for(n) { |i|
  spectrum[i] = signal[i] * Complex(0.0, -1.0) + offset
}
CArray.jit_for(n) { |i| power[i] = spectrum[i].abs }
```

`real`, `imag`, `conjugate`, `arg` and `abs` are the way between the two worlds -- three of them hand back a Float, which is what lets a complex kernel write into a real array. `Complex(x, y)` is the way in from two real arrays. Storing a Complex into a real array is refused, as Ruby refuses it.

The fifteen math functions CArray computes on a complex array -- `sqrt`, `exp`, `log`, the six trigonometric, the six hyperbolic -- compile to their C99 `c`-prefixed forms. The ones a complex CArray refuses are refused here too: `log10`, `log2` and `cbrt` have no complex form in C99, and `atan2` and `hypot` are about the plane a complex number already is.

Ruby's Complex arithmetic is not C's, in ways that show up in the last bit and in the sign of a zero, so three of the four operators are compiled to match Ruby rather than to C's operator:

- A Complex **added to** a real number keeps its imaginary part exactly as it was, rather than having a zero added to it: Ruby's own `f_add` returns the other operand as it stands when one of them is the exact Integer zero a real operand carries. `Complex(1.0, -0.0) + 2.0` is `3.0-0.0i`; widening the `2.0` to a complex first would make it `3.0+0.0i`.
- `z * x` **scales each part**, while `x * z` coerces and multiplies out in full -- so Ruby's two answers differ from each other, and each is reproduced its own way.
- **Division** is Smith's method in the order `complex.c` writes it, which is not the order the C library's `__divdc3` arrives at.

Subtraction is the one that needs no help: there the zero really is subtracted, in Ruby as in C.

`**` is the one operation here whose answer is **not** the Ruby loop's to the last bit. Ruby raises a Complex to a power by binary powering, with exact answers along the axes; `cpow` goes round through `exp` and `log`. Measured over four hundred values, the two are within three machine epsilons at `** 2` and fourteen at `** 7` -- growing with the exponent, as a sequence of multiplications would. Where the answer overflows they stop agreeing about the parts at all: Ruby's squaring overflows both of them, while `cpow` overflows the magnitude and multiplies a zero cosine into one part.

That is accepted rather than reproduced. `complex.c`'s algorithm has changed between Ruby versions -- the exact-answers-along-the-axes case arrived in 3.3 -- so reproducing it would tie a compiled kernel to the interpreter that compiled it, which is a worse trade than a few last bits.

`z * z` is exact, and cheaper than the library call, so a square is worth writing out. It is not the same expression as `z ** 2` on the axes, where Ruby's power returns an exact zero for the part the multiplication computes a signed zero for.

What *is* refused on a Complex is what **Ruby itself refuses**: ordering comparisons, `%`, `floor` and its family, `to_f`, the bit operators, and storing one into a real array. `==` and `!=` work, as they do in Ruby.

That is the whole line. A construct Ruby answers is compiled, even where the answer costs something to reproduce:

- `Complex(x)` is taken for `Complex(x, 0.0)`. In Ruby the two are `==` but not identical: the shorter one's imaginary part is an exact Integer zero, which an addition returns the other operand untouched for, so `Complex(1.0) + Complex(2.0, -0.0)` keeps a sign of a zero that `Complex(1.0, 0.0) + Complex(2.0, -0.0)` loses. Nothing else tells them apart -- multiplication, division and the infinities all agree -- and carrying an exactly-zero imaginary part through the type lattice to reproduce that one case would cost more to read than it is worth.
- A **real** number answers `real`, `imag`, `conjugate` and `arg` too, and a kernel answers them the same way. Three of them compute nothing. `arg` is the one whose class Ruby leaves to the value -- an Integer zero for a number that is not negative, `Math::PI` for one that is -- so it is a Float throughout here; the number is the same either way. It is read off the sign bit, as Ruby reads it, so `-0.0.arg` is pi although `-0.0 < 0` is false.

### Masks

A masked cell means "no value here". A plain CArray has no mask at all -- one comes into being only once a cell is actually marked -- so a kernel over unmasked arrays touches no masks and creates none.

When some array does carry one, the mask propagates the way CArray's own operators propagate it: any cell that fed a result masks that result, and an array that is written gets a mask if it did not have one.

```ruby
source[2] = UNDEF
CArray.jit_for(7) { |i| result[i] = source[i-1] + source[i+1] }
#=> result[1] and result[3] are UNDEF; they are the cells that read source[2]
```

Masking follows the offsets, and each output takes its mask from its own inputs rather than from everything the body read.

The mask of a value is built the same shape as the value. A flat union of everything an expression touches would be wrong for a conditional: `a[i] == UNDEF ? 0.0 : a[i]` does not read `a[i]` when the condition holds, and Ruby's answer there is not missing. So the conditional's mask is conditional too, and a block-local carries a mask alongside its value.

The value under a masked cell is **out of contract**: a kernel may compute anything into it, so long as the mask ends up right (`guides/devel/05`). That is what lets the loop stay branchless -- every cell is computed and only the mask is reconciled, instead of a test per cell to protect data that was never protected.

One thing cannot simply be computed and discarded: an integer division by a zero that sits under a masked cell. CArray's own kernels skip masked cells and so never reach their divide-by-zero check; a branchless kernel divides anyway, so the report is gated on the mask.

Where a kernel leaves the masking implicit, the reference is CArray's operators rather than a Ruby loop: `source[i]` hands Ruby an `UNDEF`, and `UNDEF * 2.0` does not run. A kernel that says `== UNDEF` outright is a Ruby loop again, and is checked as one.

A view that reinterprets the element size (`refer(CA_INT32, ...)` over a float64 array) is refused when it carries a mask: it gets a mask of its own shape, but one of those mask cells covers a fraction of a parent cell, so writing one marks its neighbour, and a per-cell kernel cannot express that.

### Unsigned 64-bit

`uint64` is the one width that does not fold into the `int64_t` a kernel otherwise computes its integers in: the values it holds above 2^63 are exactly the ones `int64_t` cannot carry. It computes in a `uint64_t` of its own.

What that fourth type answers to is CArray, not Ruby. Ruby's Integer has no width, so it has no opinion about what `2**64 - 1` plus one is; CArray's own operators wrap, and so does a kernel:

```ruby
max = 2**64 - 1
u = CArray.uint64(1) { max }
one = CArray.uint64(1) { 1 }

(u + one)[0]                                #=> 0, as CArray wraps
CArray.jit_each { out = u + one }
out[0]                                      #=> 0, the same
```

`+ - * / % ** & | ^ ~ << >>`, the comparisons, unary minus and `abs` all take the answer CArray's operators take. Two of them are worth naming:

- **`/` and `%` need no correction.** They are floored elsewhere, to agree with Ruby; with no sign to disagree about, C's truncation already floors.
- **`floor`, `ceil` and `round` are the number itself**, as `Integer#floor` is in Ruby. They do not go through a Float on the way, which is what would lose everything above 2^53.

Mixed with the other numeric types, the result is CArray's: an `int64` operand joins `uint64` rather than the other way round, and a float takes both out of the integers.

```ruby
CArray.result_type(:uint64, :int64)         #=> :uint64
CArray.result_type(:uint64, :float64)       #=> :float64
```

That order is C's usual arithmetic conversions as well. It is not containment -- neither integer type holds the other -- but it is what both of the languages with an opinion say.

#### Giving an accumulator the type

A local has no data type of its own, so it takes Ruby's: `total = 0` is an `int64`. Added to a `uint64` cell it would come back round the loop as a `uint64`, and one C variable is one type, so the kernel says so:

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

See [Locals](#locals-types-and-postfix-math) for what a local's type is otherwise, and [CScalar](02_KernelShapes.md#jit_each-and-jit_map-when-nothing-reaches-a-neighbour) for what else one is good for.

## Calling a C function

math.h is already handled: `Math.sqrt(x)` compiles to `sqrt(x)`, linked and inlinable. This is for everything else -- the Bessel functions in libm that Ruby has no `Math` method for, and, by the same route, anything in a library you can dlopen.

There are two of these, because they do two different things. `jit_extern` finds a function someone else compiled, which is Fiddle's job and involves no compiler at all -- `extern` is C's own word for a body that lives elsewhere. `jit_function` compiles a body of your own, which is this gem's job. They hand back the same kind of object, so a kernel calls either without knowing which it has, and `compiled?` is where the difference stays visible.

```ruby
j0 = CArray.jit_extern("double j0(double)")

CArray.jit_each { out = j0.call(x) }
```

The prototype is what you would copy out of the header. `from:` says which library to look in -- a name, or a `Fiddle::Handle` you already have -- and with nothing there the symbol is looked for in what the process has already loaded, which is where libm's own functions are.

`f.call(x)` is the spelling; `f.(x)` and `f[x]` are accepted too, the second after `Proc#[]`. All three are real Ruby that computes the same thing if the block is ever run, which is why the brackets are not a problem: `f[x]` is only read as a call because the captured name is known to hold a function rather than an array.

What this buys over applying a function to a whole array is that the call is an expression like any other. It goes wherever an expression goes -- inside a stencil, a recurrence, an inner loop -- and a stencil is the case that has no map form at all, because the cell needs the function at two places at once and there is no array of intermediate results to hold them:

```ruby
CArray.jit_for(1...n) { |i|
  smoothed[i] = 0.5 * (j0.call(x[i]) + j0.call(x[i-1]))
}
```

Fiddle is asked *where* the function is; it is not asked to call it. Going through `Fiddle::Function` costs a few hundred nanoseconds per cell, which is more than most of the arithmetic it would be called for:

```
tgamma over 200,000 cells
  in the kernel         1.63 ms      8.1 ns/element
  Fiddle, per cell    145.67 ms    728.4 ns/element   89x
  Math.gamma map       10.47 ms     52.3 ns/element    6x
```

#### A function of your own

`jit_function` takes a block and compiles it:

```ruby
square = CArray.jit_function("double (*)(double)") { |x| x * x + 1 }
```

`double (*)(double)` is the spelling C already has for the type of a function pointer, which is what this hands out. There is no name because nothing links by name -- the address is what travels -- so a name would have been invented to be looked at once. Writing one anyway is allowed, and becomes the symbol in the compiled object, which is what a profiler and a backtrace will show.

A declaration that gives a name puts that name in scope inside its own body, as C does, so the function can call itself:

```ruby
fact = CArray.jit_function("double fact(double)") { |n|
  n <= 1.0 ? 1.0 : n * fact.call(n - 1.0)
}
```

The spelling is `.call`, the one every C function takes here, because the block has to stay runnable in Ruby -- a bare `fact(n - 1.0)` would read better as C and is not Ruby at all, so it is refused with that message. `fact` in the block is a spelling, not a symbol: the compiled call goes to `carray_jit_fact_<digest>`, so it cannot reach anything else in the process that answers to `fact`. An anonymous declaration gets no recursion, having nothing to call itself by, which is C's position on a function pointer type too.

A pointer parameter may be handed on -- `total.call(n - 1, v)` passes the address the function was given, as C does -- so a recursion can walk an array. What it cannot do is stop itself running out of stack: a compiled function that recurses too deep is a SIGSEGV, not a `SystemStackError`. That is C's bargain, taken along with `void *params`.

#### Dividing by zero

`6 % 0` raises in Ruby, and the kernel raises it too: it is handed a place to report through, and reports. A compiled function has no such place -- it has the signature its declaration gave it and nothing else, which is the point of it. So the object carries one of its own: a single exported `int` that the division helpers write into, declared only when the body can actually reach it.

```ruby
r = CArray.jit_function("int r(int a, int b)") { |a, b| a % b }
r.call(7, 3)       # => 1
r.call(7, 0)       # => ZeroDivisionError: divided by 0, as r.block would
```

Nothing in the generated C reaches Ruby to do that. The function returns a number and touches no Ruby value, so its address is still safe to hand to a library or to call off the GVL; `CFunction#call` is what looks at the flag afterwards and raises. A caller coming from C sees what C arranges for a function that has to return something regardless -- the value, and the flag standing beside it.

A float division is not this case: `1.0 / 0.0` is an infinity in Ruby, in C and here, so a body that only divides floats declares no flag and pays nothing for one. Neither is a subscript on a pointer parameter, which is unchecked by design -- the caller's business, as it is in C.

The declaration stays C rather than becoming a vocabulary of this compiler's own, because what is being declared is a C function and the types it has to meet belong to whatever will call it. `void *params` is the point of the exercise, not an edge of it. C's spellings come with C's own asymmetry: the integer types have exact-width names, so `uint16_t` and `int32_t` read, while the floating types are `float` and `double` and there is no `float64_t`.

The return type is stated rather than derived from the body, although it could be derived. The reason is the one already given for writing a loop's direction at the call site: a signature is what something outside agrees to, and editing the body must not silently change it.

The block survives on the function, so what the compiled C computes and what Ruby computes can be put side by side -- which is the one place in this compiler where "the C agrees with the Ruby" is checkable rather than argued:

```ruby
square.call(3.0)         # => 10.0, through the compiled C
square.block.call(3.0)   # => 10.0, in Ruby
```

It is called from a kernel like any other, which gives kernels something they did not have -- a body you can factor and name:

```ruby
smoothstep = CArray.jit_function("double (*)(double)") { |t|
  clamped = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t)
  clamped * clamped * (3.0 - 2.0 * clamped)
}

CArray.jit_each { blended = low + (high - low) * smoothstep.call(w) }
```

Factoring it out costs nothing to run. A function written here is not called through a pointer: its body is put in the kernel's own C as a `static` and called by name, so the compiler sees through the call, inlines it, and vectorises the loop around it as it would have had the expression been written where it is called. Over 4M cells the smoothstep above takes 0.53 ms either way, against 3.79 ms when the same body is reached through a pointer.

A borrowed function still goes through the pointer: there is no body here to paste, only an address, and for it inlining was never on offer.

A body that can fail is pasted like any other. Standing alone it reports a division with no divisor through a flag in its own compiled object, which is what `f.call(0)` reads to raise `ZeroDivisionError`; pasted, there is no such object around it, and the failure belongs to the kernel that is running -- so the pasted copy takes the kernel's error slot as a last argument and reports there. The same body called either way raises the same thing, and under a masked cell it reports nothing, exactly as the kernel's own arithmetic does.

#### One of these calling another

A function written here may call another one written here, and it is pasted rather than pointed at for the reason a kernel pastes it:

```ruby
root = CArray.jit_function("double root(double)") { |x|
  raise "no square root of a negative" if x < 0
  Math.sqrt(x)
}

hypot = CArray.jit_function("double (*)(double a, double b)") { |a, b|
  root.call(a * a + b * b)
}
```

The name may be a constant as well as a local, and for a method there is no other way: a `def` closes over nothing, so `SQUARE.call(x)` is how a compiled body reaches another one from inside a method. A constant is looked up where the block was written, as it is for a kernel.

`root`'s definition goes into `hypot`'s translation unit as a `static`, and `hypot` calls it by symbol -- so what leaves is still one self-contained object with one address, and the compiler can see through the call. A chain of them arrives together: a kernel that calls the outermost gets every body under it, with the helpers they want and the messages they raise.

Which is what the error slot buys here too. `root` reports a failure, so the copy pasted into `hypot` takes the caller's slot, and `hypot`'s own copy takes its caller's -- however deep it goes, and whether the top of it is a kernel or a `#call` from Ruby. So `hypot.call(3.0, 4.0)` is `5.0`, and a body that hands `root` a negative raises the string `root` wrote, at whatever depth it was reached.

This is the one thing a body may reach outside its parameters, and the next section says why it is not really an exception.

#### A call may stand alone

A call is the one thing in the subset that may be written as a statement:

```ruby
CArray.jit_for(n) { |i| record.call(log, i, sample[i]) }
```

Its value is dropped, exactly as Ruby drops the value of a statement, and what it did is wherever its pointer parameters pointed. Nothing else may stand there. A computation nobody takes the value of is a line that does nothing, and refusing it is how a missing `out[i] =` gets caught; a call is different in kind, because its parameters can carry an address.

Two things follow. A kernel whose only work is a call is a kernel, not a mistake -- "the kernel writes to no array" no longer refuses it. And `void` becomes a return type that means something here, borrowed or written: the reason it was refused is that a cell has nowhere to put it, and a statement asks for nothing to put anywhere.

```ruby
ignore = CArray.jit_extern("void srand(unsigned int)")
CArray.jit_for(n) { |i| ignore.call(seed[i]) }

record = CArray.jit_function("void record(double log[], int64_t at, double v)") { |log, at, v|
  log[at] = v
}
```

A `void` body is not a special kind of body: it ends in a statement rather than in the expression it returns, which is the whole of the difference. So its last line has to do something -- a body ending in `x * 2.0` is refused the way any body with a computation nobody takes the value of is -- and calling it where a value is wanted is refused too, with the same words a borrowed `void` function gets.

A recursion is written the same way, which is what a body walking an array wants: quicksort's two halves are called for what they do to the run, and their `0` goes nowhere.

**Under a mask the call does not happen.** Every other statement may run on bytes that mean nothing and mark what it wrote as missing; a call cannot be taken back once it has run, so this follows `raise` rather than the arithmetic -- a cell whose arguments are missing is a cell the function is not told about. The generated C tests the mask, not the value.

#### Its parameters are its whole surface

A compiled function may not reach anything outside its parameter list -- not a number, not an array, not a function borrowed with `jit_extern`. A captured number could be written into the C as a literal and a borrowed function's address as a constant, but either would put something in the compiled object that no cache key covers, and an object built for one capture would be handed back for another. The borrowed one has a second reason: an address is all there is of it, and there is nowhere in a compiled object to keep one. A kernel is handed its addresses at call time; a function has no such moment.

A function compiled here is the exception, and stays inside the rule that produced the restriction: what goes into the caller is the callee's body and the symbol standing over it, and that symbol -- which carries the digest of the body -- goes into the key. So two blocks spelled the same that call different functions are two functions, which is the whole of what the key had to settle.

Two things fall out, and they are worth more than the restriction costs. The first is that `[source, return type, parameter types, the symbols it calls]` is a complete key: nothing else reaches the compiled object, so the body's text settles which function it is. The second is that the compiled object is **pure C** -- it touches no Ruby value and references no Ruby symbol, so the address is safe to call from a thread that holds no GVL, and from a library that knows nothing about Ruby. That is more than a Ruby-defined callback usually manages.

What replaces capturing is what C already does: take a pointer.

```ruby
# gsl_function is `double (*)(double x, void *params)`, and the second half is
# not optional however little the function does with it.
f = CArray.jit_function("double (*)(double x, void *params)") { |x, params| x * x }
```

A pointer that points at numbers is indexed, and takes a CArray:

```ruby
poly = CArray.jit_function("double (*)(double x, const double coef[3])") { |x, c|
  c[0] + c[1] * x + c[2] * x * x
}
poly.call(2.0, CArray.double(3) { |i| [1.0, 2.0, 3.0][i] })   # => 17.0
```

Nothing about the spelling had to be settled: C settled it long ago. `const` says a parameter may only be read, so `dydt[0] = ...` compiles and `coef[0] = ...` is refused; a declarator carries a length where there is one, so `coef[3]` is checked against the array it is given and `coef[]` is the caller's business, as it is in C. The whole ODE signature is therefore sayable, with no half of it invented here:

```ruby
CArray.jit_function(
  "int (*)(double t, const double y[2], double dydt[2], void *params)"
) { |t, y, dydt, params|
  dydt[0] = y[1]
  dydt[1] = -y[0]
  0
}
```

The length matters more than it looks. A subscript in this compiler has always had an extent behind it, which is what lets a kernel be checked at all; a bare pointer has none, and `y[7]` would read whatever is there. So `const double coef[3]` and `const double *coef` are kept apart -- the same ABI, a different promise.

And the block still agrees with the C. `coef[0]` means the same to a CArray as to a C pointer, so the body is unchanged between them:

```ruby
poly.call(2.0, coef)         # through the compiled C
poly.block.call(2.0, coef)   # in Ruby, same bits
```

A `void *` stays a slot, because it points at nothing in particular: it takes its place in the signature -- which is what makes `gsl_function` sayable -- and the body may not reach through it.

A kernel can hand one of its own arrays over the same way:

```ruby
CArray.jit_for(n) { |i| out[i] = poly.call(x[i], coef) }
```

`x[i]` is a cell and `coef` is the whole array, and which is meant comes from the declaration rather than from the spelling. That is a rule this compiler did not have before -- a captured name's meaning has come from what it holds, not from where it stands -- so it is worth saying plainly: a parameter declared `double` takes a cell, one declared `const double *` takes the array.

The address does not vary with the cell, so it travels beside the captured scalars rather than through the addressing a cell needs. What the declaration promised is checked before the loop runs: the data type it points at, the length if it named one, and that the array carries no mask -- a masked cell's bytes are out of contract, and a C function has no mask to consult.

The same three are checked by `f.call`, which is the same array reaching the same C by the other road: `f.call(x, coef)` refuses a masked `coef` where `f.block.call(x, coef)` would have reached an UNDEF and stopped.

What is refused is carrying a mask, not having a cell under it, so an array that masks nothing is refused too. The way through is one thing either way:

```ruby
poly.call(2.0, coef.strip_mask(Float::NAN))
```

`#strip_mask` is where the caller says what the C should see where the mask was -- a NaN that will poison whatever it reaches, a zero that will not, the choice being the caller's and not this compiler's -- and it hands back an unmasked entity, which is what the pointer wanted anyway. An array that masked nothing loses the mask and no values.

One thing to know about the Ruby side: a pointer is walked contiguously, so a view is packed into an entity for the call and copied back afterwards if the C may have written to it. `CArray#to_ca` is not what packs it -- that answers self for a view as well as an entity, and handing the C a view's base pointer to walk contiguously writes over its neighbours without a word.

One thing the name does not get to do is collide. The generated symbol is always behind `carray_jit_`, because the dangerous case is the one that does not fail: `double sin(double)` matches math.h's declaration, so a file defining it compiles cleanly and the shared object exports libm's `sin`, which where symbols are interposable replaces sine for whatever loads it next. A mismatched signature would have been a compile error and been noticed; this would not.

#### One kernel per signature, for a function that arrives as an address

The address travels to the kernel in a buffer, beside the captured scalars, rather than being linked against. The generated C says nothing about where the function came from:

```c
typedef double (*f_fn_t)(double);
...
  const f_fn_t f = (f_fn_t) functions[0];
  ((double *)(p_out))[index0] = f(((double *)(p_x))[index0]);
```

So the kernel depends on the **signature**, not the symbol, and one compiled kernel serves every function of that shape -- `j0`, `y0` and `tgamma` share one. It also means no `-l` flag, no library path at compile time, and nothing in the on-disk cache that goes stale when a library moves.

A body pasted into the kernel is the other way round. It is *in* the kernel, so the kernel is that body's as much as it is the block's, and two bodies that happen to be declared the same way have to be two kernels -- keyed on the symbol, which carries a digest of the text. Sharing one would hand the second function the first one's answer, and say nothing about it.

The other side of that: the address has to arrive with the call rather than with the kernel, and a wrong prototype is undefined behaviour rather than a compile error -- the declaration is trusted, exactly as `Fiddle::Function` trusts it. What is checked is the arity at the call site, and the types the prototype names: a pointer return has no cell to live in and is refused by name, and a `void` one is refused wherever a value is wanted -- which is everywhere but the statement position above.

## The recognized subset

Anything outside it raises `CArray::JIT::Unsupported`, naming the construct and its line and column.

**Accepted**

- Integer, Float, imaginary (`2i`), `true` and `false` literals
- The block's parameters: the loop indices
- Block-local variables, assigned before use, reassignable -- including to a different type (see [Locals](#locals-types-and-postfix-math))
- Captured CArrays, read and written; captured scalars, read only, Float, Integer or Complex. In a block with no indices an array may be named bare -- `a` -- which is `a[]`
- `+ - * /`, unary `-`, `**`, comparisons `< <= > >= == !=`
- `&&`, `||`, `!`
- `abs`, `floor`, `ceil`, `round`, `truncate`, `to_i`, `to_f`
- `real`, `imag`, `conjugate`, `arg` and their other Ruby spellings, on a Complex or on a real number; `Complex(x, y)` and `Complex(x)` to build one
- `Math::PI`, `Math::E`
- `if`/`elsif`/`else` and the ternary operator, as expressions and as statements
- `a[i] == UNDEF` and `a[i] != UNDEF`, either way round; `a[i] = UNDEF`
- `Math.sqrt`, `cbrt`, `exp`, `log`, `log2`, `log10`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `hypot`, `asinh`, `acosh`, `atanh`
- the postfix spelling of those -- `x.sqrt`, `(0.0415 * (t[i] - 218.8)).tanh` -- which `CArray::CoreExtensions` provides (see [Postfix math](#postfix-math))
- `a[i - c]` and `a[i + c]`, with `c` a non-negative integer literal or an integer built from literals and captured integers, one subscript per axis of the array; a constant subscript pins an axis, and a computed one gathers or scatters
- `%`, which floors as Ruby's does rather than truncating as C's does
- `x += e` and the rest of the operator assignments, on a local, on a cell (`work[i, k] += e`) and on a CScalar; each is the assignment it stands for, so a fold written with `+=` is still split into partial sums. `||=` and `&&=` are refused, being about nil and false rather than about arithmetic
- `& | ^ ~ << >>` on integers, and `& | ^` on booleans; a shift is C's shift, which is what CArray's own `<<` compiles to
- `(from...to).each { |j| ... }` and `n.times { |j| ... }`, an inner loop whose index addresses reads and writes alike -- `work[i, j] = ...` is a row of workspace for the cell (see [A row of workspace per cell](02_KernelShapes.md#a-row-of-workspace-per-cell)); `next` and `break` inside it, and `next` in the kernel block to skip the cell
- `from.step(to, s) { |j| ... }` and `(from...to).step(s) { |j| ... }`, the same loop counting by a literal stride: `(n-1).step(0, -1)` is a downward sweep, and `to` is included there as Ruby includes it. Two loops in one body may both be written `{ |k| ... }`; each keeps its own range
- `while cond ... end`, and its modifier form, with `next` and `break` inside it; the condition is read at the top of every pass, and a local it reads must be a local before the loop.  `while true` is allowed where the body holds a `break` or a `raise`, and refused where it holds neither
- a call to a C function -- one from `jit_extern` or `jit_function`, the function's own name inside its body, or, inside a `jit_function` body, another function written with `jit_function` -- as an expression, and *as a statement*, where its value is dropped as Ruby drops it and what it did is wherever its pointer parameters pointed. It is the only call that may stand alone; a `void` function -- borrowed or written here -- may only be called there. Under a mask the call does not happen (see [Calling a C function](#a-call-may-stand-alone))
- assignment to a cell: `out[i] = ...`, at a cell the loop walks onto -- every axis of it either walks with an index at no offset or is pinned, so `out[i, 0]` writes a column and `out[i, i]` a diagonal.  Pin every axis and nothing walks: `box[0] = ...` writes one cell for every iteration and keeps the last, as the same Ruby loop does.  A pinned position is checked against the extent before the first cell, so reaching outside is a message rather than a store past the end

**Rejected**

Everything else: `for` and `until`, `begin ... end while`, strings, hashes, symbols, Ruby arrays, method definitions, `eval`, method calls outside the table above, writing a cell displaced from the one the loop is on -- `out[i + 1]`, which walks *and* lands where another iteration walks, so the order decides which survives -- `break` in the kernel block, `break x` and `next x`, `rand` and every other draw from a generator (fill an array with `CArray#random!` and read a cell of it -- see [Known limitations](#known-limitations)), `if` without `else` in *expression* position, arithmetic on a boolean cell, comparing one with a number, and captured scalars that are not Float, Integer or Complex. On a Complex: ordering comparisons, `%`, the rounding methods and the bit operators -- which is what Ruby's Complex refuses too.

## Known limitations

- **Integer overflow wraps**, as CArray's own operators wrap. Ruby's Integer is arbitrary precision; the generated C uses `int64_t`, so a kernel that would grow past 2^63 wraps instead. Float kernels are unaffected.
- **Object arrays are not handled.** `CA_OBJECT` holds Ruby values rather than numbers, and reaching into Ruby from inside a kernel would give up what compiling it was for.
- **`**` on a Complex is the one place the answer is not bit-for-bit Ruby's.** It is within a few machine epsilons, growing with the exponent. What is refused on a Complex is what Ruby refuses -- ordering comparisons, `%`, the rounding methods, the bit operators. See [Complex arrays](#complex-arrays).
- **A sine and a cosine of the same argument are one `sincos` call.** The C compiler merges them, and its sine differs from `sin` in the last bit for some arguments, where Ruby calls `sin`. Either flag that stops it costs more elsewhere than the bit is worth here, so it is documented rather than disabled; see [Design notes](05_DesignNotes.md#a-sine-beside-a-cosine-is-sincos-and-is-allowed-to-be).
- **A reduction does not take Ruby's order.** An accumulator is split into partial sums by default, which is usually the more accurate answer and is not the Ruby loop's; `reassociate: false` asks for that order back. `sum(axis:)`, whose kernels are written for the shape, is still faster at the reductions it covers.
- **A `while` may fail to return, and nothing can interrupt it.** The loop is in the subset now, and the bound that used to be compulsory is not: a compiler-invented cap would be a number nobody could choose, since the loops whose bound is knowable are already `(0...cap).each` with a `break`.  What comes with that is C's bargain, the one a `jit_function` recursing too deep already takes.  It bites harder here than it would in Ruby: a generated loop has no interrupt check in it, so `Ctrl-C` does not reach a running kernel -- whether or not it holds the GVL -- and a runaway pass ends with a signal from another terminal.  The one case that can be read off the page, `while true` with no `break` and no `raise` in it, is refused.
- **`until` is not in the subset.** `while` with the condition negated is the same loop, and one spelling of it is enough to keep.
- **An inner loop's stride is a literal.** It is what says which way the loop runs, and the C is written one way or the other before anything is known, so `k.step(0, s)` with `s` a captured integer is refused. `downto`, `upto` and `reverse_each` are refused by name, with `step` named as the spelling to use -- one way of counting down is enough to keep, and it is the one an extent already takes.
- **A kernel draws no random numbers.** Generate them outside and pass the array in: `noise = CArray.double(n).random!` and then `a[i] + noise[i]`, which is a captured array like any other. There is no `rand` in the subset, and the reason is the same one that makes it easy to work around. A generator has one state and hands out its numbers in the order it was asked, and this compiler does not fix the order it asks in: a stencil's border is a second loop over the frame, a reduction may split its accumulator, and a kernel runs with the GVL released, which is not where Ruby's own `Random` -- the one `CArray#random!` calls through -- may be reached at all. An array filled before the call has none of those questions: it was drawn in one order, by Ruby's generator, and the kernel reads a cell of it like any other cell.
- **An operand that is not an entity is transferred before the loop.** A kernel walks memory, so an array that is not one -- a view that does not fold to an entity, a `CAObject` computing its cells in Ruby -- has the box the kernel touches transferred into a packed buffer first, and written back afterwards if the kernel wrote it. The box, not the array: an extent covering two cells transfers two. What that costs is a copy; what it changes is when the cells are read. An array whose cells are computed on read is read once per cell per call, so two reads of one cell in a kernel give the same number where the same Ruby loop would give two -- and a one-cell source is one number for the whole loop. Drawing random numbers that way therefore works, and means what filling an array before the call means.
- **A block's source must be recoverable.** Blocks defined in `eval` or in a console have no file to read back; pass `source:` there, or set `RubyVM.keep_script_lines = true` before defining them. This also ties the gem to CRuby, which CArray requires anyway.
- **Nothing existing is replaced.** `jit_for` is a new method, not a faster `each_index`: the two differ in what they reject, and a caller should be able to choose.
