module ActsAsXapian
  # Base class for Search and Similar below
  class QueryBase
    attr_accessor :offset
    attr_accessor :limit
    attr_accessor :query
    attr_accessor :matches
    attr_accessor :query_models
    attr_accessor :runtime
    attr_accessor :cached_results

    def initialize_db
      self.runtime = 0.0

      ActsAsXapian.readable_init

      raise "ActsAsXapian not initialized" if ActsAsXapian.db.nil?
    end

    # Set self.query before calling this
    def initialize_query(options)
      #raise options.to_yaml

      self.runtime += Benchmark::realtime do
        offset = options[:offset] || 0; offset = offset.to_i
        @limit = (options[:limit] || -1).to_i
        sort_by_prefix = options[:sort_by_prefix] || nil
        sort_by_ascending = options[:sort_by_ascending].nil? ? true : options[:sort_by_ascending]
        collapse_by_prefix = options[:collapse_by_prefix] || nil

        ActsAsXapian.enquire.query = self.query

        if sort_by_prefix.nil?
          ActsAsXapian.enquire.sort_by_relevance!
        else
          value = ActsAsXapian.values_by_prefix[sort_by_prefix]
          raise "couldn't find prefix '#{sort_by_prefix}'" if value.nil?
          ActsAsXapian.enquire.sort_by_value_then_relevance!(value, sort_by_ascending)
        end
        if collapse_by_prefix.nil?
          ActsAsXapian.enquire.collapse_key = Xapian.BAD_VALUENO
        else
          value = ActsAsXapian.values_by_prefix[collapse_by_prefix]
          raise "couldn't find prefix '#{collapse_by_prefix}'" if value.nil?
          ActsAsXapian.enquire.collapse_key = value
        end

        self.matches = ActsAsXapian.enquire.mset(offset, @limit, 100)
        self.cached_results = nil
      end
    end

    # Return a description of the query
    def description
      self.query.description
    end

    # Estimate total number of results
    def matches_estimated
      self.matches.matches_estimated
    end

    # Return query string with spelling correction
    def spelling_correction
      correction = ActsAsXapian.query_parser.get_corrected_query_string
      correction.empty? ? nil : correction
    end

    # Return array of models found
    def results
      # If they've already pulled out the results, just return them.
      return self.cached_results unless self.cached_results.nil?

      docs = []
      self.runtime += Benchmark::realtime do
        # Pull out all the results
        iter = self.matches._begin
        while !iter.equals(self.matches._end)
          docs.push({:data => iter.document.data,
                  :percent => iter.percent,
                  :weight => iter.weight,
                  :collapse_count => iter.collapse_count})
          iter.next
        end
      end

      # Log time taken, excluding database lookups below which will be displayed separately by ActiveRecord
      if ActiveRecord::Base.logger
        ActiveRecord::Base.logger.debug("  Xapian query (%.5fs) #{self.log_description}" % self.runtime)
      end

      # Look up without too many SQL queries
      lhash = {}
      lhash.default = []
      docs.each do |doc|
        k = doc[:data].split('-')
        lhash[k[0]] = lhash[k[0]] + [k[1]]
      end
      # for each class, look up all ids
      chash = {}
      lhash.each_pair do |cls, ids|
        joins = "INNER JOIN (select #{ids.first} as id #{ids[1..-1].map {|i| "union all select #{i.to_s} "} * ' '}) AS x ON #{cls.constantize.table_name}.#{cls.constantize.primary_key} = x.id"
        found = cls.constantize.find(:all, :joins => joins, :include => cls.constantize.xapian_options[:eager_load])
        found.each {|f| chash[[cls, f.id]] = f }
      end
      # now get them in right order again
      results = []
      docs.each {|doc| k = doc[:data].split('-'); results << { :model => chash[[k[0], k[1].to_i]],
              :percent => doc[:percent], :weight => doc[:weight], :collapse_count => doc[:collapse_count] } }
      self.cached_results = results
    end
  end
end
