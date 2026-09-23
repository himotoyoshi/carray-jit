require "rake/testtask"
require "rbconfig"

begin
  require "yard"
  YARD::Rake::YardocTask.new(:yard)
rescue LoadError
  # yard gem not installed; `rake yard` will be unavailable.
end

# A checkout of CArray to run against, in place of the installed gem.  The two
# gems are developed together, and a change on the CArray side is invisible
# here until its tree is on the load path -- which is what kept a suite run
# from saying anything about a CArray change that had not been installed yet.
#
#     CARRAY_TREE=../carray rake test
#
# The tree has to carry a built extension.  Falling back to the gem would run
# against something other than what the caller asked for and say nothing about
# it, which is the failure this exists to prevent.
CARRAY_TREE = ENV["CARRAY_TREE"]

def carray_tree_libs
  return [] unless CARRAY_TREE
  tree = File.expand_path(CARRAY_TREE)
  extension = File.join(tree, "ext")
  library = File.join(tree, "lib")
  built = File.join(extension, "carray_ext.#{RbConfig::CONFIG['DLEXT']}")
  unless File.directory?(library)
    abort "CARRAY_TREE=#{CARRAY_TREE} is not a CArray checkout (no lib/)"
  end
  unless File.exist?(built)
    abort "CARRAY_TREE=#{CARRAY_TREE} has no built extension at #{built}; " \
          "run `rake build_ext` there first"
  end
  [extension, library]
end

# Children see it too.  Several tests run a program in a child process -- the
# command, the light half that must load without the compiler -- and a child
# inherits the environment but not the parent's `-I`.  Without this the suite
# answers for the tree and its children answer for the installed gem, which is
# the same silence CARRAY_TREE exists to break: it showed up as a child saying
# a constant was missing that the tree had had all along.
unless carray_tree_libs.empty?
  flags = carray_tree_libs.map { |path| "-I#{path}" }.join(" ")
  ENV["RUBYOPT"] = [flags, ENV["RUBYOPT"]].compact.reject(&:empty?).join(" ")
end

# The `-I` flags for a `ruby` invocation from here, so a benchmark or a probe
# reaches the same CArray the suite does.
def carray_tree_flags
  carray_tree_libs.map { |path| "-I#{path}" }.join(" ")
end

Rake::TestTask.new(:test) do |task|
  task.libs.concat(carray_tree_libs)
  task.libs << "lib" << "test"
  task.test_files = FileList["test/test_*.rb"]
  task.warning = false
end
task :test => :carray_in_use

desc "Say which CArray a run here will use"
task :carray_in_use do
  script = 'puts "CArray #{CArray::VERSION} - #{$LOADED_FEATURES.grep(/carray_ext/).first}"'
  # The array form of `sh` runs the command directly, so the script keeps its
  # own `#{}` instead of losing them to a shell.
  sh RbConfig.ruby, *carray_tree_libs.map { |path| "-I#{path}" },
     "-rcarray", "-e", script, :verbose => false
end

desc "Compare compiled kernels against the same loops written in Ruby"
task :benchmark do
  ruby "#{carray_tree_flags} -Ilib benchmark/recurrence.rb"
  puts
  ruby "#{carray_tree_flags} -Ilib benchmark/views.rb"
  puts
  ruby "#{carray_tree_flags} -Ilib benchmark/thomas.rb"
  puts
  ruby "#{carray_tree_flags} -Ilib benchmark/element_wise.rb"
  puts
  ruby "#{carray_tree_flags} -Ilib benchmark/narrow_types.rb"
  puts
  ruby "#{carray_tree_flags} -Ilib benchmark/footprint.rb"
  puts
  ruby "#{carray_tree_flags} -Ilib benchmark/reduction.rb"
  puts
  ruby "#{carray_tree_flags} -Ilib benchmark/contraction.rb"
  puts
  ruby "#{carray_tree_flags} -Ilib benchmark/break_even.rb"
  puts
  ruby "#{carray_tree_flags} -Ilib benchmark/call_overhead.rb"
  puts
  ruby "#{carray_tree_flags} -Ilib benchmark/crossover.rb"
end

desc "Run every example"
task :examples do
  Dir[File.expand_path("examples/*/*.rb", __dir__)].sort.each do |example|
    puts "== #{example.split("/")[-2..].join("/")}"
    ruby "#{carray_tree_flags} -Ilib #{example}"
    puts
  end
end

desc "Show the kernel cache"
task :cache do
  ruby "#{carray_tree_flags} -Ilib bin/carray-jit status"
end

task :default => :test

# A new CArray call reached for here, with the floor in the gemspec left where
# it was, survives a green test run -- the CArray in the checkout is newer than
# the floor.  So the release path asks whether the gemspec admits what was
# tested against.
desc "Check that the CArray in use satisfies the gemspec's declared range"
task :dependency_check do
  # The same CArray the suite ran against, so the range is checked on what was
  # tested rather than on whatever happens to be installed.
  $LOAD_PATH.unshift(*carray_tree_libs)
  require "carray"
  spec = eval File.read("carray-jit.gemspec")
  carray = spec.dependencies.find { |dependency| dependency.name == "carray" }
  unless carray.requirement.satisfied_by?(Gem::Version.new(CArray::VERSION))
    STDERR.puts "The CArray in use is outside the range carray-jit declares"
    STDERR.puts "  carray in use  - #{CArray::VERSION}"
    STDERR.puts "  gemspec asks   - #{carray.requirement}"
    STDERR.puts "Please check!"
    exit(1)
  end
end

desc "Build and install the gem"
task :install => :dependency_check do
  spec = eval File.read("carray-jit.gemspec")
  sh "gem build carray-jit.gemspec"
  sh "gem install #{spec.full_name}.gem --no-document"
end
