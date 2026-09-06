Examples
========

Two kinds. [applications/](applications) are small programs that do something
-- read one to see how this gets used. [features/](features) is a tour of the
subset, one file per feature, closer to documentation with the answers checked.

```
ruby examples/applications/game_of_life.rb
rake examples                        # all of them
```

Applications
------------

| | |
| --- | --- |
| [game_of_life.rb](applications/game_of_life.rb) | Conway's rules as a stencil, twice: with the indices named, and as a window on a torus |
| [moving_average.rb](applications/moving_average.rb) | a price series: exponential smoothing, running peak, drawdown |
| [heat_equation.rb](applications/heat_equation.rb) | implicit diffusion in a rod -- a tridiagonal solve every step |
| [sobel_edges.rb](applications/sobel_edges.rb) | edge detection on an image, printed as ASCII |
| [sensor_gaps.rb](applications/sensor_gaps.rb) | quality control on a record with holes in it |
| [point_cloud.rb](applications/point_cloud.rb) | rotating points, their covariance, projecting onto a basis |
| [mandelbrot.rb](applications/mandelbrot.rb) | escape time per cell -- a loop whose length no cell shares, and `z = z*z + c` as a Complex |
| [relaxation.rb](applications/relaxation.rb) | steady heat on a plate: a stencil sweep with the boundary held |
| [partial_sums.rb](applications/partial_sums.rb) | nine series in one pass, and where the order of a sum is a choice |
| [sieve.rb](applications/sieve.rb) | Eratosthenes: an inner loop the data decides the length of |
| [recursion.rb](applications/recursion.rb) | fib, tak, tarai and ackermann as `jit_function`s that call themselves |
| [quicksort.rb](applications/quicksort.rb) | the textbook partition as a compiled C function, recursing through a pointer |
| [kepler.rb](applications/kepler.rb) | Newton's method where the passes are the cell's business, not the program's |

Each says what you would otherwise have written -- a Ruby loop, or an
expression over whole arrays -- and measures against it. The numbers vary with
the machine; the ratios are what to read.

The tour
--------

| | |
| --- | --- |
| [01_element_wise.rb](features/01_element_wise.rb) | `jit_each { out = a + b * c }` and `jit_map` in one pass, and broadcasting |
| [02_stencil.rb](features/02_stencil.rb) | each cell from its neighbours; extents, offsets, a step of two |
| [03_recurrence.rb](features/03_recurrence.rb) | Legendre polynomials; upward sweeps, Ruby's division, a refused range |
| [04_thomas.rb](features/04_thomas.rb) | a tridiagonal solver; the downward sweep and why it is `step(0, -1)` |
| [05_reduction.rb](features/05_reduction.rb) | sum, maximum, count and a matrix multiply, all as inner loops |
| [06_jit_contract.rb](features/06_jit_contract.rb) | Contraction over a repeated index; matmul, trace, outer product, the shape check |
| [07_masks.rb](features/07_masks.rb) | `a[i] == UNDEF`, filling holes, and implicit propagation |
| [08_views.rb](features/08_views.rb) | a column, a slice of a slice, a transpose, written in place |
| [09_inspecting.rb](features/09_inspecting.rb) | the generated C, the cost of compiling, and what is refused |
| [10_complex.rb](features/10_complex.rb) | complex arrays, the way in and out of them, and Ruby's signed zeros |
| [11_c_functions.rb](features/11_c_functions.rb) | `jit_extern` for a C function already compiled, `jit_function` for one written in Ruby |
| [12_sweep.rb](features/12_sweep.rb) | letting CArray drive the element-wise loop; what that bounds, and what keeps it here |
| [13_cscalar.rb](features/13_cscalar.rb) | a `CScalar` in an expression, in a loop, and as the one cell every iteration writes |
| [14_stencil_window.rb](features/14_stencil_window.rb) | `jit_stencil`: windows instead of indices, and the five answers `border:` gives |
| [15_loops.rb](features/15_loops.rb) | an inner loop with a `break`, `while` where no bound is known, `next` |
| [16_raising.rb](features/16_raising.rb) | `raise "..."` in a kernel: what comes back, and what was written before it |
