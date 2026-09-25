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
int64_t x;
int64_t y;
double x__2;
x = INT64_C(5);
y = x >> 1;                /* the integer division Ruby did */
x__2 = 1.5;
```

Reassignment at the same type reuses the variable. A local left with different types on the two arms of a branch does not survive it, and reading it after says so.

A loop is where one forward pass is not enough: the body runs again with what the last pass left behind. So a local that goes round the loop has to be one type, and a body that changes it is refused rather than compiled as whichever type the first pass saw:

```ruby
x = 2
(0...3).each { |j| y = x / 4; x = 1.5 }
#=> `x` enters this loop as an Integer and comes back round as a Float
```

Ruby divides in integers on the first pass and in floats after; no single C variable does that. Writing `x = 2.0` settles it. A local that lives only inside the body may still change type, because it is assigned before it is read on every pass and so nothing crosses the edge.

A local belongs to the scope Ruby gives it, and is declared at the head of the C block that stands for that scope. The kernel's block is one scope and each inner loop's block is another, so two loops side by side may both use `t`, at one type or two. `while` and `if` make no scope: a value assigned inside them is the same variable after them. What is assigned for the first time inside a loop's block is not there after the block -- Ruby reads the name there as a method call -- and what is assigned for the first time inside a `while` is refused if it is read after the loop, since the loop may run no passes and Ruby's value would then be nil. Give either one a value before the loop.

The version before this one settled locals by joining every assignment's type and declaring the variable once. On the example above it printed the right answer -- by dividing in double where Ruby divided in integers, and then truncating 1.5 to 1 on the way back. Two errors that happened to cancel.

### Parallel assignment

`a, b = b, a` is in the subset, and means what Ruby means by it: **every value on the right is settled before anything on the left is written**.

```ruby
# The Fibonacci numbers, by the recurrence that defines them.
out = CArray.int64(12)
CArray.jit_for(12) { |i|
  a = 0
  b = 1
  i.times { |k| a, b = b, a + b }   # `a + b` reads the old `a`
  out[i] = a
}
```

That is the line the spelling exists for. Written out by hand it is three, and the middle one is where the mistake goes:

```ruby
t = a           # forget this and `b` reads the new `a`
a = b
b = t + b
```

The compiler writes that temporary instead, one per value, and the C says so -- this is the inner loop above:

```c
for (int64_t k = INT64_C(0); k < i; k++) {
  int64_t value1;
  int64_t value2;
  value1 = b;
  value2 = a + b;      /* the `a` here is still the old one */
  a = value1;
  b = value2;
}
```

The names are written every time, for the simple ones too. A rule that dropped them where nothing on the right read what the left writes would be a rule a reader of the C had to know before they could tell what a line meant, and a C compiler drops a name assigned once and read once without being asked.

A cell is a target as much as a name is, which is the swap a sort is written with:

```ruby
CArray.jit_for(n / 2) { |i| a[i], a[n - 1 - i] = a[n - 1 - i], a[i] }
```

Each value keeps its own type, as it would on a line of its own -- `counts[i], parts[i] = i * 2, i / 4.0` writes an integer and a double -- and a value carries its mask to the name it is written to, the way an ordinary assignment does. A swap under a branch writes two cells rather than one, which is worth reading about before sorting masked data: see [Masks](#masks).

**One value per name, written out.** Ruby's other readings all rest on taking one value apart, and nothing in a kernel is a value that can be taken apart, so each is refused by name rather than read as the first: `a, b = f(x)` and `a, b = [1, 2]` spread a single value, `a, *rest =` and `= 1, *xs` ask for however many are left over, `a, (b, c) =` unpacks again one level down, and a count that does not match says which way round it did not and what Ruby would have done about it.

And it is a statement, not a value. Ruby's value for it is the array of what it wrote, so a block that ends in one is refused where `jit_map` wanted a number.

### Local arrays

A local variable becomes a C variable; a `CArray` the block makes becomes a C array. It lives on the stack of the block it was written in, its length is whatever the block wrote, and it is reached at a subscript the way a captured array is.

```ruby
# labels: a uint8 classification image (rows x cols), mode: the commonest class per row
CArray.jit_for(rows) { |i|
  counts = CArray.int64(256)
  (0...cols).each { |j| counts[labels[i, j]] += 1 }
  best = 0
  (1...256).each { |c| best = c if counts[c] > counts[best] }
  mode[i] = best
}
```

```c
for (int64_t i = ...) {
  int64_t counts[256];
  memset(counts, 0, sizeof counts);
  ...
}
```

The declaration is hoisted to the head of the block, as a local's is. What stays at the line is the clearing: in Ruby that line makes a fresh array of zeros each time it runs, so every pass of the loop starts from cleared cells, and `memset` is what says the same thing in C.

Three spellings are taken, and they are CArray's own:

| Written | The cells start as | Where it comes from |
|---|---|---|
| `CArray.<type>(n)` | zero | the singleton methods CArray defines for each type |
| `CArray.new(:type, [n])` | zero | `CArray#initialize` |
| `CArray.empty(:type, [n])` | **whatever the stack held** | `CArray.empty`, from carray 3.0.2 |

The types are the ones CArray has, minus the two a kernel computes with neither of: `int8` `int16` `int32` `int64`, `uint8` `uint16` `uint32` `uint64`, `float32` `float64`, `cmplx64` `cmplx128`, `boolean`. `object` and `fixlen` are refused.

The aliases are CArray's too, and two of them are worth reading twice: **`CArray.float` is a float32** and **`CArray.complex` is a cmplx64** -- single precision, the opposite of what Ruby's own `Float` and `Complex` would suggest. `CArray.double` is float64 and `CArray.dcomplex` is cmplx128. `byte`, `short` and `int` are uint8, int16 and int32.

`CArray.empty(data_type, dim)` is carray 3.0.2's spelling. A block is read rather than run, so a kernel takes it whatever version of CArray is loaded -- but calling it outside a kernel needs 3.0.2.

The shape is **written out**: an integer, or integers joined by `+`, `-` and `*`, so `CArray.double(2 * 4 + 1)` is a nine-cell array. A length only the call knows is refused -- there would be no C array to declare and no bound to check against -- and so is a length of zero or less. One axis in this release; `CArray.double(3, 4)` says which release takes more.

**More than one axis** is written the way CArray writes it, and each axis is checked against its own extent:

```ruby
CArray.jit_for(ny, nx) { |i, j|
  m = CArray.double(3, 4)                 # double m[12]; packed row-major
  3.times { |r| 4.times { |c| m[r, c] = coef[i, j, r, c] } }
  ...
}
```

The shape is literal, so the strides are constants the compiler can see: `m[r, c]` becomes `m[(r) * 4 + (c)]`, and a rank above two folds the same way. One subscript per axis, and a count that does not match the axes is refused.

Per-axis checking is the thing this buys, and the reason to write `m[r, c]` rather than flattening by hand. Write `m[r * 4 + c]` yourself and a `c` of 4 is a cell of the next row -- a real read, of the wrong number, saying nothing. Write `m[r, c]` and the column is held to four:

```ruby
m = CArray.double(3, 4)
3.times { |r| 5.times { |c| m[r, c] = 1.0 } }
#=> the subscript `c` on axis 1 of `m`, which is 3 x 4, reaches cell 4 of that
#   axis's 4 cells, whose cells are 0 to 3: `c` runs 0 to 4 here.
```

A column the kernel works out is checked where it is reached, per axis as well, so a write past one axis raises rather than landing in the next row.

The size counts cells rather than axes: `CArray.double(32, 32)` is 8 KiB, past what a frame holds, so it is allocated at the kernel's entry instead (see "Larger, and lengths the kernel works out").

To a C function a local array goes as what it is -- one flat run of cells, row after row -- so a `double[3][4]` is handed to `const double a[12]`, and the length is matched over every cell.

