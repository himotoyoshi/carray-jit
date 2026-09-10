require_relative "test_helper"

# The block is passed as a block, so its source has to be recovered.
class TestBlockSource < Minitest::Test

  def test_do_end_block
    values = CArray.double(10)
    values[0] = 2.0
    CArray.jit_for(1...10) do |i|
      values[i] = values[i-1] * 1.5
    end
    assert_in_delta(2.0 * 1.5 ** 9, values[9], 1e-9)
  end

  # Two blocks on one line are what defeats Proc#source_location on its own;
  # the instruction sequence reports columns, which tells them apart.
  def test_two_blocks_on_one_line
    first = CArray.double(6); first[0] = 1.0
    second = CArray.double(6); second[0] = 1.0
    CArray.jit_for(1...6) { |i| first[i] = first[i-1] * 2.0 }; CArray.jit_for(1...6) { |i| second[i] = second[i-1] * 3.0 }
    assert_equal(32.0, first[5])
    assert_equal(243.0, second[5])
  end

  def test_block_written_in_a_method
    assert_equal([1.0, 2.0, 4.0, 8.0], run_in_a_method(2.0).to_a)
  end

  def run_in_a_method (weight)
    values = CArray.double(4)
    values[0] = 1.0
    CArray.jit_for(1...4) { |i| values[i] = values[i-1] * weight }
    values
  end

  def test_eval_defined_block_needs_kept_script_lines
    previous = RubyVM.keep_script_lines
    RubyVM.keep_script_lines = true
    values = CArray.double(6)
    values[0] = 1.0
    block = eval("proc { |i| values[i] = values[i-1] * 4.0 }")
    CArray.jit_for(1...6, &block)
    assert_equal(1024.0, values[5])
  ensure
    RubyVM.keep_script_lines = previous
  end

  # The file a block sits in is read by the encoding the parser gave it.
  # `File.read` would use `Encoding.default_external`, which has nothing to
  # do with a source's encoding: with no locale set it is US-ASCII, and the
  # file comes back as bytes under a tag that every later `rstrip` raises on.
  def test_a_non_ascii_comment_inside_a_block
    values = CArray.double(4)
    CArray.jit_for(4) do |i|
      values[i] = 2.0        # 日本語のコメント
    end
    assert_equal([2.0] * 4, values.to_a)
  end

  # Columns locate the block, so what stands before it on the line has to be
  # counted the way the parser counted it.
  def test_non_ascii_before_a_block_on_the_same_line
    values = CArray.double(4)
    倍率 = 3.0; CArray.jit_for(4) { |i| values[i] = 倍率 }
    assert_equal([3.0] * 4, values.to_a)
  end

  # The two above only say anything on a machine whose locale is not UTF-8,
  # so this one asks for that machine.
  def test_a_block_is_read_whatever_the_locale
    script = <<~RUBY
      require "carray"
      require "carray/jit"
      values = CArray.double(3)
      CArray.jit_for(3) do |i|
        values[i] = 7.0      # 日本語のコメント
      end
      print values.to_a.inspect
    RUBY
    assert_equal("[7.0, 7.0, 7.0]", run_without_a_locale(script))
  end

  # `# encoding:` is one of the spellings Ruby takes, so a source is not
  # simply UTF-8 and the comment has to be read before the file is.
  def test_a_magic_comment_names_the_encoding
    script = <<~RUBY.encode(Encoding::EUC_JP)
      # encoding: euc-jp
      require "carray"
      require "carray/jit"
      values = CArray.double(3)
      CArray.jit_for(3) do |i|
        values[i] = 9.0      # 日本語のコメント
      end
      print values.to_a.inspect
    RUBY
    assert_equal("[9.0, 9.0, 9.0]", run_without_a_locale(script))
  end

  def run_without_a_locale (script)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "kernel_source.rb")
      File.binwrite(path, script)
      library = File.expand_path("../lib", __dir__)
      environment = { "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil,
                      "RUBYOPT" => nil }
      IO.popen(environment, [RbConfig.ruby, "-I#{library}", path],
               :err => [:child, :out], &:read)
    end
  end

  def test_a_block_is_required
    error = assert_raises(CArray::JIT::Unsupported) { CArray.jit_for(0...4) }
    assert_match(/needs a block/, error.message)
  end

  def test_a_name_the_block_cannot_see_is_reported
    block = proc { |i| nowhere[i] = 1.0 }
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(0...4, &block)
    end
    assert_match(/`nowhere` is not defined/, error.message)
  end

end
