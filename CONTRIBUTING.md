# Contributing to carray-jit

Thanks for looking. This file says which form a contribution is best sent
in, so that neither of us spends effort on something that cannot land.

## What to send

| What you have | How to send it |
|---|---|
| **A bug report or a feature request** | Open an issue. |
| **A small, self-contained bug fix** | Open a pull request. |
| **Anything larger** | Open an issue first. |

carray-jit was built the way the README describes: designed and reviewed
by me, implemented in collaboration with AI coding tools. That has a
consequence worth saying plainly, because it is not visible from outside.
Code here gets rewritten as a matter of course — mine included. A patch
that touches the internals is likely to be reimplemented rather than
merged, and not because anything is wrong with it. That is simply how
work moves through this repository.

So a description travels further than a diff. An issue saying what you
were trying to do, what happened, and what you expected can be acted on
directly. A patch for the same thing may end up read for the problem it
describes and then written again — a poor return on your evening.

A small, self-contained bug fix is the exception. Send it as a pull
request.

When a change starts from your issue, the changelog entry will say so.

## Opening an issue

Issues in English or Japanese are both fine.

For a bug, include:

- carray-jit version (`CArray::JIT::VERSION`), CArray version
  (`CArray::VERSION`), Ruby version, and OS
- **The C compiler and its version.** This library hands your block to
  whatever compiler it finds, so the compiler is part of the report the
  way the Ruby version is
- The smallest script that shows the problem
- What you expected and what you got

Two kinds of problem live here, and they want different things:

**A block that is refused** — say what you were trying to write. The
subset is documented in [What may be in a block](docs/03_Blocks.md), and
a refusal is either the subset working as intended, in which case the
message should have pointed somewhere useful, or a gap. Either way the
block itself is the report.

**A kernel that compiles and computes the wrong thing** — this is the
serious one. Include `kernel.c_source`, which is the C that actually ran,
and say what the same block computes as a Ruby loop. A kernel is meant to
agree with the loop it replaces, cell for cell.

And, where they apply, the things most bugs here turn on:

- the **data type** of the arrays involved, including the types of block
  locals, which are inferred
- whether any array carries a **mask**
- whether you are working on an **entity or a view** (`a[0..1, nil]`,
  `transpose`, `reshape` and friends return views that share storage)
- whether the kernel came from the **cache**. A kernel is compiled once
  and reused across processes, so a stale object can outlive the change
  that should have replaced it. `rake cache` shows what is stored and
  `CArray::JIT.clear_cache` empties it — if clearing the cache changes
  the answer, say so, because that is a bug in the cache key

Please say which OS you are on even if the bug looks portable. Compilers
differ in what they do with the same C, and this library generates C.

Note that this gem moves with CArray and the surface is not settled
until CArray 3.1: behaviour can change between releases. A change
recorded in [CHANGELOG.md](CHANGELOG.md) is a change, not a bug. If a
documented change breaks something for you, that is still worth an issue
— say what it broke.

For a feature request, describe the problem rather than the API you have
in mind. What you were trying to compute, and what made it awkward, is
the part that carries; the shape it should take is the part most likely
to change on the way in.

Performance reports are welcome as reproducible scripts. `rake benchmark`
is what is used for development, and a number on its own cannot be
checked against anything; a script can be run.

## Sending a fix

Ruby 3.2 or later, a C compiler, and CArray in the range the gemspec
declares. Build and test:

```sh
rake compile     # build the small memory extension in place
rake test        # every test suite
rake benchmark   # compiled kernels against the same loops in Ruby
rake examples    # run every example
```

`rake test` must report no failures. It is also the default task, so a
bare `rake` does the same thing.

The tests are hand written, one file per area, and a test for your fix
goes beside the ones it belongs with — follow whichever style the
neighbouring file uses. Two things about them are worth knowing before
you add one:

- **Float comparisons are exact, not within a tolerance.** A kernel is
  checked against the same computation written as a Ruby loop, and the
  two are required to agree bit for bit. A tolerance would hide exactly
  the bugs the suite exists to catch. Where the answer is legitimately
  allowed to differ — a reduction whose accumulator may be split — the
  test says so and pins the order it asked for.
- **A test that only checks the result is half a test.** What a kernel
  computes and what it compiles to are separate questions, and several
  suites assert against `c_source` because that is where a wrong
  translation shows up first.

Then, in the same pull request:

- If you changed what a public method does or accepts, update its
  documentation comment in `lib/` — those comments are the source of the
  generated documentation — and the guide page in `docs/` that covers it.
- Add an entry to [CHANGELOG.md](CHANGELOG.md), at the top of the
  unreleased section, opening with `- Fix:`. Write it for someone who hit
  the bug: what behaves differently now, not how the code was wrong.

Keep the commit message to a subject line and a line or two of context.
Anything a user needs to know belongs in the changelog entry rather than
in the commit.

## Working on the code

`docs/` is the guide, and it is written to be read in order: what the
library is for, the shapes a kernel takes, what may be in a block, and
what compiling costs. [Design notes](docs/05_DesignNotes.md) is the one
to read before changing anything — it records the decisions that were not
obvious, including several that look like oversights from outside.
[Cheatsheet](docs/06_Cheatsheet.md) is the quick reference to the
entry points.

The pipeline is: read the block with Prism, decide whether it falls
inside the subset, assign a type to every value in it, generate C,
compile, and call through Fiddle. Each of those is its own file under
`lib/carray/jit/`, in that order.

## License

By submitting a pull request, you agree that your contribution is licensed
under the MIT License, the same terms as the rest of the project.
