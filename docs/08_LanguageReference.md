# Language reference

This chapter states what a block may contain, what each construct means, and what is refused. The other chapters teach the language by example. This one is for looking things up, and it tries to be complete rather than gentle.

The block language is a subset of Ruby. A construct in the subset means what Ruby means by it, except where §10 says otherwise. A construct outside the subset is refused when the block is read, with `CArray::JIT::Unsupported`, before anything is compiled or run. Nothing falls back to running the block as Ruby.

## 1. Notation and terms

- **Kernel**: the C function a block becomes.
- **Cell**: one element of an array.
- **Capture**: a name the block reads from the scope it was written in.
- **Index**: a block parameter, or the parameter of an inner loop. An index is an integer.
- **Local**: a name assigned inside the block.
- **Local array**: an array the block makes for itself with a constructor (§5.9).
- **Refused**: the block raises `CArray::JIT::Unsupported`, a subclass of `CArray::JIT::Error` and so of `StandardError`. Where the refusal can point at the source, the message ends with "(at line L, column C)".

## 2. Entry points

A block reaches the compiler through one of these methods. They share one language; they differ in what the block's parameters are and what the block's value means.

| Method | Parameters | Value of the block |
|---|---|---|
| `CArray.jit_for(*extents) { \|i, j, ...\| }` | one index per extent | none; the block writes arrays |
| `CArray.jit_each { }` | none | none; the block writes arrays |
| `CArray.jit_map { }` | none | the last statement, collected into a new array |
| `array.jit_init { \|i, j, ...\| }` | one index per axis of the receiver | the last statement, written into the receiver's cell |
| `CArray.jit_stencil(*arrays, border:, type:, into:) { \|w, ...\| }` | one window per array | the last statement, collected into the result |
| `CArray.jit_contract(*free) { \|i, j, k\| }` | the indices | one expression, or one write as the last statement |
| `CArray.jit_function(prototype) { \|params\| }` | the prototype's parameters | the last statement, unless the return type is `void` |
| `CArray.jit_call(prototype) { }` | none; the prototype names them | as `jit_function` |

`CArray.jit_extern` binds a function compiled elsewhere and takes no block.

**Rules for every block:**

- The block is never called. Its source is read from the file, or from `RubyVM.keep_script_lines`. A block whose source cannot be found or no longer matches its file is refused.
- Only required parameters are allowed. Optional, rest, keyword and block parameters are refused.
- An empty body is refused.
- A body that writes no array and calls nothing is refused, for the methods whose block has no value.
- An index may not be named after a C keyword or a name the generated code uses (`pointers`, `strides`, `bounds`, `reals`, `integers`, `functions`, `data`, `mask_pointers`, `mask_strides`, `error`, any name containing `__`, any name starting with `carray_jit_`). A local with such a name is renamed silently.

### 2.1 `jit_for`

Each extent is an Integer `n`, meaning `0...n`; a Range, neither endless nor descending; or an `Enumerator::ArithmeticSequence` with a non-zero step. There must be as many extents as indices, and at least one. The loop runs in the direction of the extent's step; the direction is not derived from the body.

Arrays are captured and indexed: `out[i] = a[i] + 1`. A bare array name is refused. A CScalar is a cell with no index, written `s[]` or `s`.

### 2.2 `jit_each` and `jit_map`

The block takes no parameters. Every captured array name stands for the current cell, written bare (`a`) or as `a[]`. `a[i]` is refused, and so is `out[] = ...`: a write is `out = ...`. Arrays broadcast; a CScalar stretches. Writing an array that is stretched is refused.

For `jit_map`, the last statement is the value. It may be an assignment, whose value is what was assigned. A boolean value is refused, because no array type holds it. A last statement that makes a local array is refused.

A name the block makes a local array under, where the same name is a CArray outside, is refused.

### 2.3 `jit_stencil`

The parameters are windows onto the given arrays, which must share a shape. A window is read with one literal offset per axis: `w[-1, 0]`. Each offset is an integer literal or `+`, `-` and `*` over literals. A captured array read with no subscript, or with `[]`, is the current cell; read with subscripts it is an absolute position, not an offset. A stencil writes no array.

