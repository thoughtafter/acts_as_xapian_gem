require 'rubygems'
require 'rake'

begin
  require 'jeweler'
  Jeweler::Tasks.new do |gem|
    gem.name = "acts_as_xapian"
    gem.summary = %Q{A gem for interacting with the Xapian full text search engine. Based on the acts_as_xapian plugin.}
    gem.description = %Q{A gem for interacting with the Xapian full text search engine. Completely based on the acts_as_xapian plugin.}
    gem.email = "mdnelson30@gmail.com"
    gem.homepage = "http://github.com/mnelson/acts_as_xapian_gem"
    gem.authors = ["Mike Nelson"]
    gem.add_development_dependency "rspec", ">= 1.2.9"
    gem.add_development_dependency "active_record"
    # gem is a Gem::Specification... see http://www.rubygems.org/read/chapter/20 for additional settings
  end
  Jeweler::GemcutterTasks.new
rescue LoadError
  puts "Jeweler (or a dependency) not available. Install it with: gem install jeweler"
end

require 'spec/rake/spectask'
Spec::Rake::SpecTask.new(:spec) do |spec|
  spec.libs << 'lib' << 'spec'
  spec.spec_files = FileList['spec/**/*_spec.rb']
end

Spec::Rake::SpecTask.new(:rcov) do |spec|
  spec.libs << 'lib' << 'spec'
  spec.pattern = 'spec/**/*_spec.rb'
  spec.rcov = true
end

task :spec => :check_dependencies

task :default => :spec

require 'rake/rdoctask'
Rake::RDocTask.new do |rdoc|
  version = File.exist?('VERSION') ? File.read('VERSION') : ""

  rdoc.rdoc_dir = 'rdoc'
  rdoc.title = "acts_as_xapian #{version}"
  rdoc.rdoc_files.include('README*')
  rdoc.rdoc_files.include('lib/**/*.rb')
end
