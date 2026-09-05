# Locals, types and postfix math

## Locals, and what Ruby having no types costs

Types are **assigned, not inferred**: an array's dtype and a captured scalar's
class fix the leaves, and everything else follows bottom-up. That is what
keeps this small -- there is no type variable to solve for, because the
values are right there.

Locals are the one place Ruby's dynamism shows through. A Ruby local holds
whatever it was last assigned, and that can change type mid-body:

```ruby
x = 5
y = x / 2      # an integer division: y is 2
x = 1.5        # now x is a Float
```

No single C variable is both, so types are settled in one forward pass and
each type gets a variable of its own:

```c
int64_t x = INT64_C(5);
int64_t y = x >> 1;        /* the integer division Ruby did */
double x__2 = 1.5;
```

Reassignment at the same type reuses the variable. A local left with different
types on the two arms of a branch does not survive it, and reading it after
says so.

A loop is where one forward pass is not enough: the body runs again with what
the last pass left behind. So a local that goes round the loop has to be one
type, and a body that changes it is refused rather than compiled as whichever
type the first pass saw:

```ruby
x = 2
(0...3).each { |j| y = x / 4; x = 1.5 }
#=> `x` enters this loop as an Integer and comes back round as a Float
```

Ruby divides in integers on the first pass and in floats after; no single C
variable does that. Writing `x = 2.0` settles it. A local that lives only
inside the body may still change type, because it is assigned before it is
read on every pass and so nothing crosses the edge.

The version before this one settled locals by joining every assignment's type
and declaring the variable once. On the example above it printed the right
answer -- by dividing in double where Ruby divided in integers, and then
truncating 1.5 to 1 on the way back. Two errors that happened to cancel.

## Postfix math

`CArray::CoreExtensions` is a refinement that puts `sqrt`, `tanh` and the rest
on `Float` and `Integer`, so that one formula reads the same whether it is
applied to a scalar or to a whole array:

```ruby
using CArray::CoreExtensions

CArray.jit_for(n) { |i| out[i] = (0.0415 * (t[i] - 218.8)).tanh }
```

A per-cell kernel works on scalars pulled out of arrays, which is exactly the
scalar half of that polymorphism, so a formula already written that way
compiles as it stands.

Only the sixteen names that are 1:1 with math.h are accepted. The refinement's
other methods are refused by name, `expm1` and `log1p` most pointedly: C has
functions by those names, and they exist because `exp(x) - 1` and `log(1 + x)`
lose precision for small x -- which is what the Ruby side computes. Lowering
them to the C functions would quietly produce different numbers, the same trap
as `%` and `fmod`.

One honesty note: carray-jit reads the block's syntax, not its meaning, so it
compiles `x.sqrt` whether or not the file that wrote it said `using
CArray::CoreExtensions`, since it reads the block rather than running it.
Write the `using` all the same: it is what lets the same formula be handed a
scalar, where it is Ruby that runs and `Float#sqrt` has to exist.