`border:` is one of `:mask`, `:skip`, `:zero`, `:clamp` and `:wrap`. `type:` and `into:` may not both be given.

### 2.4 `jit_contract`

The body is one expression, or a write `res[i, j] = expr` as its last statement. Called with no arguments, an index that appears once is free and an index that repeats is summed. Called with Symbols, the named indices are free and the block parameters are summed; a name in both is refused. An array that is both written and read is refused, as are locals before the summand, local arrays, generators, and an index inside a computed subscript.

### 2.5 `jit_function` and `jit_call`

The prototype is a C declaration. Its types are the keywords `const unsigned signed void char short int long float double _Complex complex`, the fixed-width types `int8_t` to `uint64_t`, and `size_t ssize_t ptrdiff_t intptr_t uintptr_t`. `long double` and a pointer return type are refused.

A number parameter computes as `double` (from `float` or `double`), `int64` (from `char` to `long long`), `uint64` (from `unsigned long`, `unsigned long long` and `size_t`) or `complex`. A pointer to numbers is indexed like an array; `const` makes it read-only, and `void *` cannot be indexed. A bare pointer is a value only as a condition, where it tests for NULL (`p == nil` is accepted).

A function body captures nothing except C functions. It calls itself as `name.call(...)`. It may not use `UNDEF` or allocate a local array on the heap.

For `jit_call` the block takes no parameters: the prototype's names are the parameters, and their values are read from the locals of the same names where the call is written. Assigning one is refused.

## 3. Captures

A name the block reads but does not assign is a capture. A name starting with a capital letter (including a path such as `Float::INFINITY`) is evaluated where the block was written. Any other name must be a defined local there, or the block is refused.

What a captured value becomes depends on its class:

| Class | Becomes |
|---|---|
| `CArray`, including `CScalar` | an array |
| `CArray::JIT::CFunction` | a C function |
| `CArray::Rng` | a random number generator |
| `Float` | a `double` |
| `Integer` within int64 | an `int64` |
| `Integer` in `2**63 ... 2**64` | a `uint64` |
| `Complex` | a `complex` |

Any other value is refused, including `true`, `false`, `nil`, `Rational`, `String`, `Symbol`, `Range`, `Array` and `Proc`. An Integer outside both ranges is refused. `UNDEF`, `Math` and `Math::*` are not captures.

A captured scalar is read-only in the sense that the kernel cannot change the outer variable. Assigning a name that is also a local outside makes a new local inside the kernel; the outer variable keeps its value. Reading the name before that assignment is refused.

A generator may be captured in `jit_for`, `jit_each` and `jit_map`. It is refused in a stencil, a contraction and a function body. Ruby's `Random`, `rand` and `srand` are refused with a pointer to `CArray::Rng`.

## 4. Lexical elements

**Accepted anywhere an expression is:**

- integer literals, which compute as `int64`. A literal in `2**63 ... 2**64` is written to C as a `uint64` constant; a larger one is refused;
- float literals, which compute as `double`. An infinite literal such as `1e400` is `INFINITY`;
- imaginary literals (`2i`, `2.5i`), which compute as `complex`;
- `true` and `false`;
- parentheses around exactly one expression.

**Accepted only in one position:**

| Element | Where |
|---|---|
| a string literal | the format of `printf`, and the message of `raise` |
| a Symbol | the type of `CArray.new` / `CArray.empty`, and the key `rng:` |
| an Array literal | the shape of `CArray.new` / `CArray.empty`, and the right-hand side of a parallel assignment |
| a Range literal | the receiver of an inner `each` or `step` |
| `nil` | a pointer test in a function body |
| `UNDEF` | `x = UNDEF`, `a[...] = UNDEF`, and `== UNDEF` / `!= UNDEF` |
| `Math::PI`, `Math::E` | anywhere; other `Math::` constants are refused |

Everything else in an expression position is refused: `nil` elsewhere, Rational literals, strings and interpolation, Symbols, Hashes, `self`, instance, global and class variables, `defined?`.

## 5. Statements

