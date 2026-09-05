# Reductions

A reduction is a per-cell computation like any other: the caller says where
the answer goes, and the kernel fills that cell.

```ruby
CArray.jit_for(rows) { |i|
  accumulator = 0.0
  (0...columns).each { |j| accumulator = accumulator + source[i, j] }
  total[i] = accumulator
}
```

The accumulator is split into partial sums, which is faster than the serial
chain and usually the more accurate answer, and is not the order the same loop
would take in Ruby. `reassociate: false` asks for that order; see "The order a
reduction takes its terms in" below.

What makes it expressible is `(from...to).each { |j| ... }` -- or
`n.times { |j| ... }`, which is the same loop from zero: an inner loop whose
index addresses arrays but writes nothing. The accumulator is then an
ordinary block-local, which is why sum, maximum, product, count and a dot
product all fall out without a primitive each -- and why a matrix multiply
does too:

```ruby
CArray.jit_for(rows, columns) { |i, j|
  accumulator = 0.0
  (0...inner).each { |t| accumulator = accumulator + left[i, t] * right[t, j] }
  result[i, j] = accumulator
}
```

`each` rather than `for`, because `for` does not open a scope: it would assign
an enclosing variable of the same name and leave the index bound afterwards,
neither of which the generated loop does. The range must be a literal `Range`;
`Enumerator::ArithmeticSequence` -- `(0...n).step(2)` -- is not handled yet.

Inner loops nest, and an index binds to an axis by name rather than by
position. One index may walk two axes of the same array (a trace), two indices
may walk one axis of it (`c[p,a] * c[p,b]`, which is a covariance), the outer
indices need not address axes in their own order (a transposing read), and a
full contraction is the same thing written into a one-cell box.

That holds for an array the kernel writes as well. In `v[a,b] = v[a,a]` the
cell read is one this loop also writes, so cells reached before it read the
old value and cells reached after it read the new one, and the answer depends
on the order -- which is what the extent states. So the kernel runs the order
it was given and means what the same Ruby loop means.

Written out, a contraction is loops; but the loops are the *definition*
rewritten, so `contract` writes the definition instead -- see
[Contraction](06_Contraction.md).

An offset may be an integer the block closed over -- `a[i - window]` for a
window the caller chooses -- and it reaches the kernel as an argument, so one
compiled kernel serves every value of it. How far the kernel reaches is then
known when it is called rather than when it compiled, which is where the
bounds check already lives. Nothing is executed before it passes.

An index may address any axis of any array that is read. A subscript that is
not an index **pins** the axis: `a[i, 0]` is the first column, and so is
`a[i, offset]` where `offset` is an integer the block closed over. A pinned
position is an argument to the kernel rather than part of it, so one compiled
kernel serves every value -- which is what lets a contraction be taken row by
row from an ordinary Ruby loop:

```ruby
n.times { |i| out[i] = CArray.contract { |k| a[i, k] * b[i, k] }[0] }
```

Whether that is a good idea depends on how much work each call does. A call
costs 20-40 us before the kernel starts, and against that:

```
64 dot products, inner length     Ruby loop    loop of contract    one jit_for
                            4       0.04 ms             1.22 ms         0.03 ms
                           64       0.56 ms             1.41 ms         0.02 ms
                        1,000       8.38 ms             1.51 ms         0.07 ms
                       10,000      83.17 ms             2.00 ms         0.60 ms
                      100,000     839.73 ms             7.17 ms         5.92 ms
```

Below a few hundred elements the loop of `contract` is **slower than the Ruby
loop it replaces** -- at an inner length of four, thirty times slower -- because
the per-call cost dwarfs an inner loop the interpreter gets through quickly.
Past a thousand it wins, and by a hundred thousand the overhead has
disappeared and the loop form is simply the more readable one.

How many times the outer loop runs does not enter into it: both sides scale
with it, so the ratio holds. At an inner length of 64 the loop of `contract`
is 0.12x, 0.33x and 0.40x the Ruby loop for 4, 64 and 1024 outer iterations;
at 10,000 it is 48x, 41x and 41x. The only question is whether one call's
worth of work is worth its 20-30 us.

