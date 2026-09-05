# Calling a C function

math.h is already handled: `Math.sqrt(x)` compiles to `sqrt(x)`, linked and
inlinable. This is for everything else -- the Bessel functions in libm that
Ruby has no `Math` method for, and, by the same route, anything in a library
you can dlopen.

There are two of these, because they do two different things. `jit_extern`
finds a function someone else compiled, which is Fiddle's job and involves no
compiler at all -- `extern` is C's own word for a body that lives elsewhere.
`jit_function` compiles a body of your own, which is this gem's job. They hand
back the same kind of object, so a kernel calls either without knowing which
it has, and `compiled?` is where the difference stays visible.

```ruby
j0 = CArray.jit_extern("double j0(double)")

CArray.jit_each { out = j0.call(x) }
```

The prototype is what you would copy out of the header. `from:` says which
library to look in -- a name, or a `Fiddle::Handle` you already have -- and
with nothing there the symbol is looked for in what the process has already
loaded, which is where libm's own functions are.

`f.call(x)` is the spelling; `f.(x)` and `f[x]` are accepted too, the second
after `Proc#[]`. All three are real Ruby that computes the same thing if the
block is ever run, which is why the brackets are not a problem: `f[x]` is only
read as a call because the captured name is known to hold a function rather
than an array.

What this buys over applying a function to a whole array is that the call is
an expression like any other. It goes wherever an expression goes -- inside a
stencil, a recurrence, an inner loop -- and a stencil is the case that has no
map form at all, because the cell needs the function at two places at once and
there is no array of intermediate results to hold them:

```ruby
CArray.jit_for(1...n) { |i|
  smoothed[i] = 0.5 * (j0.call(x[i]) + j0.call(x[i-1]))
}
```

Fiddle is asked *where* the function is; it is not asked to call it. Going
through `Fiddle::Function` costs a few hundred nanoseconds per cell, which is
more than most of the arithmetic it would be called for:

```
tgamma over 200,000 cells
  in the kernel         1.63 ms      8.1 ns/element
  Fiddle, per cell    145.67 ms    728.4 ns/element   89x
  Math.gamma map       10.47 ms     52.3 ns/element    6x
```

### A function of your own

`jit_function` takes a block and compiles it:

```ruby
square = CArray.jit_function("double (*)(double)") { |x| x * x + 1 }
```

`double (*)(double)` is the spelling C already has for the type of a function
pointer, which is what this hands out. There is no name because nothing links
by name -- the address is what travels -- so a name would have been invented
to be looked at once. Writing one anyway is allowed, and becomes the symbol in
the compiled object, which is what a profiler and a backtrace will show.

A declaration that gives a name puts that name in scope inside its own body,
as C does, so the function can call itself:

```ruby
fact = CArray.jit_function("double fact(double)") { |n|
  n <= 1.0 ? 1.0 : n * fact.call(n - 1.0)
}
```

The spelling is `.call`, the one every C function takes here, because the
block has to stay runnable in Ruby -- a bare `fact(n - 1.0)` would read better
as C and is not Ruby at all, so it is refused with that message. `fact` in the
block is a spelling, not a symbol: the compiled call goes to
`carray_jit_fact_<digest>`, so it cannot reach anything else in the process
that answers to `fact`. An anonymous declaration gets no recursion, having
nothing to call itself by, which is C's position on a function pointer type
too.

A pointer parameter may be handed on -- `total.call(n - 1, v)` passes the
address the function was given, as C does -- so a recursion can walk an array.
What it cannot do is stop itself running out of stack: a compiled function
that recurses too deep is a SIGSEGV, not a `SystemStackError`. That is C's
bargain, taken along with `void *params`.

### Dividing by zero

`6 % 0` raises in Ruby, and the kernel raises it too: it is handed a place to
report through, and reports. A compiled function has no such place -- it has
the signature its declaration gave it and nothing else, which is the point of
it. So the object carries one of its own: a single exported `int` that the
division helpers write into, declared only when the body can actually reach
it.

```ruby
r = CArray.jit_function("int r(int a, int b)") { |a, b| a % b }
r.call(7, 3)       # => 1
r.call(7, 0)       # => ZeroDivisionError: divided by 0, as r.block would
```

Nothing in the generated C reaches Ruby to do that. The function returns a
number and touches no Ruby value, so its address is still safe to hand to a
library or to call off the GVL; `CFunction#call` is what looks at the flag
afterwards and raises. A caller coming from C sees what C arranges for a
function that has to return something regardless -- the value, and the flag
standing beside it.

A float division is not this case: `1.0 / 0.0` is an infinity in Ruby, in C
and here, so a body that only divides floats declares no flag and pays
nothing for one. Neither is a subscript on a pointer parameter, which is
unchecked by design -- the caller's business, as it is in C.

