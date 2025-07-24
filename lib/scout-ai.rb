require 'scout'
require 'scout/path'
require 'scout/resource'

Path.add_path :scout_ai_lib, File.join(Path.caller_lib_dir(__FILE__), "{TOPLEVEL}/{SUBPATH}")

require 'scout/llm/ask'
require 'scout/llm/chat'
require 'scout/llm/embed'
require 'scout/llm/agent'