Writing the whole thing as one kernel has no such threshold: it beats the Ruby
loop at every size on this table, and by two orders of magnitude once there is
real work.

A constant subscript pins an axis: `a[i, 0]` and `a[i, j]` on the same array is ordinary. An
array the kernel *writes* cannot be read through an inner index, because that
would reach cells another outer iteration owns and no evaluation order settles
it.

```
row sums over 2000 x 500
  jit_for                       0.3 ms   0.25 ns/cell
  jit_for, reassociate: false   0.9 ms   0.92 ns/cell   3.61x
  Ruby loop                     50.7 ms  50.75 ns/cell    200x
  sum(axis: 1)                   0.1 ms   0.10 ns/cell   0.40x

matrix multiply 300 x 300 x 300
  jit_for                       6.5 ms   0.24 ns per multiply-add   8.37 GFLOP/s
  jit_for, reassociate: false  15.3 ms   0.57 ns per multiply-add   3.53 GFLOP/s
```

### The order a reduction takes its terms in

Floating-point addition is not associative, so a serial accumulator is one
dependent chain and each addition waits for the one before it. Splitting it
into partial sums is what fills that latency, and it is the whole of the
difference between the two rows above -- and between `jit_for` and
`sum(axis: 1)`, whose kernels take a `reduction_kind:` licence that emits
`#pragma omp simd reduction(...)`.

A kernel splits the accumulator by default, into eight chains combined
pairwise at the end, with the terms that do not fill a round left to a serial
tail. So the three answers are three numbers:

```
Ruby's serial sum              204800000000.0     4247d78400000000
jit_for, reassociate: false   204800000000.0     4247d78400000000
jit_for                       204800000000.0042  4247d7840000008a
sum(axis: 1)                   204800000000.0074  4247d784000000f2
```

That is not a trade of accuracy for speed. Splitting the accumulation is what
limits the cancellation, so the partial sums are usually the *more* accurate
answer -- on this row, which cancels, the licensed kernel is nearer the true
sum than the serial one is. What it is not is the order Ruby's loop would have
taken, and that is what `reassociate: false` asks for:

```ruby
CArray.jit_for(rows, reassociate: false) { |i|
  accumulator = 0.0
  (0...columns).each { |j| accumulator = accumulator + source[i, j] }
  total[i] = accumulator
}
```

Two reasons to ask for it. A **compensated summation** -- Kahan's, or any
error-free transformation -- *is* its order: reassociating it does not make it
less accurate, it deletes the algorithm. And **checking a kernel against the
loop it replaces** needs the two to be comparable to the last bit, which is
how this gem's own tests are written; `CARRAY_JIT_REASSOCIATE=0` sets it for a
whole process.

What is licensed is the order the *iterations* are grouped in, and nothing
else. Each term is computed exactly as it was written, in the operand order it
was written in, and everything outside a reduction is untouched: a recurrence
is serial by definition, and a stencil's cells are independent, so neither has
an order to give up.

The licence is part of the kernel rather than of the call -- it decides what C
is emitted -- so the two spellings compile to two kernels and the cache keeps
them apart. `#c_source` shows which one ran; the chains are named
`<accumulator>__p0` and up.

**A fold and nothing else.** The accumulator has to enter the loop already
live and leave it folded whole: one statement, one associative operator, the
accumulator on one side and a term that does not mention it on the other. An
exponential average -- `accumulator = accumulator * 0.5 + source[i, j]` -- is
not that, and keeps the serial loop, which is right: there the order is the
algorithm. So does a masked accumulator (a partial sum would need a mask
each), an integer one (reassociating it computes the same number, so there is
nothing to license), and a written-out extent shorter than one round.

The matrix multiply carries a different subtlety -- it is a plain triple loop
and not a blocked GEMM, so BLAS is still an order of magnitude away.

So this is not a faster `sum`. It is a way to write the reduction that has no
`sum`.
