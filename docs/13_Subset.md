# The recognized subset

Anything outside it raises `CArray::JIT::Unsupported`, naming the construct
and its line and column.

**Accepted**

- Integer, Float, imaginary (`2i`), `true` and `false` literals
- The block's parameters: the loop indices
- Block-local variables, assigned before use, reassignable -- including to a
  different type (see [Locals](08_Locals.md))
- Captured CArrays, read and written; captured scalars, read only, Float,
  Integer or Complex. In a block with no indices an array may be named bare
  -- `a` -- which is `a[]`
- `+ - * /`, unary `-`, `**`, comparisons `< <= > >= == !=`
- `&&`, `||`, `!`
- `abs`, `floor`, `ceil`, `round`, `truncate`, `to_i`, `to_f`
- `real`, `imag`, `conjugate`, `arg` and their other Ruby spellings, on a
  Complex or on a real number; `Complex(x, y)` and `Complex(x)` to build one
- `Math::PI`, `Math::E`
- `if`/`elsif`/`else` and the ternary operator, as expressions and as statements
- `a[i] == UNDEF` and `a[i] != UNDEF`, either way round; `a[i] = UNDEF`
- `Math.sqrt`, `cbrt`, `exp`, `log`, `log2`, `log10`, `sin`, `cos`, `tan`,
  `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `hypot`, `asinh`,
  `acosh`, `atanh`
- the postfix spelling of those -- `x.sqrt`, `(0.0415 * (t[i] - 218.8)).tanh`
  -- which `CArray::CoreExtensions` provides (see [Postfix math](08_Locals.md#postfix-math))
- `a[i - c]` and `a[i + c]`, with `c` a non-negative integer literal or an
  integer built from literals and captured integers, one subscript per axis of
  the array; a constant subscript pins an axis, and a computed one gathers or
  scatters
- `%`, which floors as Ruby's does rather than truncating as C's does
- `& | ^ ~ << >>` on integers, and `& | ^` on booleans; a shift is C's shift,
  which is what CArray's own `<<` compiles to
- `(from...to).each { |j| ... }` and `n.times { |j| ... }`, an inner loop
  whose index reads but never writes; `next` and `break` inside it, and `next`
  in the kernel block to skip the cell
- `while cond ... end`, and its modifier form, with `next` and `break` inside
  it; the condition is read at the top of every pass, and a local it reads
  must be a local before the loop.  `while true` is allowed where the body
  holds a `break` or a `raise`, and refused where it holds neither
- a call to a C function -- one from `jit_extern` or `jit_function`, or the
  function's own name inside its body -- as an expression, and *as a
  statement*, where its value is dropped as Ruby drops it and what it did is
  wherever its pointer parameters pointed. It is the only call that may stand
  alone; a `void` function -- borrowed or written here -- may only be called
  there. Under a mask the call does not happen (see
  [Calling a C function](09_CFunctions.md#a-call-may-stand-alone))
- assignment to a cell: `out[i] = ...`, at a cell the loop walks onto -- every
  axis of it either walks with an index at no offset or is pinned, so
  `out[i, 0]` writes a column and `out[i, i]` a diagonal.  Pin every axis and
  nothing walks: `box[0] = ...` writes one cell for every iteration and keeps
  the last, as the same Ruby loop does.  A pinned position is checked against
  the extent before the first cell, so reaching outside is a message rather
  than a store past the end

**Rejected**

Everything else: `for` and `until`, `begin ... end while`, strings, hashes,
symbols, Ruby arrays,
method definitions, `eval`, method calls outside the table above, writing a
cell displaced from the one the loop is on -- `out[i + 1]`, which walks *and*
lands where another iteration walks, so the order decides which survives --
`break` in the kernel block,
`break x` and `next x`, `rand` and every other draw from a generator (fill
an array with `CArray#random!` and read a cell of it -- see [Known
limitations](14_Limitations.md)), `if` without `else` in *expression*
position, arithmetic on a boolean cell, comparing one with a number, and
captured scalars that are not Float, Integer or Complex. On a Complex: ordering
comparisons, `%`, the rounding methods and the bit operators -- which is what
Ruby's Complex refuses too.
