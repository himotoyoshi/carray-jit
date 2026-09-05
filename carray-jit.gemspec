Gem::Specification.new do |spec|
  spec.name        = "carray-jit"
  spec.version     = File.read(File.expand_path("lib/carray/jit/version.rb", __dir__))[/VERSION\s*=\s*"([^"]+)"/, 1]
  spec.summary     = "JIT compilation of CArray kernels written in Ruby"
  spec.description = <<~TEXT
    Write the loop in Ruby, and it runs at the speed of C -- one to two orders
    of magnitude faster than interpreted. It is for what a CArray expression
    cannot say: a cell that reaches its neighbours, a recurrence, a loop
    written out. What may be in a block is a subset of Ruby, and a C compiler
    has to be present at run time.
  TEXT
  spec.authors     = ["himotoyoshi"]
  spec.email       = ["himotoyoshi@users.noreply.github.com"]
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/himotoyoshi/carray-jit"

  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{c,h,rb}",
    "bin/*",
    "examples/**/*.rb",
    "examples/README.md",
    "README.md",
    "CHANGELOG.md",
    "docs/*.md",
    "LICENSE",
    "carray-jit.gemspec",
    ".yardopts",
  ]
  spec.require_paths = ["lib"]
  spec.bindir        = "bin"
  spec.executables   = ["carray-jit"]
  spec.extensions    = ["ext/carray_jit_access/extconf.rb"]

  # A kernel reaches CArray's C by address, so the ceiling is the next minor.
  spec.add_dependency "carray", ">= 3.0.1", "< 3.1"
  # fiddle ships as a bundled gem; depend on it explicitly so Ruby 3.5+ resolves it.
  spec.add_dependency "fiddle"
end