The declaration stays C rather than becoming a vocabulary of this compiler's
own, because what is being declared is a C function and the types it has to
meet belong to whatever will call it. `void *params` is the point of the
exercise, not an edge of it. C's spellings come with C's own asymmetry: the
integer types have exact-width names, so `uint16_t` and `int32_t` read, while
the floating types are `float` and `double` and there is no `float64_t`.

The return type is stated rather than derived from the body, although it could
be derived. The reason is the one already given for writing a loop's direction
at the call site: a signature is what something outside agrees to, and editing
the body must not silently change it.

The block survives on the function, so what the compiled C computes and what
Ruby computes can be put side by side -- which is the one place in this
compiler where "the C agrees with the Ruby" is checkable rather than argued:

```ruby
square.call(3.0)         # => 10.0, through the compiled C
square.block.call(3.0)   # => 10.0, in Ruby
```

It is called from a kernel like any other, which gives kernels something they
did not have -- a body you can factor and name:

```ruby
smoothstep = CArray.jit_function("double (*)(double)") { |t|
  clamped = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t)
  clamped * clamped * (3.0 - 2.0 * clamped)
}

CArray.jit_each { blended = low + (high - low) * smoothstep.call(w) }
```

Factoring it out costs nothing to run. A function written here is not called
through a pointer: its body is put in the kernel's own C as a `static` and
called by name, so the compiler sees through the call, inlines it, and
vectorises the loop around it as it would have had the expression been written
where it is called. Over 4M cells the smoothstep above takes 0.53 ms either
way, against 3.79 ms when the same body is reached through a pointer.

A borrowed function still goes through the pointer: there is no body here to
paste, only an address, and for it inlining was never on offer.

A body that can fail is pasted like any other. Standing alone it reports a
division with no divisor through a flag in its own compiled object, which is
what `f.call(0)` reads to raise `ZeroDivisionError`; pasted, there is no such
object around it, and the failure belongs to the kernel that is running -- so
the pasted copy takes the kernel's error slot as a last argument and reports
there. The same body called either way raises the same thing, and under a
masked cell it reports nothing, exactly as the kernel's own arithmetic does.

### A call may stand alone

A call is the one thing in the subset that may be written as a statement:

```ruby
CArray.jit_for(n) { |i| record.call(log, i, sample[i]) }
```

Its value is dropped, exactly as Ruby drops the value of a statement, and
what it did is wherever its pointer parameters pointed. Nothing else may
stand there. A computation nobody takes the value of is a line that does
nothing, and refusing it is how a missing `out[i] =` gets caught; a call is
different in kind, because its parameters can carry an address.

Two things follow. A kernel whose only work is a call is a kernel, not a
mistake -- "the kernel writes to no array" no longer refuses it. And `void`
becomes a return type that means something here, borrowed or written: the
reason it was refused is that a cell has nowhere to put it, and a statement
asks for nothing to put anywhere.

```ruby
ignore = CArray.jit_extern("void srand(unsigned int)")
CArray.jit_for(n) { |i| ignore.call(seed[i]) }

record = CArray.jit_function("void record(double log[], int64_t at, double v)") { |log, at, v|
  log[at] = v
}
```

A `void` body is not a special kind of body: it ends in a statement rather
than in the expression it returns, which is the whole of the difference. So
its last line has to do something -- a body ending in `x * 2.0` is refused
the way any body with a computation nobody takes the value of is -- and
calling it where a value is wanted is refused too, with the same words a
borrowed `void` function gets.

A recursion is written the same way, which is what a body walking an array
wants: quicksort's two halves are called for what they do to the run, and
their `0` goes nowhere.

**Under a mask the call does not happen.** Every other statement may run on
bytes that mean nothing and mark what it wrote as missing; a call cannot be
taken back once it has run, so this follows `raise` rather than the
arithmetic -- a cell whose arguments are missing is a cell the function is not
told about. The generated C tests the mask, not the value.

### Its parameters are its whole surface

A compiled function may not reach anything outside its parameter list -- not a
number, not an array, not another compiled function. A captured number could
be written into the C as a literal and a captured function's address as a
constant, but either would put something in the compiled object that no cache
key covers, and an object built for one capture would be handed back for
another.

Two things fall out of that, and they are worth more than the restriction
costs. The first is that `[source, return type, parameter types]` is a
complete key: with nothing captured, the body's text settles which function it
is. The second is that the compiled object is **pure C** -- it touches no Ruby
value and references no Ruby symbol, so the address is safe to call from a
thread that holds no GVL, and from a library that knows nothing about Ruby.
That is more than a Ruby-defined callback usually manages.

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