### 5.1 Assignment

`x = e` binds a local. The right-hand side may be a constructor, which makes a local array (§5.9). Assigning an index is refused, and so is assigning a number to a name that is a local array in sight. A chained assignment `x = y = e` is refused.

In `jit_each`, `jit_map` and `jit_init`, `x = e` where `x` names a captured array writes the current cell, and `x = UNDEF` masks it.

### 5.2 Operator assignment

`x op= e` means `x = x op e`, with `op` one of `+ - * / % ** & | ^ << >>`. `x` must already be assigned. `a[...] op= e` is the same on a cell. `||=` and `&&=` are refused: no number in a kernel is `nil` or `false`.

### 5.3 Parallel assignment

`a, b = e1, e2` evaluates every value on the right before writing anything on the left. The targets are locals or index targets. The right-hand side is unbracketed, has no splat, and has as many values as there are targets. Nested targets, splats, a trailing comma and attribute targets are refused. A parallel assignment cannot be a block's value.

### 5.4 Writing a cell

`a[subs] = e` writes a captured array, a local array or a pointer parameter. A captured array is written at a cell the kernel walks to (an index, with or without an offset), at a fixed position, or at a computed position. `a[subs] = UNDEF` masks the cell and leaves its value.

### 5.5 Conditionals

`if`, `elsif` and `else` work as statements, and `else` is optional there. The modifier `stmt if cond` is the same statement. A condition must be boolean (§6.3); in a function body a pointer is also a condition.

As an expression, `if` and the ternary need an `else`, and each branch is one expression. `elsif` is refused in an expression; a nested ternary is accepted.

`unless`, in either form, is refused.

### 5.6 `while`

`while cond ... end` and the modifier `stmt while cond`. `begin ... end while` is refused. `while true` is refused unless a `break` or `raise` can leave it. `until` is refused.

A local first assigned inside a `while` cannot be read after it.

### 5.7 Inner loops

| Form | Runs `k` over |
|---|---|
| `(a...b).each { \|k\| }` | `a` up to `b`, excluding `b` |
| `(a..b).each { \|k\| }` | `a` up to `b`, including `b` |
| `n.times { \|k\| }` | `0` up to `n`, excluding `n` |
| `from.step(to, s) { \|k\| }` | `from` towards `to`, including `to`, in steps of `s` |
| `(a...b).step(s) { \|k\| }` | `a` up to `b`, excluding `b`, in steps of `s` |

The block takes exactly one parameter. A step is a non-zero integer literal, optionally negated; a Range may not step down. The bounds are integers. In a kernel, they must be built from literals, captured scalars and enclosing indices; a bound read from a local or a cell is refused when the kernel is called. A function body has no such restriction.

An inner index may not reuse the name of an index in scope. Two loops side by side may reuse a name.

`downto`, `upto`, `reverse_each`, `each_with_index`, `each_with_object` and `for` are refused, each with the spelling to use instead.

A local first assigned inside an inner loop cannot be read after it.

### 5.8 `break`, `next`, `return`, `raise` and `printf`

- `break` leaves the innermost inner loop or `while`. At the top of the block it is refused.
- `next` continues the innermost loop. At the top of the block it skips the rest of the cell.
- Neither takes a value.
- `return` is refused: a body's value is its last statement.
- `raise "message"` is a statement. The message is a string literal, with no exception class. The kernel stops at the end of the pass and raises `RuntimeError` with that message. A `raise` reached under a masked cell is ignored.
- `printf("format", args...)` prints and flushes. Integer arguments take `d i u x X o`; real arguments take `e E f F g G a A`; a complex argument prints as two reals; a boolean prints as an integer. A wrong count is refused.

A call to a C function may stand as a statement; its value is discarded, and a `void` function may only appear here. Any other expression as a statement is refused.

### 5.9 Local arrays

A local array is made by assigning a constructor:

- `CArray.<type>(d1, ...)`, with the type names CArray uses (`int8` ... `uint64`, `float32`, `float64`, `cmplx64`, `cmplx128`, `boolean`) and its aliases `byte`, `short`, `int`, `float` (float32), `double` (float64), `complex` (cmplx64) and `dcomplex` (cmplx128). The cells start at zero.
- `CArray.new(:type, [d1, ...])`, whose cells start at zero.
- `CArray.empty(:type, [d1, ...])`, whose cells are not set.

`object` and `fixlen` are refused, as are `zeros`, `ones`, `full`, a constructor with a block, and a constructor with keywords.

An extent is an integer literal, or `+`, `-` and `*` over literals, and must be at least 1. An extent over captured integers is computed when the kernel starts, and that array is allocated on the heap. An extent from an index, a local or a cell is refused.

A local array of up to 4 KiB stands in the kernel's frame, with up to 16 KiB in all; larger arrays are allocated on the heap. A function body may not allocate on the heap.

A local array is read and written with as many subscripts as it has axes. A literal subscript is checked when the block is read; any other subscript is checked as it runs and raises `IndexError` out of range. A negative literal subscript is refused. A local array cannot be read bare, has no methods, and is out of scope after the block that made it. One made on only one branch of a conditional cannot be read after it.

### 5.10 Intrinsics

`sum(w)`, `min(w)` and `max(w)` are values. `sort(w)` is a statement. Each takes exactly one local array, of one axis.

- `sum` adds in index order and returns the element's computation type.
- `min` and `max` skip NaN, return NaN for an array of nothing but NaN, and keep the first of two equal values.
- `sort` puts every NaN after every number.

They are refused on a captured array, a scalar, an expression, two arguments, a boolean array, and (except `sum`) a complex array. A kernel that carries masks refuses all four.

## 6. Expressions

### 6.1 Operators

| Kind | Operators |
|---|---|
| arithmetic | `+ - * / %`, `**` |
| comparison | `< <= > >= == !=` |
| logical | `&&`, `and`, `\|\|`, `or`, `!`, `not` |
| bitwise | `& \| ^ << >> ~` |
| unary | `-x`, `+x` |

`**` with a negative literal exponent is refused (Ruby would answer a Rational). An integer raised to a power that is not a literal is refused. `<=>`, `===` and `eql?` are refused.

### 6.2 Methods on numbers

| Method | Meaning |
|---|---|
| `abs` | absolute value; a complex gives a real |
| `floor ceil round truncate to_i to_int` | to an integer, as Ruby rounds |
| `to_f` | to a double |
| `real imaginary imag conjugate conj arg angle phase` | the parts of a number |
| `clamp(lo, hi)` | Ruby's `clamp`; the Range form is refused |
| `nan? finite?` | predicates on reals; `finite?` also on complex |
| `sqrt exp log log10 sin cos tan sinh cosh tanh asin acos atan asinh acosh atanh` | written after the number: `x.sqrt` |

None takes an argument except `clamp`; `round(2)` is refused. `infinite?` is refused, with advice. Other methods are refused, among them `zero?`, `positive?`, `negative?`, `div`, `fdiv`, `divmod`, `modulo`, `remainder`, `expm1`, `log1p` and `square`. A block passed to any call is refused.

### 6.3 Conditions

A condition is a comparison, a mask test (§8), `nan?`/`finite?`, a boolean cell or local, or one of these combined with the logical operators. A number is not a condition: there is no truthiness. The operands of `&&`, `||` and `!` must be boolean.

### 6.4 `Math`

`Math.sqrt cbrt exp log log2 log10 sin cos tan asin acos atan atan2 sinh cosh tanh hypot erf erfc gamma asinh acosh atanh`. `atan2` and `hypot` take two arguments; the rest take one. `Math.log(x, base)`, `lgamma`, `frexp` and `ldexp` are refused, as is any other name.

Fifteen of them take a complex argument: `sqrt exp log` and the six trigonometric and six hyperbolic functions. A complex argument to any other is refused.

`Math.gamma` answers a whole number up to 23 exactly, as Ruby does, and raises `Math::DomainError` for a negative whole number and for negative infinity.

### 6.5 Complex numbers

`Complex(x, y)` and `Complex(x)` (which is `Complex(x, 0.0)`). The parts must be real. The result computes as `complex`.