The compatibility layer is not taken. `CArray.zeros(4)`, `CArray.ones(4)`, `CArray.full(4, 1.0)`, `CArray.empty(4)` and the Numo spellings `CArray::Int64.zeros(4)` / `CArray::Int64.empty(4)` are all refused, each naming the carray spelling it stands for. `data_type_extension.rb` opens by calling itself "Numo / NumPy-style" and "not the 'main' carray API"; the words inside a block are carray's own.

**A subscript is checked, and where depends on what it is made of.** Where the position is an inner loop's index at a literal offset and that loop states its range in literals, the reach is known as the block is read, and the C carries no test:

```ruby
t = CArray.double(4)
(0...4).each { |k| t[k + 1] = 0.0 }
#=> `t[k + 1]` reaches cell 4 of a local array of 4 cells, where the cells are
#   0 to 3: `k` runs 0 to 3 here.
```

This looks at the loop's range and not at what stands around the line, which is the character the captured arrays' own check already has: putting the line inside `if k < 3` does not make the reach smaller, because the reach is the loop's. Narrowing the loop's range is what makes it smaller.

Every other position -- a plain local, a value read out of an array, an index whose loop bound is a captured integer -- is checked where the cell is reached. A read outside the array reads cell zero and reports, and the loop leaves at the head of its next pass; a write outside it writes nothing and reports, since a report after the damage would be no use. Either way the call raises `IndexError`.

```ruby
out = CArray.int64(1)

CArray.jit_for(1) { |i|
  w = CArray.double(4)
  j = 0
  while w[j] == 0.0     # reads off the end on the fifth pass
    j += 1
  end
  out[i] = j
}
#=> IndexError: index out of range
```

**A local array is a workspace and not a value.** It has no methods and is not read bare:

```ruby
w = CArray.double(4)
x = w                #=> `w` is a local array; index it, as in `w[0]`
x = w.sum            #=> `sum` is a method CArray answers outside a kernel
```

A constructor stands on the right of an assignment and nowhere else: there is no name for the C array to be declared under otherwise.

`CArray.jit_for`, `jit_each`, `jit_map` and `jit_stencil` take them. The last three are where they are wanted most: a block with no index has no way to pick a row of captured workspace, so before this there was no place to put a window while it was being sorted.

A `jit_function` body takes one too, and hands one on to another function. A contraction takes none -- its body is one expression, so there is no run of statements for a workspace to be used by.

In the whole-array spellings a name the block assigns may be an array where the block was written -- that is what `out = a + b` rests on. A name the block makes an array *under* is refused there: the one line would mean a declaration to this compiler and a write to that array's cell to a reader, and the two are different things. Rename one of them.

**A size decides where the array lives, not whether it is allowed.** One array up to 4 KiB stands in the frame, and one kernel's arrays up to 16 KiB together; past either the array is allocated at the kernel's entry and freed at its exit. Both numbers are provisional -- what a Ruby thread's stack actually is has not been measured -- and what the total does not count is a pasted `jit_function`'s own arrays, recursion, and whatever a future thread pool gives its threads.

What a local array buys over that captured array is the memory. A 3x3 median filter over a 2000x2000 image needs nine doubles at a time; a row of workspace per cell is `work[2000, 2000, 9]`, which is 288 MB to hold 72 bytes in use. And `jit_stencil` cannot use one at all, its block having no index to pick a row by.

#### Larger, and lengths the kernel works out

Two kinds of local array do not stand in the frame: one whose cells come to more than a frame's share, and one whose length the block wrote as an expression over the integers it captured. Both are **allocated once at the kernel's entry and freed at its exit** -- outside the cell loop, so a constructor written inside the loop is still one allocation.

```ruby
# n is an Integer the block closed over; 4096 doubles is 32 KiB
CArray.jit_for(rows) { |i|
  w = CArray.double(n)          # allocated at the entry, freed at the exit
  big = CArray.double(4096)     # the same, for its size alone
  ...
}
```

Nothing changes in how a cell is reached, and nothing changes for an array that does fit: a kernel whose arrays all stand in the frame emits what it emitted before.

Three things follow from a length the kernel works out.

**Every subscript on such an axis is checked where the cell is reached.** The check that reads a loop's range has no number to compare it against -- and neither has a position written as a number, since 3 is inside an array of 4 cells and outside one of 2. Measured at 0.14 ns a cell against the same array at a length written out, which is what the check costs; the allocation itself did not rise above the noise of one call.

**The same block at two lengths is one kernel.** The length travels as an argument rather than standing in the C, so `n = 100` and `n = 200` share the compiled object and the second call compiles nothing.

**A C function takes it only where the declaration names no length.** `const double *v` promises nothing about how many cells there are and takes one; `const double v[3]` is matched against the shape as the block is read, and a length that is not there yet cannot be matched -- so that declaration is refused, naming the pointer form as the spelling to use.

A length the kernel works out has to be a length: an extent that comes to zero or less is reported as `ArgumentError` when the kernel runs, naming the array and what its shape came to, and one whose bytes could not be counted in a `size_t` is reported the same way rather than multiplied out. An allocation the system refuses is `NoMemoryError`, with the shapes and the bytes asked for. The shape may read only the integers the block captured: a loop index, a cell of an array or a local worked out inside the block would be a length that changed from cell to cell, and the array is one allocation made before the first cell.

A `jit_function` body allocates nothing. It is called once per cell, so an allocation in it would be one per cell; a body that wants a larger workspace, or one sized when the kernel runs, takes it as a pointer parameter from the kernel that calls it.

#### Masks in a local array

A kernel that carries masks gives every local array a **shadow** of one byte a cell, declared beside the cells, and a cell of the array carries a mask the way a plain local carries one beside its value: what the expression written into it carried, and the masks of the branches the write stands in. So a window copied into a workspace keeps its holes, and reading a cell back is reading what it was made of.

```ruby
field = CArray.double(8).seq!(1.0)
field[2] = UNDEF
out = CArray.double(8)

CArray.jit_for(1...7) { |i|
  w = CArray.double(3)
  w[0] = field[i-1]; w[1] = field[i]; w[2] = field[i+1]
  out[i] = w[0] + w[1] + w[2]
}
#=> out[1], out[2] and out[3] are UNDEF; they are the cells that read field[2]
```

A cell can be marked and asked about, as a captured array's can:

```ruby
w[k] = UNDEF
w[k] == UNDEF
w[k] != UNDEF
```

The zeroed spellings clear the shadow with the cells, so a cell starts every pass present rather than holding what the pass before left there. `CArray.empty` says nothing about either: its cells and its shadow are both whatever the stack held, which is the bargain that spelling makes.

Two things a local array does not do under masks. **The intrinsics refuse it**: what `sum`, `min`, `max` or `sort` should do with a missing cell is not decided -- pass over it, gather it at the end as `sort` gathers NaN, or count it where a median counts -- so the refusal says that rather than choosing. And **a C function cannot take one**: a signature says what a pointer points at, and a mask travels in no C declaration there is a way to write. Either way the answer is to decide it in the kernel, or to copy the cells the callee should see into a captured array.

The shadow counts towards where the array goes, being on the same stack: an array of 512 doubles is 4 KiB of cells and stands in the frame, and 4.5 KiB once it carries masks, which is past a frame's share -- so under masks that array is allocated at the entry, its shadow with it.

`border: :mask` does **not** make a masked kernel -- the frame is marked before the loop runs and never reached by it -- so a stencil with that border pays for no shadow. Nor does a compiled function's body ever carry one: a function is handed numbers and pointers, and a mask travels in neither, so `w[k] = UNDEF` in a body is refused.

### Intrinsics

Four functions the compiler brings with it, over a local array:

```ruby
s = sum(w)          # the value
a = min(w)
b = max(w)
sort(w)             # a statement: it rearranges `w` and has no value
```

