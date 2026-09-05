# Contraction

`CArray.contract` puts the block in Einstein's convention: **an index that
appears twice in the term is summed**. The repetition is the notation -- it is
what stands in for the sigma.

```ruby
c = CArray.contract { |i, j, k| a[i,k] * b[k,j] }   # "ik,kj->ij"
m = CArray.contract { |i, k|    a[i,k] * v[k]   }   # "ik,k->i"
s = CArray.contract { |i, k|    a[i,k] * b[i,k] }   # "ik,ik->", a one-cell result
t = CArray.contract { |i|       q[i,i]          }   # "ii->"
o = CArray.contract { |i, j|    p[i] * r[j]     }   # "i,j->ij", nothing summed
```

The result is allocated and returned, its axes being the free indices in the
order the block named them -- so the parameter list is where the axis order is
stated, and `{ |j, i, k| ... }` gives the transpose. Assigning into an array of
your own says where to put it instead:

```ruby
CArray.contract { |i, j, k| c[i,j] = a[i,k] * b[k,j] }
```

which must name exactly the free indices, and still does not decide what is
summed.

No extent is given, because each index's extent is fixed by the axes it
addresses. An index whose axes disagree is refused, which is the shape check a
contraction exists to do:

```
`k` addresses axes of different extents: `a` axis 1 is 4, `b` axis 0 is 5
```

Neither form decides what is summed. So a sum along an axis is not a
contraction, and is refused:

```ruby
CArray.contract { |i, k| total[i] = a[i,k] }
#=> `k` appears once, so it is free and must be on the left. A contraction
#   sums the indices that appear twice; to sum one that does not, write the
#   loop with jit_for, or use sum(axis:)
```

There is nothing in `a[i,k]` standing in for a sigma, and summing anyway would
be the `=` quietly meaning something it does not say. `sum(axis: 1)` is that
operation, and it is faster than anything written here.

An array that is both written and read is a recurrence rather than a
contraction, and is refused with a pointer at `jit_for` too.

There is no BLAS for an arbitrary contraction, which is rather the point: this
compiles to a plain nest of loops and is slower than a tuned GEMM, but it is
one line and it exists.

Its sum is serial. `jit_for`'s reduction takes partial sums by default and
`contract`'s does not, which is the wrong way round -- a contraction is a sum
with no loop written anywhere for it to agree with -- and stays that way only
until `contract` has a meaning in the core to be licensed against.