### 6.6 Subscripts of captured arrays

A subscript on each axis is one of:

- an index, `i`;
- an index with a literal offset, `i + c` or `i - c`, where `c` is a non-negative literal (`i + -1` is refused);
- an index with an offset over literals and captures, `i + n`; an index inside the offset is refused;
- a fixed position: a literal, a capture, or `+`, `-` and `*` over them;
- a computed position: anything else, such as `a[b[i]]`.

A subscript must be an integer. An array must be indexed with the same number of subscripts everywhere.

**Bounds:**

- Walked subscripts and fixed positions are checked before the kernel runs. A position out of range is refused; a negative position is refused rather than counted from the end.
- A computed position is checked as it runs. Out of range, a read gives cell 0, a write does nothing, and the kernel raises `IndexError` at the end of the pass.

In `jit_for`, an array that is written may be read through an inner index only if every axis it is written on uses the same outer index.

### 6.7 C functions

A C function is called as `f.call(args)`, `f.(args)` or `f[args]`, with the declared number of arguments. A pointer parameter takes a captured array by name, or a local array; an expression in that position is refused. A local array passed to a sized parameter must match its element type and be at least as long. A captured array passed to a C function must have the declared element type and length and carry no mask.

### 6.8 Random numbers

On a captured `CArray::Rng` `r`: `r.random` (a uniform double), `r.randomn` (a normal double) and `r.bits` (a `uint64`). `random(rng: r)` and `randomn(rng: r)` are the same draws. No other method and no arguments are accepted.

## 7. Types

### 7.1 Computation types

A value computes in one of seven types:

| Type | C | From storage |
|---|---|---|
| `int64` | `int64_t` | int8, int16, int32, int64, uint8, uint16, uint32 |
| `uint64` | `uint64_t` | uint64 |
| `float` | `float` | float32 |
| `double` | `double` | float64 |
| `float_complex` | `float _Complex` | cmplx64 |
| `complex` | `double _Complex` | cmplx128 |
| `boolean` | `int` | boolean |

Any other array type is refused. A cell is widened to its computation type when read and converted back when stored; a boolean cell stores 0 or 1.

### 7.2 How a leaf gets its type

- A literal: §4.
- An index, and an inner loop's bound: `int64`.
- A cell: its array's computation type.
- A capture: §3.
- A pointer read: the declared element type.
- A C call: the declared return type.

### 7.3 Combining two values

The numeric types are ordered `int64 < uint64 < float < double < float_complex < complex`. Two values of the same type give that type. Otherwise the result depends on whether each side is **weak** (a literal or a captured scalar) or **strong** (anything else):

- Both weak, or both strong: the later type in the order.
- One weak and one strong:
  - if the weak side is of a higher kind (integer < real < complex), the result is the weak side's type: `int32_cell * 2.0` is `double`, `f32_cell * 1i` is `complex`;
  - if they are of the same kind, the weak side takes the strong side's width: `f32_cell * 2.0` is `float`;
  - if the weak side is of a lower kind, the result is the strong side's type.

Two cases at the same kind are refused: a negative literal meeting a `uint64`, and a captured Integer above `2**63 - 1` meeting any integer (it has no width of its own to give; wrap it in a `CScalar.uint64`).

This rule applies to arithmetic, `& | ^`, `**` and the two branches of a conditional expression.

- A shift takes the type of its left operand.
- A comparison is `boolean`, and compares in the wider of its operands.
- `-x` and `~x` keep the operand's type.
- `clamp` takes the receiver's type.
- A `Math` function of real arguments is at least `double`. Of a complex argument, it has that argument's complex width.
- `floor`, `ceil`, `round`, `truncate`, `to_i` and `to_int` give `int64`, except that an integer operand keeps its own type. `to_f` gives `double`.
- `real`, `imag` and `arg` of a complex give its real width. `conj` keeps the type. Of a real number, `real` and `conj` keep the type, `imaginary` is `int64` and `arg` is `double`.

A boolean does not combine with a number, so `flag + 1` is refused, and so is a boolean compared with a number.