Nothing about the spelling had to be settled: C settled it long ago. `const`
says a parameter may only be read, so `dydt[0] = ...` compiles and
`coef[0] = ...` is refused; a declarator carries a length where there is one,
so `coef[3]` is checked against the array it is given and `coef[]` is the
caller's business, as it is in C. The whole ODE signature is therefore
sayable, with no half of it invented here:

```ruby
CArray.jit_function(
  "int (*)(double t, const double y[2], double dydt[2], void *params)"
) { |t, y, dydt, params|
  dydt[0] = y[1]
  dydt[1] = -y[0]
  0
}
```

The length matters more than it looks. A subscript in this compiler has always
had an extent behind it, which is what lets a kernel be checked at all; a bare
pointer has none, and `y[7]` would read whatever is there. So
`const double coef[3]` and `const double *coef` are kept apart -- the same
ABI, a different promise.

And the block still agrees with the C. `coef[0]` means the same to a CArray as
to a C pointer, so the body is unchanged between them:

```ruby
poly.call(2.0, coef)         # through the compiled C
poly.block.call(2.0, coef)   # in Ruby, same bits
```

A `void *` stays a slot, because it points at nothing in particular: it takes
its place in the signature -- which is what makes `gsl_function` sayable --
and the body may not reach through it.

A kernel can hand one of its own arrays over the same way:

```ruby
CArray.jit_for(n) { |i| out[i] = poly.call(x[i], coef) }
```

`x[i]` is a cell and `coef` is the whole array, and which is meant comes from
the declaration rather than from the spelling. That is a rule this compiler
did not have before -- a captured name's meaning has come from what it holds,
not from where it stands -- so it is worth saying plainly: a parameter
declared `double` takes a cell, one declared `const double *` takes the array.

The address does not vary with the cell, so it travels beside the captured
scalars rather than through the addressing a cell needs. What the declaration
promised is checked before the loop runs: the data type it points at, the
length if it named one, and that the array carries no mask -- a masked cell's
bytes are out of contract, and a C function has no mask to consult.

The same three are checked by `f.call`, which is the same array reaching the
same C by the other road: `f.call(x, coef)` refuses a masked `coef` where
`f.block.call(x, coef)` would have reached an UNDEF and stopped.

What is refused is carrying a mask, not having a cell under it, so an array
that masks nothing is refused too. The way through is one thing either way:

```ruby
poly.call(2.0, coef.strip_mask(Float::NAN))
```

`#strip_mask` is where the caller says what the C should see where the mask
was -- a NaN that will poison whatever it reaches, a zero that will not, the
choice being the caller's and not this compiler's -- and it hands back an
unmasked entity, which is what the pointer wanted anyway. An array that masked
nothing loses the mask and no values.

One thing to know about the Ruby side: a pointer is walked contiguously, so a
view is packed into an entity for the call and copied back afterwards if the C
may have written to it. `CArray#to_ca` is not what packs it -- that answers
self for a view as well as an entity, and handing the C a view's base pointer
to walk contiguously writes over its neighbours without a word.

One thing the name does not get to do is collide. The generated symbol is
always behind `carray_jit_`, because the dangerous case is the one that does
not fail: `double sin(double)` matches math.h's declaration, so a file
defining it compiles cleanly and the shared object exports libm's `sin`, which
where symbols are interposable replaces sine for whatever loads it next. A
mismatched signature would have been a compile error and been noticed; this
would not.

### One kernel per signature, for a function that arrives as an address

The address travels to the kernel in a buffer, beside the captured scalars,
rather than being linked against. The generated C says nothing about where the
function came from:

```c
typedef double (*f_fn_t)(double);
...
  const f_fn_t f = (f_fn_t) functions[0];
  ((double *)(p_out))[index0] = f(((double *)(p_x))[index0]);
```

So the kernel depends on the **signature**, not the symbol, and one compiled
kernel serves every function of that shape -- `j0`, `y0` and `tgamma` share
one. It also means no `-l` flag, no library path at compile time, and nothing
in the on-disk cache that goes stale when a library moves.

A body pasted into the kernel is the other way round. It is *in* the kernel,
so the kernel is that body's as much as it is the block's, and two bodies that
happen to be declared the same way have to be two kernels -- keyed on the
symbol, which carries a digest of the text. Sharing one would hand the second
function the first one's answer, and say nothing about it.

The other side of that: the address has to arrive with the call rather than
with the kernel, and a wrong prototype is undefined behaviour rather than a
compile error -- the declaration is trusted, exactly as `Fiddle::Function`
trusts it. What is checked is the arity at the call site, and the types the
prototype names: a pointer return has no cell to live in and is refused by
name, and a `void` one is refused wherever a value is wanted -- which is
everywhere but the statement position above.
