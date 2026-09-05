# Testing

```
rake test
rake benchmark
```

Every kernel in the suite is checked against the same computation written as
an ordinary Ruby loop -- except the masked ones, which are checked against
CArray's operators -- and the float comparisons are exact rather than within a
tolerance -- a tolerance would hide the two bugs most worth catching, FMA
contraction and computing in the wrong precision. A test whose kernel reduces
says `reassociate: false`, which is what makes its answer comparable to a Ruby
loop's at all.

The tridiagonal solver in `test/test_thomas.rb` is the case the design had to
be able to express: two sweeps in opposite directions, one of them writing two
arrays that share a denominator. It is checked bit for bit against a plain
Ruby solver, and by the residual of `A x - d`.

`benchmark/thomas.rb` times it against a Ruby loop and against LAPACK:

```
n = 1,000,000
jit_for (compiled)        9.3 ms     9.3 ns/element
Ruby loop over CArray    702.2 ms   702.2 ns/element    75x
Ruby loop over Array     215.5 ms   215.5 ns/element    23x
LAPACK ?gtsv              18.0 ms    18.0 ns/element   1.92x
largest difference from LAPACK: 1.33e-15
```

The 75x is the number this gem is about. The LAPACK column is **not** a claim
that this is faster than LAPACK, and three things stand between it and any
such reading:

- `?gtsv` does LU with partial pivoting and solves systems that are not
  diagonally dominant. This solves the ones that are. Skipping the pivot is
  most of the difference.
- 18.0 ms is what `CArray::Linalg.solve_tridiagonal` costs, not what `?gtsv`
  costs: the diagonals are passed as views, so there are contiguity copies,
  plus validation and output allocation, inside that number.
- The four arguments `?gtsv` overwrites have to be copied first. That is 3.1 ms
  and it is excluded from the figure above, because it is not part of solving.

What the comparison is good for is the other direction. `?gtsv` exists, so
this kernel can be checked against it -- and it agrees to 1.3e-15. The
algorithms `jit_for` is actually for, a periodic tridiagonal solve or a
domain-specific recurrence, have no LAPACK entry point to be checked against
at all.

`test/test_views.rb` covers the access tiers: a contiguous row, a strided
column, a reversal, a slice of a slice, and a gather view whose region is
transferred and written back.