**Also refused:**

- an ordering comparison or `%` on complex values;
- a conversion, `clamp` or `nan?` on a complex;
- a bitwise operator on non-integers;
- storing a complex into a real array (store `.real`, `.imag` or `.abs`);
- storing a boolean into a numeric array, or a number into a boolean array (the literals 0 and 1 are accepted there).

### 7.4 Locals

A local's type is the type of what was last assigned to it. Assigning a value of another type makes a new local under the same name.

- **After a conditional**, a local can be read only if every branch assigned it, and at the same type.
- **A type change that comes round a loop** is refused: for example, a local that enters a loop as an integer and leaves the body as a float.

## 8. Masks

A kernel carries masks when an array it walks has a mask, or when the block mentions `UNDEF`. A stencil's `border: :mask` does not make it carry masks.

- A value's mask follows the expression. Literals, indices, captures and mask tests contribute no mask. A conditional's mask follows the branch taken.
- A write to a cell sets its mask from the value's mask. Writing a present value clears the cell's mask.
- A write under a branch or a `while` that was decided by a masked value is masked too.
- Locals and the cells of local arrays carry masks the same way.
- `a[...] == UNDEF` and `!= UNDEF` test the mask and are never masked themselves. In `jit_each` and `jit_map`, `a == UNDEF` is the same test on the current cell. Comparing anything else with `UNDEF` is refused.
- Under a masked cell, a division by zero, an index out of range, `clamp`, `gamma` and `raise` report nothing, and a C call standing as a statement is skipped.

**Refused in a kernel that carries masks:** the intrinsics, and passing a local array to a C function. A captured array with a mask may not be passed to a C function; strip the mask first with `strip_mask(fill)`. A function body may not use `UNDEF`.

## 9. Errors at run time

A block that is accepted can still raise when the kernel runs. The kernel finishes its pass and then raises:

| Exception | When |
|---|---|
| `ZeroDivisionError` | integer `/`, integer or float `%` by zero |
| `IndexError` | a computed subscript or a local-array subscript out of range |
| `ArgumentError` | `clamp` with `lo > hi` or a NaN bound; a heap-allocated local array whose extent is below 1 |
| `Math::DomainError` | `Math.gamma` at a negative whole number or negative infinity |
| `FloatDomainError` | rounding NaN or an infinity to an integer |
| `RangeError` | rounding a Float past int64; a negative captured Integer used where a `uint64` is computed |
| `NoMemoryError` | a heap-allocated local array that cannot be allocated |
| `RuntimeError` | `raise "message"` |

## 10. Where the answer differs from Ruby

These are deliberate. Everything not listed here gives Ruby's answer.

- **Overflow wraps.** Integers wrap modulo 2^64, as CArray's do; Ruby would make a Bignum. `INT64_MIN / -1` is `INT64_MIN`.
- **Narrow types compute narrow.** A float32 cell computes as `float`, and a cmplx64 cell as `float _Complex`, as CArray computes them. Ruby would widen to double.
- **An Integer compared with a Float** is compared as two doubles.
- **Outside a function's domain, `Math` answers NaN** rather than raising `Math::DomainError`. The exception is `gamma`. `Math.sqrt(-0.0)` is `-0.0`.
- **A negative real raised to a fractional power** is NaN where the result is read as a real. Stored into a complex cell, or joined with a complex value, it is Ruby's Complex.
- **A complex raised to a power** uses `cpow`, which can differ from Ruby in the last bit.
- **A sine beside a cosine** may be computed together, which can change the last bit.
- **A reduction is reassociated** into partial sums unless `reassociate: false` is given, so its last bits can differ from adding in order.
- **Storing a real out of range into an integer array** is C's conversion, whose result depends on the machine. Storing an integer into a narrower array wraps.
- **`uint64`** follows CArray's wrapping and C's ordering of uint64 over int64.
- **Assigning a captured name** makes a local inside the kernel; the outer variable is not changed.
- **A local first assigned on one branch** cannot be read after the branch, where Ruby would give `nil`.
- **A loop's direction** is the step of its extent, whatever the body reads.
