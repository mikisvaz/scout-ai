# encoding: utf-8

ENV["BRANCH"] = 'main'

require 'rubygems'
require 'rake'
require 'juwelier'
Juwelier::Tasks.new do |gem|
  # gem is a Gem::Specification... see http://guides.rubygems.org/specification-reference/ for more options
  gem.name = "scout-ai"
  gem.homepage = "http://github.com/mikisvaz/scout-ai"
  gem.license = "MIT"
  gem.summary = %Q{AI gear for scouts}
  gem.description = %Q{assorted functionalities to help scouts use AI}
  gem.email = "mikisvaz@gmail.com"
  gem.authors = ["Miguel Vazquez"]

  # dependencies defined in Gemfile
  gem.add_runtime_dependency 'scout-rig', '>= 0'
  gem.add_runtime_dependency 'ruby-openai', '>= 0'
  gem.add_runtime_dependency 'ollama-ai', '>= 0'
  gem.add_runtime_dependency 'ruby-mcp-client', '>= 0'
end
Juwelier::RubygemsDotOrgTasks.new
require 'rake/testtask'
Rake::TestTask.new(:test) do |test|
  test.libs << 'lib' << 'test'
  test.pattern = 'test/**/test_*.rb'
  test.verbose = true
end

desc "Code coverage detail"
task :simplecov do
  ENV['COVERAGE'] = "true"
  Rake::Task['test'].execute
end

task :default => :test

require 'rdoc/task'
Rake::RDocTask.new do |rdoc|
  version = File.exist?('VERSION') ? File.read('VERSION') : ""

  rdoc.rdoc_dir = 'rdoc'
  rdoc.title = "scout-ai #{version}"
  rdoc.rdoc_files.include('README*')
  rdoc.rdoc_files.include('lib/**/*.rb')
end