They are written as bare calls, the way `random(rng: r)` is, and not as methods on the array. `w.sum` is refused, and that is the point: writing `w.sum` would promise CArray's `sum` -- an `axis:` keyword, masked cells skipped, an identity for an empty array, a CScalar or a number back, one type promoted to another -- and every one of those would then have to be honoured or explained. A bare name is this compiler's own, so what it means is settled here.

The name does not collide with anything the block writes. `sum = 0.0` beside `sum(w)` is a local and reads as one, because a bare name with no arguments is a capture; `sum.call(x)` is a call to whatever `sum` holds, because a name with a receiver is. Only the receiverless call with arguments is the intrinsic.

**What they take.** One local array, of one axis, named on its own -- a local array may have more than one axis, but these four do not take one: a row-major sweep would read well enough for `sum`, `sort` over one has no obvious meaning, and the four keep a single rule. Walk the axes yourself, or copy the cells you want into an array of one axis. A captured array is refused, and the message says why: walking all of it at every cell is a pass over the whole array per cell, which is not what the line looks like it costs. Reducing a whole array is `CArray#sum` outside the kernel. A scalar, an expression and two arguments are all refused -- for the minimum of two numbers write `x < y ? x : y`, and to hold a value between bounds write `x.clamp(lo, hi)`.

**`sum`** accumulates in the element's computation type, in index order from the first cell: an int32 array sums in `int64_t`, a float32 array in `float`. It is the same loop written out, in the same order, so the last bit is the same one -- no partial sums, unlike a reduction over a captured array, because a local array is small enough that splitting buys nothing and would change the answer. An integer sum wraps where the width wraps. A boolean array is refused: CArray reads the sum of one as a count, and counting is a meaning this would be borrowing rather than deciding. Count into an integer array and sum that.

**`min` and `max`** answer what CArray's own `min` and `max` answer. A NaN never displaces the accumulator, so it is skipped wherever it stands -- first, middle or last:

```ruby
CArray.double(3) { [Float::NAN, 1.0, 2.0] }.min   #=> 1.0
```

and an array of nothing but NaN comes back `NaN`, there being no number left to win, which is again CArray's answer. Of two cells that compare equal the first is kept, so `0.0` and `-0.0` come back in whichever order they stood, as they do from CArray -- which is why the fold is a comparison rather than C99 `fmin` / `fmax`, whose NaN rule is the same but which leave the choice between two zeros to the library. Over an integer array, which has no NaN, it is a comparison against the limit of the type. `sort` does not skip a NaN, for the reason the fold does: skipping drops a cell -- right for a fold, wrong for a sort. A Complex array is refused, Ruby not ordering Complex numbers either, and so is a boolean one.

**`sort`** puts the cells in ascending order where they stand. It is a statement and never a value; writing `x = sort(w)` is refused, and so is `sort(w)` in the middle of an expression. Every NaN ends up after every number, which is where CArray's own sort puts them. The relative order of `-0.0` and `0.0` is not promised -- the comparison is `<`, which reads them as equal -- and that is the one place this compiler compares floats by value rather than bit for bit; CArray's sort takes the same licence.

Which algorithm is emitted is decided by the length, which the block wrote:

| Cells | What is emitted |
|---|---|
| 1 | nothing: one cell is in order |
| 2 to 16 | a **comparator network** -- a fixed sequence of compare-exchanges, the smallest number known for that length (25 at nine cells, 60 at sixteen) |
| 17 and up | an **insertion sort**, which is a loop |

A network has no branch in it at all. At nine cells, the helper compiles to 50 `fcsel` instructions and zero branches on arm64, which is why it costs the same whatever the data is: measured over 100,000 rows of nine shuffled doubles it sorts a row in 42 ns against the insertion sort's 70, and at sixteen cells 55 ns against 159. The insertion sort is adaptive and wins on data that is already in order -- 7 ns at nine cells -- which is the case a sort is not usually reached for.

All four are emitted as `static inline` helpers in the preamble, one per element type and, for a network, per length; the body carries the call. So `max(w) - min(w)` is one line with two calls in it, `c_source` stays readable, and the compiler has the length as a literal to propagate.

