require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout/llm/agent'

# Bug B1 regression: the `attach` agent tool never attached PDFs.
#
# Two stacked defects (lib/scout/llm/agent/attach.rb):
#   * the normalization else-branch overwrote an explicit file_type 'pdf'
#     with 'image' (only 'auto' + a .pdf extension ever became 'pdf');
#   * the dispatcher was a bare `case` with no subject, so `when 'image',
#     'png', 'jpeg'` matched unconditionally and `when 'pdf'` was dead code.
#
# Every route therefore appended an 'image' message and self.pdf was never
# called. These tests drive the real tool Proc (offline: attaching only
# annotates the agent chat, no inference) and assert the appended role.
class TestLLMAgentAttach < Test::Unit::TestCase
  # Minimal byte content: attach only checks existence and the extension.
  # Files are created per call (not in setup) because the shared setup in
  # test_helper.rb wipes the tmpdir after subclass setup hooks.
  def make_fixture(name, bytes)
    dir = File.join(tmpdir, 'attach_tests')
    FileUtils.mkdir_p dir
    file = File.join(dir, name)
    File.binwrite(file, bytes)
    file
  end

  def make_pdf
    make_fixture('doc.pdf', "%PDF-1.4\n1 0 obj\nendobj\ntrailer\n<<>>\n%%EOF\n")
  end

  def make_png
    make_fixture('photo.png', ["89504e470d0a1a0a"].pack('H*'))
  end

  def attach_tool
    agent = LLM::Agent.new
    agent.attachments
    obj, _definition = agent.other_options[:tools][:attach]
    [agent, obj]
  end

  # The role of the image/pdf message the tool appended to the agent chat
  def appended_role(agent)
    message = agent.current_chat.reverse.find do |m|
      %w(image pdf).include?(m[:role].to_s)
    end
    message.nil? ? nil : message[:role].to_s
  end

  def attach(parameters)
    agent, obj = attach_tool
    obj.call('attach', IndiferentHash.setup(parameters.dup))
    [agent, appended_role(agent)]
  end

  def test_explicit_pdf_file_type_attaches_a_pdf_message
    _agent, role = attach(file: make_pdf, file_type: 'pdf')
    assert_equal 'pdf', role
  end

  def test_auto_file_type_detects_pdf_from_the_extension
    _agent, role = attach(file: make_pdf, file_type: 'auto')
    assert_equal 'pdf', role
  end

  # Schema default is 'auto' (attach.rb enum/default); the code-side
  # fallback must agree, so a call that omits file_type still sniffs the
  # extension instead of hard-coding 'image'.
  def test_missing_file_type_defaults_to_auto_detection
    _agent, role = attach(file: make_pdf)
    assert_equal 'pdf', role
  end

  def test_auto_file_type_falls_back_to_image_for_non_pdfs
    _agent, role = attach(file: make_png, file_type: 'auto')
    assert_equal 'image', role
  end

  def test_image_png_jpeg_aliases_attach_an_image_message
    png = make_png
    %w(image png jpeg).each do |file_type|
      _agent, role = attach(file: png, file_type: file_type)
      assert_equal 'image', role, "file_type #{file_type.inspect}"
    end
  end

  def test_unknown_file_type_raises_scout_exception
    agent, obj = attach_tool
    result = obj.call('attach', IndiferentHash.setup(file: make_pdf, file_type: 'exe'))

    # The tool block rescues ScoutException and returns it, so a bad
    # file_type surfaces as the exception object (process_calls marks the
    # call errored) instead of silently attaching an image.
    assert_kind_of ScoutException, result
    assert_include result.message, 'exe'
    assert_nil appended_role(agent)
  end

  def test_missing_file_raises
    _agent, obj = attach_tool
    result = obj.call('attach', IndiferentHash.setup(file: File.join(tmpdir, 'nope.pdf')))

    assert_kind_of ScoutException, result
    assert_include result.message, 'Path not found'
  end

  # The registered schema must keep advertising the auto default the code
  # now honours (B5 divergence: schema 'auto' vs code 'image').
  def test_tool_definition_advertises_auto_default
    _agent, obj = attach_tool
    agent = LLM::Agent.new
    agent.attachments
    _obj, definition = agent.other_options[:tools][:attach]
    assert_equal 'auto', definition.dig(:function, :parameters, :properties, :file_type, :default)
    assert_include definition.dig(:function, :parameters, :properties, :file_type, :enum), 'pdf'
  end
end
