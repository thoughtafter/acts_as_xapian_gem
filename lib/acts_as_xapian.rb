# acts_as_xapian/lib/acts_as_xapian.rb:
# Xapian full text search in Ruby on Rails.
#
# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: francis@mysociety.org; WWW: http://www.mysociety.org/
#
# Documentation
# =============
#
# See ../README.txt foocumentation. Please update that file if you edit
# code.

# Make it so if Xapian isn't installed, the Rails app doesn't fail completely,
# just when somebody does a search.
begin
  require 'xapian'
  $acts_as_xapian_bindings_available = true
rescue LoadError
  STDERR.puts "acts_as_xapian: No Ruby bindings for Xapian installed"
  $acts_as_xapian_bindings_available = false
end

module ActsAsXapian
  class NoXapianRubyBindingsError < StandardError; end

  @@db = nil
  @@db_path = nil
  @@writable_db = nil
  @@writable_suffix = nil
  @@init_values = []

  mattr_reader :config, :db, :db_path, :writable_db, :stemmer, :term_generator, :enquire, :query_parser, :values_by_prefix

  # Offline indexing job queue model, create with migration made
  # using "script/generate acts_as_xapian" as described in ../README.txt
  class ActsAsXapianJob < ActiveRecord::Base; end

  class <<self
    ######################################################################
    # Module level variables
    # XXX must be some kind of cattr_accessor that can do this better
    def bindings_available
      $acts_as_xapian_bindings_available
    end

    ######################################################################
    # Initialisation
    def init(classname = nil, options = nil)
      # store class and options for use later, when we open the db in readable_init
      @@init_values.push([classname,options]) unless classname.nil?
    end

    # Reads the config file (if any) and sets up the path to the database we'll be using
    def prepare_environment
      return unless @@db_path.nil?

      # barf if we can't figure out the environment
      environment = (ENV['RAILS_ENV'] || RAILS_ENV)
      raise "Set RAILS_ENV, so acts_as_xapian can find the right Xapian database" unless environment

      # check for a config file
      config_file = RAILS_ROOT + "/config/xapian.yml"
      @@config = File.exists?(config_file) ? YAML.load_file(config_file)[environment] : {}

      # figure out where the DBs should go
      if config['base_db_path']
        db_parent_path = File.join(RAILS_ROOT, config['base_db_path'])
      else
        db_parent_path = File.join(File.dirname(__FILE__), '../xapiandbs/')
      end

      # make the directory for the xapian databases to go in
      Dir.mkdir(db_parent_path) unless File.exists?(db_parent_path)

      @@db_path = File.join(db_parent_path, environment)

      # make some things that don't depend on the db
      # XXX this gets made once for each acts_as_xapian. Oh well.
      @@stemmer = Xapian::Stem.new('english')
    end

    # Opens / reopens the db for reading
    # XXX we perhaps don't need to rebuild database and enquire and queryparser -
    # but db.reopen wasn't enough by itself, so just do everything it's easier.
    def readable_init
      raise NoXapianRubyBindingsError.new("Xapian Ruby bindings not installed") unless self.bindings_available
      raise "acts_as_xapian hasn't been called in any models" if @@init_values.empty?

      # if DB is not nil, then we're already initialised, so don't do it again
      # XXX we need to reopen the database each time, so Xapian gets changes to it.
      # Hopefully in later version of Xapian it will autodetect this, and this can
      # be commented back in again.
      # return unless @@db.nil?

      prepare_environment

      # basic Xapian objects
      begin
        @@db = Xapian::Database.new(@@db_path)
        @@enquire = Xapian::Enquire.new(@@db)
      rescue IOError
        raise "Xapian database not opened; have you built it with scripts/rebuild-xapian-index ?"
      end

      init_query_parser
    end

    # Make a new query parser
    def init_query_parser
      # for queries
      @@query_parser = Xapian::QueryParser.new
      @@query_parser.stemmer = @@stemmer
      @@query_parser.stemming_strategy = Xapian::QueryParser::STEM_SOME
      @@query_parser.database = @@db
      @@query_parser.default_op = Xapian::Query::OP_AND

      @@terms_by_capital = {}
      @@values_by_number = {}
      @@values_by_prefix = {}
      @@value_ranges_store = []

      @@init_values.each do |(classname, options)|
        # go through the various field types, and tell query parser about them,
        # and error check them - i.e. check for consistency between models
        @@query_parser.add_boolean_prefix("model", "M")
        @@query_parser.add_boolean_prefix("modelid", "I")
        (options[:terms] || []).each do |term|
          raise "Use up to 3 single capital letters for term code" unless term[1].match(/^[A-Z]{1,3}$/)
          raise "M and I are reserved for use as the model/id term" if term[1] == "M" || term[1] == "I"
          raise "model and modelid are reserved for use as the model/id prefixes" if term[2] == "model" || term[2] == "modelid"
          raise "Z is reserved for stemming terms" if term[1] == "Z"
          raise "Already have code '#{term[1]}' in another model but with different prefix '#{@@terms_by_capital[term[1]]}'" if @@terms_by_capital.key?(term[1]) && @@terms_by_capital[term[1]] != term[2]
          @@terms_by_capital[term[1]] = term[2]
          @@query_parser.add_prefix(term[2], term[1])
        end
        (options[:values] || []).each do |value|
          raise "Value index '#{value[1]}' must be an integer, is #{value[1].class}" unless value[1].instance_of?(Fixnum)
          raise "Already have value index '#{value[1]}' in another model but with different prefix '#{@@values_by_number[value[1]]}'" if @@values_by_number.key?(value[1]) && @@values_by_number[value[1]] != value[2]

          # date types are special, mark them so the first model they're seen for
          if !@@values_by_number.key?(value[1])
            value_range = case value[3]
            when :date
              Xapian::DateValueRangeProcessor.new(value[1])
            when :string
              Xapian::StringValueRangeProcessor.new(value[1])
            when :number
              Xapian::NumberValueRangeProcessor.new(value[1])
            else
              raise "Unknown value type '#{value[3]}'"
            end

            @@query_parser.add_valuerangeprocessor(value_range)

            # stop it being garbage collected, as
            # add_valuerangeprocessor ref is outside Ruby's GC
            @@value_ranges_store.push(value_range)
          end

          @@values_by_number[value[1]] = value[2]
          @@values_by_prefix[value[2]] = value[1]
        end
      end
    end

    def writable_init(suffix = "")
      raise NoXapianRubyBindingsError.new("Xapian Ruby bindings not installed") unless self.bindings_available
      raise "acts_as_xapian hasn't been called in any models" if @@init_values.empty?

      # if DB is not nil, then we're already initialised, so don't do it again
      return unless @@writable_db.nil?

      prepare_environment

      new_path = @@db_path + suffix
      raise "writable_suffix/suffix inconsistency" if @@writable_suffix && @@writable_suffix != suffix

      # for indexing
      @@writable_db = Xapian::WritableDatabase.new(new_path, Xapian::DB_CREATE_OR_OPEN)
      @@term_generator = Xapian::TermGenerator.new()
      @@term_generator.set_flags(Xapian::TermGenerator::FLAG_SPELLING, 0)
      @@term_generator.database = @@writable_db
      @@term_generator.stemmer = @@stemmer
      @@writable_suffix = suffix
    end

    ######################################################################
    # Index

    # Update index with any changes needed, call this offline. Only call it
    # from a script that exits - otherwise Xapian's writable database won't
    # flush your changes. Specifying flush will reduce performance, but
    # make sure that each index update is definitely saved to disk before
    # logging in the database that it has been.
    def update_index(flush = false, verbose = false)
      # puts "start of self.update_index" if verbose

      # Before calling writable_init we have to make sure every model class has been initialized.
      # i.e. has had its class code loaded, so acts_as_xapian has been called inside it, and
      # we have the info from acts_as_xapian.
      model_classes = ActsAsXapianJob.find_by_sql("select model from acts_as_xapian_jobs group by model").map {|a| a.model.constantize }
      # If there are no models in the queue, then nothing to do
      return if model_classes.empty?

      self.writable_init

      ids_to_refresh = ActsAsXapianJob.find(:all, :select => 'id').map { |i| i.id }
      ids_to_refresh.each do |id|
        begin
          ActsAsXapianJob.transaction do
            job = ActsAsXapianJob.find(id, :lock =>true)
            puts "ActsAsXapian.update_index #{job.action} #{job.model} #{job.model_id.to_s}" if verbose
            begin
              case job.action
              when 'update'
                # XXX Index functions may reference other models, so we could eager load here too?
                model = job.model.constantize.find(job.model_id) # :include => cls.constantize.xapian_options[:include]
                model.xapian_index
              when 'destroy'
                # Make dummy model with right id, just for destruction
                model = job.model.constantize.new
                model.id = job.model_id
                model.xapian_destroy
              else
                raise "unknown ActsAsXapianJob action '#{job.action}'"
              end
            rescue ActiveRecord::RecordNotFound => e
              job.action = 'destroy'
              retry
            end
            job.destroy

            self.writable_db.flush if flush
          end
        rescue => detail
          # print any error, and carry on so other things are indexed
          # XXX If item is later deleted, this should give up, and it
          # won't. It will keep trying (assuming update_index called from
          # regular cron job) and mayhap cause trouble.
          STDERR.puts("#{detail.backtrace.join("\n")}\nFAILED ActsAsXapian.update_index job #{id} #{$!}")
        end
      end
    end

    # You must specify *all* the models here, this totally rebuilds the Xapian database.
    # You'll want any readers to reopen the database after this.
    def rebuild_index(model_classes, verbose = false)
      raise "when rebuilding all, please call as first and only thing done in process / task" unless self.writable_db.nil?

      prepare_environment

      # Delete any existing .new database, and open a new one
      new_path = "#{self.db_path}.new"
      if File.exist?(new_path)
        raise "found existing #{new_path} which is not Xapian flint database, please delete for me" unless File.exist?(File.join(new_path, "iamflint"))
        FileUtils.rm_r(new_path)
      end
      self.writable_init(".new")

      # Index everything
      # XXX not a good place to do this destroy, as unindexed list is lost if
      # process is aborted and old database carries on being used. Perhaps do in
      # transaction and commit after rename below? Not sure if thenlocking is then bad
      # for live website running at same time.

      ActsAsXapianJob.destroy_all
      batch_size = 1000
      model_classes.each do |model_class|
        model_class.transaction do
          0.step(model_class.count, batch_size) do |i|
            puts "ActsAsXapian: New batch. From #{i} to #{i + batch_size}" if verbose
            models = model_class.find(:all, :limit => batch_size, :offset => i, :order => :id)
            models.each do |model|
              puts "ActsAsXapian.rebuild_index #{model_class} #{model.id}" if verbose
              model.xapian_index
            end
          end
        end
      end

      self.writable_db.flush

      # Rename into place
      old_path = self.db_path
      temp_path = "#{old_path}.tmp"
      if File.exist?(temp_path)
        raise "temporary database found #{temp_path} which is not Xapian flint database, please delete for me" unless File.exist?(File.join(temp_path, "iamflint"))
        FileUtils.rm_r(temp_path)
      end
      FileUtils.mv(old_path, temp_path) if File.exist?(old_path)
      FileUtils.mv(new_path, old_path)

      # Delete old database
      if File.exist?(temp_path)
        raise "old database now at #{temp_path} is not Xapian flint database, please delete for me" unless File.exist?(File.join(temp_path, "iamflint"))
        FileUtils.rm_r(temp_path)
      end

      # You'll want to restart your FastCGI or Mongrel processes after this,
      # so they get the new db
    end
  end

  ######################################################################
  # Main entry point, add acts_as_xapian to your model.

  module ActsMethods
    # See top of this file for docs
    def acts_as_xapian(options)
      # Give error only on queries if bindings not available
      return unless ActsAsXapian.bindings_available

      include InstanceMethods
      extend ClassMethods

      # extend has_many && has_many_and_belongs_to associations with our ProxyFinder to get scoped results
      # I've written a small report in the discussion group why this is the proper way of doing this.
      # see here: XXX - write it you lazy douche bag!
      self.reflections.each do |association_name, r|
        # skip if the associated model isn't indexed by acts_as_xapian
        next unless r.klass.respond_to?(:xapian?) && r.klass.xapian?
        # skip all associations except ham and habtm
        next unless [:has_many, :has_many_and_belongs_to_many].include?(r.macro)

        # XXX todo:
        # extend the associated model xapian options with this term:
        # [proxy_reflection.primary_key_name.to_sym, <magically find a free capital letter>, proxy_reflection.primary_key_name]
        # otherways this assumes that the associated & indexed model indexes this kind of term

        # but before you do the above, rewrite the options syntax... wich imho is actually very ugly

        # XXX test this nifty feature on habtm!

        if r.options[:extend].nil?
          r.options[:extend] = [ProxyFinder]
        elsif !r.options[:extend].include?(ProxyFinder)
          r.options[:extend] << ProxyFinder
        end
      end

      cattr_accessor :xapian_options
      self.xapian_options = options

      ActsAsXapian.init(self.class.to_s, options)

      after_save :xapian_mark_needs_index
      after_destroy :xapian_mark_needs_destroy
    end
  end

  module ClassMethods
    # Model.find_with_xapian("Search Term OR Phrase")
    # => Array of Records
    #
    # this can be used through association proxies /!\ DANGEROUS MAGIC /!\
    # example:
    # @document = Document.find(params[:id])
    # @document_pages = @document.pages.find_with_xapian("Search Term OR Phrase").compact # NOTE THE compact wich removes nil objects from the array
    #
    # as seen here: http://pastie.org/270114
    def find_with_xapian(search_term, options = {})
      search_with_xapian(search_term, options).results.map {|x| x[:model] }
    end

    def search_with_xapian(search_term, options = {})
      ActsAsXapian::Search.new([self], search_term, options)
    end

    #this method should return true if the integration of xapian on self is complete
    def xapian?
      self.included_modules.include?(InstanceMethods) && self.extended_by.include?(ClassMethods)
    end
  end

  ######################################################################
  # Instance methods that get injected into your model.

  module InstanceMethods
    # Used internally
    def xapian_document_term
      "#{self.class}-#{self.id}"
    end

    # Extract value of a field from the model
    def xapian_value(field, type = nil)
      value = self[field] || self.send(field.to_sym)
      case type
      when :date
        value = value.to_time if value.kind_of?(Date)
        raise "Only Time or Date types supported by acts_as_xapian for :date fields, got #{value.class}" unless value.kind_of?(Time)
        value.utc.strftime("%Y%m%d")
      when :boolean
        value ? true : false
      else
        value.to_s
      end
    end

    # Store record in the Xapian database
    def xapian_index
      # if we have a conditional function for indexing, call it and destory object if failed
      if self.class.xapian_options.key?(:if) && !xapian_value(self.class.xapian_options[:if], :boolean)
        self.xapian_destroy
        return
      end

      # otherwise (re)write the Xapian record for the object
      doc = Xapian::Document.new
      ActsAsXapian.term_generator.document = doc

      doc.data = self.xapian_document_term

      doc.add_term("M#{self.class}")
      doc.add_term("I#{doc.data}")
      (self.xapian_options[:terms] || []).each do |term|
        ActsAsXapian.term_generator.increase_termpos # stop phrases spanning different text fields
        ActsAsXapian.term_generator.index_text(xapian_value(term[0]), 1, term[1])
      end
      (self.xapian_options[:values] || []).each {|value| doc.add_value(value[1], xapian_value(value[0], value[3])) }
      (self.xapian_options[:texts] || []).each do |text|
        ActsAsXapian.term_generator.increase_termpos # stop phrases spanning different text fields
        # XXX the "1" here is a weight that could be varied for a boost function
        ActsAsXapian.term_generator.index_text(xapian_value(text), 1)
      end

      ActsAsXapian.writable_db.replace_document("I#{doc.data}", doc)
    end

    # Delete record from the Xapian database
    def xapian_destroy
      ActsAsXapian.writable_db.delete_document("I#{self.xapian_document_term}")
    end

    # Used to mark changes needed by batch indexer
    def xapian_mark_needs_index
      model = self.class.base_class.to_s
      model_id = self.id
      ActiveRecord::Base.transaction do
        found = ActsAsXapianJob.delete_all(["model = ? and model_id = ?", model, model_id])
        job = ActsAsXapianJob.new
        job.model = model
        job.model_id = model_id
        job.action = 'update'
        job.save!
      end
    end

    def xapian_mark_needs_destroy
      model = self.class.base_class.to_s
      model_id = self.id
      ActiveRecord::Base.transaction do
        found = ActsAsXapianJob.delete_all(["model = ? and model_id = ?", model, model_id])
        job = ActsAsXapianJob.new
        job.model = model
        job.model_id = model_id
        job.action = 'destroy'
        job.save!
      end
    end
  end

  module ProxyFinder
    def find_with_xapian(search_term, options = {})
      search_with_xapian(search_term, options).results.map {|x| x[:model] }
    end

    def search_with_xapian(search_term, options = {})
      ActsAsXapian::Search.new([proxy_reflection.klass], "#{proxy_reflection.primary_key_name}:#{proxy_owner.id} #{search_term}", options)
    end
  end
end

# Reopen ActiveRecord and include the acts_as_xapian method
ActiveRecord::Base.extend ActsAsXapian::ActsMethods


