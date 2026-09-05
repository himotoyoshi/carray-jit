require "rake/testtask"
require "rbconfig"

begin
  require "yard"
  YARD::Rake::YardocTask.new(:yard)
rescue LoadError
  # yard gem not installed; `rake yard` will be unavailable.
end

EXTENSION_DIRECTORY = "ext/carray_jit_access"
EXTENSION_NAME = "access.#{RbConfig::CONFIG['DLEXT']}"
# mkmf names the target carray/jit/access so that `gem install` puts it under
# lib/carray/jit, but it builds the object flat in the extension directory.
BUILT_EXTENSION = File.join(EXTENSION_DIRECTORY, EXTENSION_NAME)
INSTALLED_EXTENSION = File.join("lib/carray/jit", EXTENSION_NAME)

EXTENSION_SOURCES = FileList[File.join(EXTENSION_DIRECTORY, "*.{c,h}")] +
                    [File.join(EXTENSION_DIRECTORY, "extconf.rb")]

file BUILT_EXTENSION => EXTENSION_SOURCES do
  Dir.chdir(EXTENSION_DIRECTORY) do
    ruby "extconf.rb"
    sh "make"
  end
end

file INSTALLED_EXTENSION => BUILT_EXTENSION do
  cp BUILT_EXTENSION, INSTALLED_EXTENSION
end

desc "Build the memory extension"
task :compile => INSTALLED_EXTENSION

Rake::TestTask.new(:test) do |task|
  task.libs << "lib" << "test"
  task.test_files = FileList["test/test_*.rb"]
  task.warning = false
end
task :test => :compile

desc "Compare compiled kernels against the same loops written in Ruby"
task :benchmark => :compile do
  ruby "-Ilib benchmark/recurrence.rb"
  puts
  ruby "-Ilib benchmark/views.rb"
  puts
  ruby "-Ilib benchmark/thomas.rb"
  puts
  ruby "-Ilib benchmark/element_wise.rb"
  puts
  ruby "-Ilib benchmark/narrow_types.rb"
  puts
  ruby "-Ilib benchmark/footprint.rb"
  puts
  ruby "-Ilib benchmark/reduction.rb"
  puts
  ruby "-Ilib benchmark/break_even.rb"
end

desc "Run every example"
task :examples => :compile do
  Dir[File.expand_path("examples/*/*.rb", __dir__)].sort.each do |example|
    puts "== #{example.split("/")[-2..].join("/")}"
    ruby "-Ilib #{example}"
    puts
  end
end

desc "Show the kernel cache"
task :cache do
  ruby "-Ilib bin/carray-jit status"
end

desc "Remove build products"
task :clean do
  rm_f Dir[File.join(EXTENSION_DIRECTORY, "**/*.{o,#{RbConfig::CONFIG['DLEXT']}}")]
  rm_f Dir[File.join(EXTENSION_DIRECTORY, "Makefile")]
  rm_rf Dir[File.join(EXTENSION_DIRECTORY, "**/*.dSYM")]
  rm_f INSTALLED_EXTENSION
end

task :default => :test

# A new CArray call reached for here, with the floor in the gemspec left where
# it was, survives a green test run -- the CArray in the checkout is newer than
# the floor.  So the release path asks whether the gemspec admits what was
# tested against.
desc "Check that the CArray in use satisfies the gemspec's declared range"
task :dependency_check do
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