They are written wherever a local array is: `CArray.jit_for`, `jit_each`, `jit_map`, `jit_stencil`, and a `jit_function` body. The one place they are refused is over an array of a kernel that carries masks, where what to do with a missing cell is not decided (see [Masks in a local array](#masks-in-a-local-array)). `qsort` is not used anywhere -- its comparison goes through a function pointer, which ends inlining and makes the NaN rule a property of whoever wrote the callback.

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

A branch with no `else` writes nothing on the path not taken, so the cell keeps both its value and its mask -- as the same `if` would in Ruby. What that costs is a conclusion drawn from *not* taking it: `found = -1; if a[i, j] > x then found = j end` leaves `found` at -1 for a row whose only candidate was masked, and reports "no match here" as a value like any other, since nothing was written to carry the mask. Where the difference between "no match" and "nothing to compare" matters, ask about the mask yourself -- `if a[i, j] == UNDEF`, which is a question about the cell rather than about its bytes. As an *expression*, `if` still needs an `else`, because there every cell needs a value.

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

Ruby's Complex arithmetic is not C's, in ways that show up in the last bit, in the sign of a zero, and where an infinity meets a zero, so three of the four operators are compiled to match Ruby rather than to C's operator:

- A Complex **added to** a real number keeps its imaginary part exactly as it was, rather than having a zero added to it: Ruby's own `f_add` returns the other operand as it stands when one of them is the exact Integer zero a real operand carries. `Complex(1.0, -0.0) + 2.0` is `3.0-0.0i`; widening the `2.0` to a complex first would make it `3.0+0.0i`.
- `z * x` **scales each part**, while `x * z` coerces and multiplies out in full -- so Ruby's two answers differ from each other, and each is reproduced its own way. A full product, `x * z` or two Complex numbers, is Ruby's part by part: a zero meeting an infinity gives a zero, so `0.0 * Complex(Float::INFINITY, 0.0)` is `0.0+0.0i`, where C's own complex `*` answers `NaN`s.
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
source = CArray.double(7).seq!(1.0)
source[2] = UNDEF
result = CArray.double(7)

CArray.jit_for(1...6) { |i| result[i] = source[i-1] + source[i+1] }
#=> result[1] and result[3] are UNDEF; they are the cells that read source[2]
```

Masking follows the offsets, and each output takes its mask from its own inputs rather than from everything the body read.

The mask of a value is built the same shape as the value. A flat union of everything an expression touches would be wrong for a conditional: `a[i] == UNDEF ? 0.0 : a[i]` does not read `a[i]` when the condition holds, and Ruby's answer there is not missing. So the conditional's mask is conditional too, and a block-local carries a mask alongside its value -- as does every cell of a local array, which under masks is declared with a shadow of one byte a cell beside it (see [Masks in a local array](#masks-in-a-local-array)).

The value under a masked cell is **out of contract**: a kernel may compute anything into it, so long as the mask ends up right (`guides/devel/05`). That is what lets the loop stay branchless -- every cell is computed and only the mask is reconciled, instead of a test per cell to protect data that was never protected.

One thing cannot simply be computed and discarded: an integer division by a zero that sits under a masked cell. CArray's own kernels skip masked cells and so never reach their divide-by-zero check; a branchless kernel divides anyway, so the report is gated on the mask.

Where a kernel leaves the masking implicit, the reference is CArray's operators rather than a Ruby loop: `source[i]` hands Ruby an `UNDEF`, and `UNDEF * 2.0` does not run. A kernel that says `== UNDEF` outright is a Ruby loop again, and is checked as one.

**A compare-exchange spreads a mask further than anything else does.** A branch decided by a missing cell masks what it writes, which is the rule everywhere; a swap writes two cells rather than one, and a sort runs compare-exchange over every cell again and again. So one missing cell does not stay one:

```ruby
row = CA_DOUBLE([[5, 1, 4, 2, 3]])
row[0, 2] = UNDEF

CArray.jit_for(1) { |i|                       # a bubble sort over the row
  4.times { |p|
    (0...4).each { |j|
      if row[i, j] > row[i, j + 1]
        row[i, j], row[i, j + 1] = row[i, j + 1], row[i, j]
      end
    }
  }
}
row.to_a                            #=> [[1.0, UNDEF, UNDEF, UNDEF, UNDEF]]
```

Nothing here is wrong: every comparison that read the missing cell was decided by bytes that mean nothing, so both cells it exchanged are marked, and the next pass compares those. It is the ordinary rule with an unusually high gain.

This is the question `sum`, `min`, `max` and `sort` refuse to answer for a local array -- pass over a missing cell, gather it at the end, or count it where a median counts -- except that a sort written by hand is not refused. It runs, and answers a row of `UNDEF`. Decide it before the comparison, with `if row[i, j] == UNDEF`, which asks about the cell rather than about its bytes.

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

#### A captured Integer takes the width its value asks for

A captured Integer has no data type to read a width off, so the value decides: `int64` while it fits one, `uint64` above that, and a value neither holds is refused where the capture is read rather than packed into a slot that cannot hold it.

```ruby
big = 2**64 - 1
out = CArray.uint64(1)

CArray.jit_for(1) { |i| out[i] = big / 3 }
out[0]                                      #=> 6148914691236517205, Ruby's quotient
```

This is the one thing about a capture that its *value* settles rather than its class, and it is sound because the value's width is part of the kernel's cache key: the same block with `5` and with `2**63 + 5` is two kernels, compiled and cached apart. What travels is unchanged -- the kernel's three buffers are what they were, and a `uint64` rides in the integers one as the eight bytes it is, packed as its own bits and cast back on the way in.

What it may not do is meet an integer. A bare Ruby Numeric is absorbed -- it takes the other operand's dtype rather than widening it, which is what keeps `f32 * 2.0` a float32 -- and there is no width to hand this one, since the value came from none. CArray refuses the same expression, and refuses it whatever the array's own type is:

```ruby
u = CArray.uint64(1) { 5 }

u + (2**63 + 5)         #=> RangeError: bignum too big to convert into 'long long'
u + CScalar.uint64() { 2**63 + 5 }
                        #=> [9223372036854775818], the width said once
```

So a kernel refuses it too, and names the same way through -- `CScalar.uint64() { big }`, which a kernel reads as the one-cell array it is. A Float or a Complex on the other side is a different question: there the wider kind wins rather than a width being handed over, and the value reaches a double as it does in Ruby and in CArray.

An accumulator is that refusal reached from the other side. `total = 0` is an Integer, and by the second pass it carries a width for the capture to meet, so the loop is refused and a `CScalar` is what states both: one for the seed, as [Giving an accumulator the type](#giving-an-accumulator-the-type) has it, and one for the value.

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

`Math.erf` and `Math.erfc` are lowered like the rest -- Ruby calls those very functions, so the two agree to the bit.

`Math.gamma` is lowered too, but not to `tgamma`: Ruby's answer is tgamma with two things around it, and both are reproduced. A whole number up to 23 is answered from the table of exact values Ruby answers it from -- written into the generated C, filled from the Ruby that compiled it, the way `Math::PI` is emitted as the double Ruby would have used -- and a negative whole number, or negative infinity, raises `Math::DomainError` with Ruby's own words where `tgamma` would answer with a NaN. A cell with no value in it does not raise, as everywhere else.

The rest of `Math` answers outside its domain the way `math.h` does, with a `NaN`, where Ruby raises `Math::DomainError`: `Math.sqrt(-1.0)`, `Math.log(-1.0)`, `log2` and `log10` of a negative number, `asin` and `acos` past `±1`, `acosh` below 1, `atanh` past `±1`. `Math.sqrt(-0.0)` is `-0.0`, where Ruby answers `0.0`. `Math.gamma` is the exception because its helper was there anyway, for the table; the others are single instructions or close to it, and a check on every call keeps a loop of them from being vectorized -- a loop of `Math.sqrt` ran 2.6 times slower with one. Where an argument may leave the domain, test it in the block first: `raise "x is negative" if x < 0.0`, then `Math.sqrt(x)`.

What is left of Ruby's `Math` is three names, and each says why rather than claiming C has no such function, which it does in every case: `lgamma` and `frexp` each answer with a *pair*, and a cell holds one number; and `ldexp`'s second argument is an exponent rather than a number, where a math call here computes every argument in the type of its result.

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

The spelling is `.call`, the one every C function takes here, borrowed or written: it is how a block calls a Proc, so a name that holds a function reads as one, and a recursion reads the same as a call to anything else. A bare `fact(n - 1.0)` reads better as C and is refused all the same, with that message -- bare names that look like calls are the compiler's own (`sum(w)`, `sort(w)`, see [Intrinsics](#intrinsics)), and a function of yours is reached through the name that holds it. `fact` in the block is a spelling, not a symbol: the compiled call goes to `carray_jit_fact_<digest>`, so it cannot reach anything else in the process that answers to `fact`. An anonymous declaration gets no recursion, having nothing to call itself by, which is C's position on a function pointer type too.

A pointer parameter may be handed on -- `total.call(n - 1, v)` passes the address the function was given, as C does -- so a recursion can walk an array. What it cannot do is stop itself running out of stack: a compiled function that recurses too deep is a SIGSEGV, not a `SystemStackError`. That is C's bargain, taken along with `void *params`.

#### A workspace of the body's own

A function body may make an array of its own, and use the intrinsics over it, exactly as a kernel may (see [Local arrays](#local-arrays) and [Intrinsics](#intrinsics)). This is the one place where there is no alternative: a body closes over nothing, so an extra parameter is the only other way to give it scratch space -- and a signature settled somewhere else, a callback's, has no room for one.

Neville's interpolation is the shape that wants it. It walks a workspace of the sample count, overwriting it as it narrows:

```ruby
NEVILLE = CArray.jit_function(
  "double neville(double x, const double xs[4], const double ys[4])"
) { |x, xs, ys|
  t = CArray.double(4)
  4.times { |k| t[k] = ys[k] }
  (1...4).each { |m|
    (0...4-m).each { |k|
      t[k] = ((x - xs[k+m]) * t[k] + (xs[k] - x) * t[k+1]) / (xs[k] - xs[k+m])
    }
  }
  t[0]
}
```

`ys` is `const` and cannot be walked over, which is what the workspace is for. The array is declared at the head of the function, and a recursive body gets one per call, as C gives an automatic.

A body hands an array of its own to another compiled function under the same rules a kernel does -- the element type exactly, and at least as many cells as a sized declarator asks for, both matched as the block is read -- and reads back what a non-`const` parameter was written with. A pointer the body was *given* is passed along as C passes one, unchanged from before.

The helpers an intrinsic needs travel with the body. A function compiled on its own carries them in its own file; one pasted into a kernel puts them in the kernel's preamble, where one helper serves every body and the kernel itself that wants the same element type and length.

#### Dividing by zero

`6 % 0` raises in Ruby, and the kernel raises it too: it is handed a place to report through, and reports. A compiled function has no such place -- it has the signature its declaration gave it and nothing else, which is the point of it. So the object carries one of its own: a single exported `int32_t` that a division with no divisor and a `raise` in the body both write into, declared only when the body can actually reach it.

```ruby
r = CArray.jit_function("int r(int a, int b)") { |a, b| a % b }
r.call(7, 3)       # => 1
r.call(7, 0)       # => ZeroDivisionError: divided by 0, as r.block would
```

Nothing in the generated C reaches Ruby to do that. The function returns a number and touches no Ruby value, so its address is still safe to hand to a library or to call off the GVL; `CFunction#call` is what looks at the flag afterwards and raises. A caller coming from C sees what C arranges for a function that has to return something regardless -- a stand-in, and the flag standing beside it. Which one of those is the answer is the [next section](#lending-the-address).

#### Handing over an array the body made

A local array (see [Local arrays](#local-arrays)) goes to a pointer parameter, which is what makes one worth having beside a function: the workspace is on the block's stack and the callee is handed its address, as C hands one over.

```ruby
DOT4 = CArray.jit_function("double dot4(const double x[4], const double y[4])") { |x, y|
  x[0]*y[0] + x[1]*y[1] + x[2]*y[2] + x[3]*y[3]
}

CArray.jit_for(0...(n - 3)) { |i|
  w = CArray.double(4)
  w[0] = signal[i]; w[1] = signal[i+1]; w[2] = signal[i+2]; w[3] = signal[i+3]
  smoothed[i] = DOT4.call(w, weights)
}
```

**What the declaration says is matched as the block is read**, not at the call. Both halves are written in the block -- the element type is the constructor and the length is a literal -- so `CArray.float32(4)` against `const double x[4]`, or `CArray.double(3)` against it, is refused before anything is compiled. A captured array is matched at the call instead (there is no array to look at until then), and the rules are the same ones: the element type exactly, and at least as many cells as a sized declarator asks for. More cells than it asks for is fine, as it is for a captured array -- the callee reads the four it was promised.

The length check is doing real work here rather than tidying up. A subscript on a pointer parameter is unchecked by design, and a local array is on the stack: a declaration that read more cells than the array holds would walk over the frame the return address is in.

A parameter that is not `const` may be written through, and the line after the call reads what the callee left:

```ruby
SOLVE3 = CArray.jit_function("void solve3(const double a[12], double x[3])") { |a, x| ... }

CArray.jit_for(ny, nx) { |i, j|
  rhs = CArray.double(12)
  sol = CArray.double(3)
  ...
  SOLVE3.call(rhs, sol)
  out[i, j] = sol[0]
}
```

The zeroed constructors clear at the line as they always do, so what a callee wrote into `sol` is gone by the next cell rather than carried into it.

Passing the same local array to two parameters -- `DOT4.call(w, w)` -- is well-formed, the declarations carrying no `restrict`.

#### An array handed over whole is not an operand

In `jit_each`, `jit_map` and `jit_stencil` the block names no index, so a bare array name is the cell the loop is on and every operand has to line up with every other. An array handed to a C function is not one of those: it goes over whole, so its own length is nobody else's business.

```ruby
weights = CArray.double(4).seq        # four coefficients
a       = CArray.double(1000).seq     # a thousand cells to compute

CArray.jit_each { out = a + DOT4.call(weights, weights) }
```

The weights are four cells against a thousand, and that is fine: they are handed over, not walked. What decides it is the declaration rather than the spelling -- a parameter that takes a number by value reads the cell, so `twice.call(a)` against `double twice(double x)` walks `a` a cell at a time and lines up like any operand. An array used *both* ways -- read by cell and handed over -- is an operand, and lines up.

A block whose only array is handed over has nothing to say how many cells there are to compute, and says so:

```ruby
CArray.jit_map { DOT4.call(weights, weights) }
#=> the block reaches no array to walk: `weights` is handed to a C function
#   whole rather than read by cell, so it does not say how many cells there
#   are to compute. `CArray.jit_for` with a count says that, and so does an
#   operand the block reads a cell of
```

`jit_for` says how many cells there are itself, so it never needed an operand for that.

#### Lending the address

`#call` is one call and answers for it. A library given `#pointer` calls whenever it likes, as often as it likes, and what wants an answer is the whole of that -- so the window is what the flag is put down for, and what it is read for:

```ruby
f.watching do
  Integration.qags(f.pointer, 0.0, 1.0)
end
```

That is the arrangement a kernel already keeps with its own slot: cleared once before a sweep, read once after it, never per cell. `#clear_error` and `#report_error` are the two halves on their own, for a window that is not a block -- one opened in one method and closed in another, or one whose block belongs to somebody else. Asking does not put the flag down; the window that put it down is what picks it up.

Once the flag stands, the body does no more work. It is asked again -- the library has no idea anything went wrong, and nothing has told it to stop -- and it returns the stand-in without running. **The stand-in is not the answer. The flag says so.** A body that returns nothing has no stand-in to offer and leaves its out-parameters alone, which is the same refusal.

This matters more than it sounds. Without it a body would report its failure once and then answer normally, and an adaptive routine would do what adaptive routines do: see one bad point, subdivide around it, find every subdivision well behaved, and converge. The number that comes back is not wrong in a way anybody can see. It is worse than a wrong answer, because it looks like a right one.

A failure inside the window outranks whatever the library made of it. The body returned a stand-in, so the library is usually the first to complain -- that the endpoints do not straddle, that the iteration did not converge -- and those complaints are consequences rather than what happened, so `#watching` reads the flag before letting the exception through. Where nothing stands, the library's own story is the story.

A window may be opened inside a window, and `#call` may be made inside one: both borrow the flag and put it back as they found it, so an inner window answers for its own block and no other, and a call answers for itself without disarming whoever is watching. A kernel run inside a window is untouched either way -- a kernel is handed its own slot, and never reaches this flag at all.

One flag per compiled object, so two functions never share a window. Threads do share one, though: the flag is a single `int32_t` beside the body, so lending the same function to two threads at once is not a window that can be made to mean anything. That is C's bargain again, taken along with `void *params`.

#### Telling the holder to stop

The stand-in keeps a library from converging on fiction, but it does not stop the library: an optimizer given a large `maxeval` goes on calling to the end, each call turned away at the top. `#on_error` gives the body a C function to call when it fails, so that whoever holds the address can be told:

```ruby
nlopt = Fiddle::Handle.new("libnlopt.dylib")
f.on_error(nlopt["nlopt_force_stop"], opt)   # void nlopt_force_stop(nlopt_opt)
f.watching { nlopt_optimize.call(opt, x, minf) }
```

The hook is any `void (*)(void *)` -- an address as a `Fiddle::Pointer` or an Integer -- and the second argument is the one pointer it is called with. It is called once, by the call whose body put the flag up; every call after that is turned away before the body runs, so it is not called again until the flag has been put down and gone up again. It runs in C and reaches no Ruby value, as the body does not. `on_error(nil)` takes it away.

`#call` does not call it. That is one call made from Ruby, and it answers for itself by raising, as it does inside a window. A body that cannot fail has no flag to go up and is compiled without the hook; `on_error` is accepted there and never called, so a library binding can set it without asking which kind of body it was given. The hook belongs to the compiled object, like the flag.

A float division is not this case: `1.0 / 0.0` is an infinity in Ruby, in C and here, so a body that only divides floats declares no flag and pays nothing for one. Neither is a subscript on a pointer parameter, which is unchecked by design -- the caller's business, as it is in C. The one exception needs nothing to run: a literal subscript outside a length the declaration gave -- `v[7]` or `v[-1]` against `double v[2]` -- is refused as the body is read, since the caller is held to that many cells and no more.

A complex is a type a declaration may be written in: `double _Complex`, `float _Complex`, and `<complex.h>`'s `double complex` for either of them, by value or as a pointer (`double _Complex v[]` takes a `cmplx128` array, as `double v[]` takes a `float64` one). A kernel calls such a function the way C calls it. A call from Ruby cannot go straight through Fiddle -- it has no type to carry a complex by value in -- so a function compiled here gets a second entry point beside it, taking each complex argument as the two doubles C99 lays one out as and writing a complex result back the same way. It calls the body rather than repeating it, so `f.call` and `f.block.call` are the same body run two ways, as they are for every other signature. A *borrowed* function declared with one has no such entry point, there being no source here to compile beside it: a kernel calls it, and `f.call` from Ruby says why it cannot.

The declaration stays C rather than becoming a vocabulary of this compiler's own, because what is being declared is a C function and the types it has to meet belong to whatever will call it. `void *params` is the point of the exercise, not an edge of it. C's spellings come with C's own asymmetry: the integer types have exact-width names, so `uint16_t` and `int32_t` read, while the floating types are `float` and `double` and there is no `float64_t`. The names that stand for whatever the platform made them -- `size_t` and its kin -- read too, and have [their own section](#the-widths-a-declaration-may-name) below.

The return type is stated rather than derived from the body, although it could be derived. The reason is the one already given for writing a loop's direction at the call site: a signature is what something outside agrees to, and editing the body must not silently change it.

The block survives on the function, and where its body stays inside what Ruby computes the same way -- no width that wraps where an Integer would grow, no intrinsic such as `sort(w)` that Ruby has no definition for -- the two can be put side by side, which is handy while writing one:

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

#### The widths a declaration may name

`uint16_t` is a width. `size_t` is not: it is whatever the platform's unsigned word turned out to be, and a declaration that uses it says so without saying which. So nothing here maps the spelling to a type. Fiddle is asked what the word is on the machine the function is being compiled on, and the answer is read through the same table that decides `uint64_t` -- on an LP64 machine `size_t` lands on `uint64`, on Windows x64 it lands there by the other code, and where the word is 32 bits it lands on `uint32`. The signed ones -- `ssize_t`, `ptrdiff_t`, `intptr_t` -- are an `int64` the same way, and `uintptr_t` joins `size_t`.

The generated C keeps the spelling it was given, so the C compiler gives it its width there. The two agree because they are the same platform's answer to the same question, and a compiled object is cached under the platform it was built for.

A parameter may be one, which is the point of reading them: a body that counts bytes or elements is declared the way C declares it rather than in a translation of it.

The platform's own integer words read the same way, in whatever order C allows them: `unsigned` is `unsigned int`, `long unsigned int` is `unsigned long`, and `int` may be left out wherever C lets it be. That is how headers are written -- NLopt's objective is `double (*)(unsigned n, const double *x, double *grad, void *f_data)` -- and a declaration copied out of one reads as it stands. A combination C has no type for, such as `short long` or `signed unsigned`, is refused by name.

```ruby
stride = CArray.jit_function("size_t stride(size_t n, size_t width)") { |n, w|
  n * w
}

stride.call(6, 8)         # => 48
```

Which is what makes the ordinary C signature sayable -- a pointer and a length, counted the way C counts:

```ruby
fill = CArray.jit_function("void fill(double out[], size_t n)") { |out, n|
  (0...n).each { |i| out[i] = i * 2.0 }
}
```

That is wider than what a *captured* scalar may be. A kernel's captures travel in the buffers its signature has -- doubles, integers, complexes -- and a `uint64` fits none of them whole; a compiled function's parameters are not carried in a buffer at all, they *are* its signature, so a value of any type the body can compute in may be handed to one. Above 2^63 it arrives whole:

```ruby
half = CArray.jit_function("size_t half(size_t a, size_t b)") { |a, b| a / b }

half.call(2**64 - 1, 3)   # => 6148914691236517205, the unsigned quotient
```

Where the arithmetic leaves the width it wraps, as CArray's own `uint64` operators wrap and as C does -- so the body agrees with the array type it was written for rather than with `Integer`, which would have grown instead. `stride.block.call` is the one place the two part company, and `(2**63 + 5) * 2` is the smallest way to see it.

A pointer to one takes the array of that width: `size_t counts[]` wants a `uint64` CArray where the word is 64 bits and a `uint32` one where it is not. That is `size_t`'s own bargain rather than this compiler's -- the declaration is portable and the array it asks for is not the same array everywhere -- so where a program means the width and not the word, `uint64_t` says the width.

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

A body reaches outside its parameter list in two places only -- this one, and a function borrowed with `jit_extern` -- and the next section says why neither is really an exception.

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

A compiled function may not reach anything outside its parameter list -- not a number, not an array. A captured number could be written into the C as a literal, but that would put something in the compiled object that no cache key covers, and an object built for one capture would be handed back for another.

A function compiled here is the first of the two, and stays inside the rule that produced the restriction: what goes into the caller is the callee's body and the symbol standing over it, and that symbol -- which carries the digest of the body -- goes into the key. So two blocks spelled the same that call different functions are two functions, which is the whole of what the key had to settle.

A function borrowed with `jit_extern` is reached by the other route, and it is the name rather than the address. An address is all a borrowed function has for a kernel, and there is nowhere in a compiled object to keep one -- but a name is what the declaration states and what a linker or a loader resolves, and `jit_extern` opened the library to find the function, so the symbol is in the process by the time the body is compiled. The generated file declares it, `double j0(double);`, and calls it by that name, which the key already covers as one of the symbols the body calls. A kernel is unchanged: it takes the address through its buffer, which is what a kernel has and a body has not. A file built ahead of the program links the library the usual way, and one that is not linked by default is the caller's to add.

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

#### Asking whether an address came

Some callers decide per call whether a pointer is there at all. NLopt hands an objective a gradient to fill when the method uses one and `NULL` when it does not, so a body that writes `grad[0]` unconditionally writes through `NULL` under a derivative-free method. The body asks first, in the spellings Ruby answers the same way for `nil`:

```ruby
objective = CArray.jit_function(
  "double (*)(uint32_t n, const double *x, double *grad, void *data)"
) { |n, x, grad, data|
  if grad                       # grad.nil?, grad == nil and grad != nil read too
    grad[0] = 2.0 * x[0]
  end
  x[0] * x[0]
}

objective.call(1, x, nil, nil)    # nil arrives as NULL
```

A bare pointer name is read as the question only where a condition is read -- `if`, `while`, `?:`, and `!`, `&&` and `||` inside one -- because that is where Ruby's truthiness is the question. Anywhere else a pointer is still not a value, and `g = grad` is refused as before. A `void *` may be asked too: whether a slot was filled is a question about the slot, not a reach through it. `f.block.call` takes `nil` in the same place and runs the same branch.

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

#### Compiling a body where it is called

`jit_function` hands back a function and the caller writes out the arguments. `CArray.jit_call` does both at once, at the site:

```ruby
def moving_average (values, window)
  n = values.elements
  out = CArray.double(n)
  CArray.jit_call("void (*)(double *out, const double *values, " \
                  "size_t n, size_t window)") {
    n.times { |i|
      total = 0.0
      window.times { |k| total = total + values[i - k < 0 ? 0 : i - k] }
      out[i] = total / window
    }
  }
  out
end
```

The declaration's parameter names are the join, and they do the work twice over: they are the body's parameters, so the block declares none, and they name the locals around the call the values come from -- `out`, `values`, `n` and `window` are read out of the method at the moment the call is made. In C a parameter's name in a prototype is decoration; here it is the whole binding. A declared name with no local behind it is refused at the call, by name, rather than read as a `nil` inside the body, and a declaration that leaves a parameter unnamed is refused for the same reason: there is nothing to bind by.

What this saves over `jit_function` and a `call` is the argument list, which restates the declaration in an order nothing checks. What it costs is reading those locals through the block's binding, about 0.3 microseconds against a call that costs several -- so the body it suits is one that does a loop's worth of work per call, which is what a `void` function over whole arrays already is.

What is inside the block is what `jit_function` compiles, under the same rules: the same subset, the same local arrays, the same error slot, and the same refusal for a name it closes over that the declaration did not name. What differs is where the compiled function is kept. It is kept per call site rather than per block -- a block literal is a fresh Proc every time the line runs, but the instruction sequence behind it belongs to the site -- so the second pass through the method is a lookup, and `CArray::JIT.clear_registry` reaches these as it reaches the rest.

A site may also be answered by a function somebody else compiled, in which case nothing here is asked to compile anything; see [A site answered from somewhere else](04_Compiling.md#a-site-answered-from-somewhere-else).

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
- `a[i] == UNDEF` and `a[i] != UNDEF`, either way round; `a[i] = UNDEF`. A cell of a local array is asked and marked the same way, `w[k] == UNDEF` and `w[k] = UNDEF`, where the kernel carries masks -- which gives every local array a shadow of one byte a cell (see [Masks in a local array](#masks-in-a-local-array))
- `Math.sqrt`, `cbrt`, `exp`, `log`, `log2`, `log10`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `hypot`, `asinh`, `acosh`, `atanh`
- the postfix spelling of those -- `x.sqrt`, `(0.0415 * (t[i] - 218.8)).tanh` -- which `CArray::CoreExtensions` provides (see [Postfix math](#postfix-math))
- `a[i - c]` and `a[i + c]`, with `c` a non-negative integer literal or an integer built from literals and captured integers, one subscript per axis of the array; a constant subscript pins an axis, and a computed one gathers or scatters
- `x.nan?` and `x.finite?`, C's `isnan` and `isfinite`, answering true or false as Ruby's do. `nan?` is a Float's: an Integer and a Complex have no method by that name and raise `NoMethodError` in Ruby, so both are refused. `finite?` answers for all three, a Complex's being both parts finite as Ruby asks it. `infinite?` is **not** here -- it answers nil, 1 or -1 rather than true or false, and a kernel has no nil; ask `x.abs == Float::INFINITY`, or `x == Float::INFINITY` where the sign is the question. `negative?`, `positive?` and `zero?` are not here either, for the reason `signbit` is not: the comparison is the thing, and it is already in the subset
- `x.clamp(low, high)`, which answers the value or whichever bound it ran past. All three have to be the same *class* -- Ruby hands back the receiver in one branch and a bound in the other, so `5.clamp(0.0, 3.0)` is the Float 3.0 where `1.clamp(0.0, 3.0)` is the Integer 1, and no type assigned before the loop runs is both. Two widths of one class are not that case: a float32 cell is a Ruby Float as a double is, so `f[i].clamp(0.0, 1.0)` keeps the cell's width. The two things Ruby raises `ArgumentError` for are raised here too -- bounds the wrong way round, and a NaN that cannot be ordered -- with Ruby's class; the message names the reason rather than the value, the error slot carrying a code and not a number. A cell with no value in it does not raise, which is the rule the division helpers already keep. The range form, `x.clamp(0.0..1.0)`, is not in the subset
- `sum(w)`, `min(w)`, `max(w)` and `sort(w)` over a local array of one axis -- bare calls, the compiler's own names rather than methods on the array. The first three are expressions and `sort` is a statement (see [Intrinsics](#intrinsics))
- `%`, which floors as Ruby's does rather than truncating as C's does, and raises `ZeroDivisionError` for a zero divisor as Ruby's does -- a float one included, where C's `fmod` and CArray's `%` answer `NaN`. A float `/` by zero is an infinity, in Ruby as here
- `x += e` and the rest of the operator assignments, on a local, on a cell (`work[i, k] += e`) and on a CScalar; each is the assignment it stands for, so a fold written with `+=` is still split into partial sums. `||=` and `&&=` are refused, being about nil and false rather than about arithmetic
- `& | ^ ~ << >>` on integers, and `& | ^` on booleans. A shift is C's shift in the width the kernel computes integers in, `int64_t` (`uint64_t` for an unsigned cell), and its result is narrowed on store like any other. So on a cell narrower than that, a count that reaches past the cell's own width gives the Ruby loop's answer and not CArray's, which shifts in the cell's width: `int32` `1 << 33` stores `0` here and in Ruby, where CArray's `<<` answers `2`. A count of 64 or more, or a negative one, is C's undefined shift rather than Ruby's
- `(from...to).each { |j| ... }` and `n.times { |j| ... }`, an inner loop whose index addresses reads and writes alike -- `work[i, j] = ...` is a row of workspace for the cell (see [A row of workspace per cell](02_KernelShapes.md#a-row-of-workspace-per-cell)); `next` and `break` inside it, and `next` in the kernel block to skip the cell
- an inner loop's range written over another index -- `(p+1...3)`, `(0...4-m)`, the shape a triangular loop takes -- where the index is one of the loops around it. Such a range is read at its widest when a subscript is held to its array (see [Known limitations](#known-limitations))
- `from.step(to, s) { |j| ... }` and `(from...to).step(s) { |j| ... }`, the same loop counting by a literal stride: `(n-1).step(0, -1)` is a downward sweep, and `to` is included there as Ruby includes it. Two loops in one body may both be written `{ |k| ... }`; each keeps its own range
- `while cond ... end`, and its modifier form, with `next` and `break` inside it; the condition is read at the top of every pass, and a local it reads must be a local before the loop.  `while true` is allowed where the body holds a `break` or a `raise`, and refused where it holds neither
- a call to a C function -- one from `jit_extern` or `jit_function`, the function's own name inside its body, or, inside a `jit_function` body, another function written with `jit_function` -- as an expression, and *as a statement*, where its value is dropped as Ruby drops it and what it did is wherever its pointer parameters pointed. It is the only call that may stand alone; a `void` function -- borrowed or written here -- may only be called there. Under a mask the call does not happen (see [Calling a C function](#a-call-may-stand-alone))
- assignment to a cell: `out[i] = ...`, at a cell the loop walks onto -- every axis of it either walks with an index at no offset or is pinned, so `out[i, 0]` writes a column and `out[i, i]` a diagonal.  Pin every axis and nothing walks: `box[0] = ...` writes one cell for every iteration and keeps the last, as the same Ruby loop does.  A pinned position is checked against the extent before the first cell, so reaching outside is a message rather than a store past the end

**Rejected**

Everything else: `for` and `until`, `begin ... end while`, strings, hashes, symbols, Ruby arrays, method definitions, `eval`, method calls outside the table above, a method on an array -- `w.sum`, `w.max`, `w.sort!` -- which is written as a function instead (`sum(w)`, and see [Intrinsics](#intrinsics)), `break` in the kernel block, `break x` and `next x`, `rand` and every other draw from a generator Ruby owns (draw from a `CArray::Rng` instead, or fill an array with `CArray#random!` and read a cell of it -- see [Known limitations](#known-limitations)), `if` without `else` in *expression* position, arithmetic on a boolean cell, comparing one with a number, and captured scalars that are not Float, Integer or Complex. On a Complex: ordering comparisons, `%`, the rounding methods and the bit operators -- which is what Ruby's Complex refuses too.

## Known limitations

- **Integer overflow wraps**, as CArray's own operators wrap. Ruby's Integer is arbitrary precision; the generated C uses `int64_t`, so a kernel that would grow past 2^63 wraps instead. Float kernels are unaffected.
- **An Integer compared with a Float is compared as two doubles**, as CArray compares them. Ruby compares the two exactly, so past 2^53 the answers part: `(2**53 + 1) == 2.0**53` is false in Ruby and true here, and `2**63 - 1` equals `2.0**63` here. Below 2^53 every int64 is a double exactly, and nothing differs. Where both sides may be that large, compare two integers.
- **A negative Float to a fractional power is `NaN`**, as `pow` answers and CArray does. Ruby answers a Complex -- `(-8.0) ** (1.0/3)` is `1.0+1.73i` -- which no real cell could hold anyway: storing it into a float array raises in Ruby too. A whole-number exponent, or a non-negative base, gives Ruby's number. For a cube root, `Math.cbrt` keeps the sign.
- **Object arrays are not handled.** `CA_OBJECT` holds Ruby values rather than numbers, and reaching into Ruby from inside a kernel would give up what compiling it was for.
- **`**` on a Complex is the one place the answer is not bit-for-bit Ruby's.** It is within a few machine epsilons, growing with the exponent. What is refused on a Complex is what Ruby refuses -- ordering comparisons, `%`, the rounding methods, the bit operators. See [Complex arrays](#complex-arrays).
- **A sine and a cosine of the same argument are one `sincos` call.** The C compiler merges them, and its sine differs from `sin` in the last bit for some arguments, where Ruby calls `sin`. Either flag that stops it costs more elsewhere than the bit is worth here, so it is documented rather than disabled; see [Design notes](05_DesignNotes.md#a-sine-beside-a-cosine-is-sincos-and-is-allowed-to-be).
- **A reduction does not take Ruby's order.** An accumulator is split into partial sums by default, which is usually the more accurate answer and is not the Ruby loop's; `reassociate: false` asks for that order back. `sum(axis:)`, whose kernels are written for the shape, is still faster at the reductions it covers.
- **A `while` may fail to return, and nothing can interrupt it.** The loop is in the subset now, and the bound that used to be compulsory is not: a compiler-invented cap would be a number nobody could choose, since the loops whose bound is knowable are already `(0...cap).each` with a `break`.  What comes with that is C's bargain, the one a `jit_function` recursing too deep already takes.  It bites harder here than it would in Ruby: a generated loop has no interrupt check in it, so `Ctrl-C` does not reach a running kernel -- whether or not it holds the GVL -- and a runaway pass ends with a signal from another terminal.  The one case that can be read off the page, `while true` with no `break` and no `raise` in it, is refused.
- **`until` is not in the subset.** `while` with the condition negated is the same loop, and one spelling of it is enough to keep.
- **A range written over another index is read at its widest.** `(p+1...3)` gives `k` a different start for every `p`, and a subscript is held to its array with one pair of numbers, so what that pair covers is every pass the loop could take. It is the safe direction -- a subscript this calls inside really is -- but a reach nothing actually makes can still be refused, and where it is, the message says which index the range was written over and that it was read at its widest. Narrowing the range, or the array's use, is what says it is safe.
- **The intrinsics and a C function take no local array of a kernel that carries masks.** A cell of such an array carries a mask beside it, and neither has anywhere to put that: what `sum` or `sort` should do with a missing cell is not decided -- pass over it, gather it at the end, count it where a median counts -- and a C signature says what a pointer points at, which a mask travels in no spelling of. Decide it in the kernel, or copy the cells the callee should see into a captured array. `border: :mask` is not a masked kernel and is unaffected.
- **An inner loop's stride is a literal.** It is what says which way the loop runs, and the C is written one way or the other before anything is known, so `k.step(0, s)` with `s` a captured integer is refused. `downto`, `upto` and `reverse_each` are refused by name, with `step` named as the spelling to use -- one way of counting down is enough to keep, and it is the one an extent already takes.
- **A kernel draws from a `CArray::Rng` and from nothing else.** `rand` is Ruby's, and Ruby's generator is reached through the VM: a kernel runs with the GVL released, which is not where it may be reached at all. What a kernel *can* draw from is a generator whose C it can paste, which is what `CArray::Rng` is: `rand = CArray::Rng.new(seed: 4)` and then `rand.random` in the block, once per cell, giving a double in `[0.0, 1.0)`. `rand.randomn` is a standard normal, which costs two draws and keeps no spare -- the classical pairing would have to hold the second in the generator's state, and a spare held between an array and a kernel is a second thing to keep in step. `random(rng: rand)` and `randomn(rng: rand)` are those two spelled as `CArray#random!(rng:)` spells them -- the only keyword arguments the subset has -- and `rand.bits` is the raw word a draw came from, as a `uint64`. All of them read one generator, so mixing them walks one sequence. It is a generator on both sides of the compiler: `a.random!(rng: rand)` fills an array from it and leaves it where a kernel then carries on, because CArray compiles the generator and hands out the same text for the kernel to paste rather than the two agreeing by construction. Two generators in one kernel are two sequences. What is not offered is a draw fixed to a *position*: which draw lands in which cell is the loop's order, and this compiler does not fix that order -- a stencil's border is a second loop over the frame, and a reduction may split its accumulator. Where that matters -- common random numbers, antithetic variates, stratification -- fill an array with `CArray#random!` before the call and read a cell of it, which was drawn in one order and stays in it. A compiled function is a third case: `jit_function` takes everything through its parameters and has nowhere to keep a state, so a body that needs draws takes the state as an `int64_t state[4]` parameter and is passed `rand.state`.
- **An operand that is not an entity is transferred before the loop.** A kernel walks memory, so an array that is not one -- a view that does not fold to an entity, a `CAObject` computing its cells in Ruby -- has the box the kernel touches transferred into a packed buffer first, and written back afterwards if the kernel wrote it. The box, not the array: an extent covering two cells transfers two. What that costs is a copy; what it changes is when the cells are read. An array whose cells are computed on read is read once per cell per call, so two reads of one cell in a kernel give the same number where the same Ruby loop would give two -- and a one-cell source is one number for the whole loop. Drawing random numbers that way therefore works, and means what filling an array before the call means. An indexed kernel refuses one that is a view of an array the same kernel writes: the copy is taken before the first cell and put back after the last, which is what an expression over whole arrays means and not what a loop means. Index the array itself and let the subscript gather -- `a[order[i]]` rather than a view of `a`.
- **Handing a pointer to a C function is C's bargain.** A declaration that carries no length -- `const double *x`, `double x[]` -- gives this compiler nothing to check an array against, and a function that keeps the pointer past the call keeps it past whatever the array was. That is the same arrangement calling the same function from C would be, for a local array and a captured one alike; what differs is only which memory is involved.
- **A local array's subscript counts from the start.** CArray's `w[-1]` is the last cell; a kernel has no such reading, so a literal negative subscript is refused by name and one the kernel works out raises `IndexError`. This is the difference the captured arrays already have. Write `w[n - 1]`.
- **`CArray.empty` leaves its cells as the stack left them.** Reading one before writing it is out of contract, the way reading under a mask is: the value is whatever was there. What it saves is the clearing, which for a 256-cell array inside a per-cell loop is 2 KiB a cell.
- **The stack limits are per function, and a chain of them is not counted.** One local array up to 4 KiB stands in a frame, and the arrays of one kernel body or one function body up to 16 KiB together; past either, a kernel allocates the array at its entry, while a function body -- which is called once per cell -- refuses it and asks the calling kernel for a pointer instead. A pasted function called from a kernel is a second frame, and a chain of three such functions can therefore stand 48 KiB deep while each of them is inside its own limit -- counting along the chain was considered and dropped, since the depth is not knowable where recursion is in the subset at all. What that costs is the bargain a deep recursion already takes: too deep is a SIGSEGV rather than a `SystemStackError`, and a body carrying arrays reaches it sooner. Both numbers are provisional, and neither counts a future thread pool's stacks.
- **Storing a real number into an integer array is C's conversion.** A value past the type's range, or a NaN, is undefined behaviour rather than a number -- and the same is true of a captured integer array, so a kernel brings no new hazard here. Round and clamp before storing where the value may leave the range. The rounding methods are not this case: `floor`, `ceil`, `round`, `truncate` and `to_i` on a Float raise `FloatDomainError` for a NaN or an infinity, as Ruby does, and `RangeError` where the Integer is past int64 -- except written straight into a float cell, which holds it whole (`1e20.floor` is `1e20`). The check costs a comparison per call, and in a loop that does little else it shows.
- **A block's source must be recoverable.** Blocks defined in `eval` or in a console have no file to read back; set `RubyVM.keep_script_lines = true` before defining them, or hand the text to `CArray::JIT.compile`, which takes a kernel as a string rather than as a block. This also ties the gem to CRuby, which CArray requires anyway.
- **Nothing existing is replaced.** `jit_for` is a new method, not a faster `each_index`: the two differ in what they reject, and a caller should be able to choose.
