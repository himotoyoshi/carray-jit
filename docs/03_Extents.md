# Extents, steps and subscripts

## The extent says which cells, and which way

Which way an axis runs is the extent's to say, and the kernel runs the order
it is given. Where a kernel reads a cell it will later write, that order is
the answer: reading behind the cell being written propagates forwards, reading
ahead of it propagates backwards, and both together mean cells already passed
hold new values while cells not yet reached hold old ones. None of these is
ambiguous, and each is what the same Ruby loop leaves behind.

So the direction is **written at the call site**, because that is the only
place a reader sees it:

```ruby
CArray.jit_for(1...n) { |i|                       # upward: reads cc[i-1]
  denominator = b[i] - a[i] * cc[i-1]
  cc[i] = c[i] / denominator
  dd[i] = (d[i] - a[i] * dd[i-1]) / denominator
}

CArray.jit_for((n-2).step(0, -1)) { |i|           # downward: reads x[i+1]
  x[i] = dd[i] - cc[i] * x[i+1]
}
```

A plain `Range` means upward, and `step` is how the other direction is said.
Neither is checked against the body: a kernel is not asked to justify the
order it was handed, any more than a `for` loop in C or a `do` loop in Fortran
is. What *is* checked is that every cell the loop would touch exists -- see
below.

`(n-2)..0` would read better than `(n-2).step(0, -1)`, and is not accepted:
Ruby gives that Range no elements at all, so the same expression written as a
Ruby loop would silently do nothing. `step` is the spelling Ruby actually
iterates backwards.

The forward sweep above also shows why a kernel writes as many arrays as it
likes: `cc` and `dd` share a denominator, and splitting them into two loops
would compute it twice.

## Skipping cells

An extent may step by more than one, and an offset still means what it means
in Ruby -- `a[i-1]` is the cell at index i-1, whether or not the loop is one
that writes it:

```ruby
CArray.jit_for((2...n).step(2)) { |i| a[i] = a[i-1] + b[i] }
CArray.jit_for((2...n).step(2)) { |i| a[i] = a[i-2] * 3.0 }
```

With a step of two the loop writes only every other cell, so the first reads
cells this loop never touches and the second reads its own previous iterate.
Both are what the same Ruby loop over the same sequence would do.

## Ranges are checked, not guessed

Because the range is given rather than inferred, the extents, the range and
the offsets are all known before anything runs, and a kernel that would reach
outside its array says so rather than reaching:

```ruby
CArray.jit_for(0...8) { |i| values[i] = values[i-1] * 2.0 }
#=> CArray::JIT::Unsupported: `values` is indexed at `values[i - 1]`,
#   so the range on `i` cannot start at 0
```

This is the check that has to be here. Ruby raises on an index past the end
and CArray does too; C reads whatever is there, or writes it. Everything else
about the order is the caller's to say.

An inferred range would have quietly started at 1 instead, and a kernel that
meant to touch cell 0 would never say so.

## Subscripts the kernel works out

A subscript is usually an index and a constant, and then every cell the kernel
touches is known before it runs. But it may also be a value the kernel works
out -- a cell of another array, or a local -- and then it cannot be, so the
check moves to the access:

```ruby
CArray.jit_for(n) { |i| result[i] = table[index[i]] }        # a gather

CArray.jit_for(n) { |i|                                      # a histogram
  bin = value[i].floor
  histogram[bin] = histogram[bin] + 1
}
```

Out of range raises `IndexError`, at the cell the Ruby loop would have raised
at: the loop stops there rather than running on and reporting at the end. A
read outside the array reads cell zero and reports, which changes nothing that
is kept; a write outside it is not made at all, since a report that arrived
after the damage would be no use.

This is the one thing about a kernel that is not settled in advance, and it
costs what that implies: a compare per access, and no vectorising the
expression it is in. Kernels without such a subscript are untouched -- they
keep both loops and the check that costs nothing.

A view that has to be reached a box at a time still takes one, but the box
becomes the whole view: a computed index could reach any cell of it. That
costs what copying the view would have cost, which is what the caller would
otherwise have been told to write by hand.

One restriction remains. A write is either the cell the loop is on or a
computed one -- never the cell one along, which is the cell another iteration
writes.
