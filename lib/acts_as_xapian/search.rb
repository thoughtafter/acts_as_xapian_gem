module ActsAsXapian
  # Search for a query string, returns an array of hashes in result order.
  # Each hash contains the actual Rails object in :model, and other detail
  # about relevancy etc. in other keys.
  class Search < QueryBase
    attr_accessor :query_string

    # Note that model_classes is not only sometimes useful here - it's
    # essential to make sure the classes have been loaded, and thus
    # acts_as_xapian called on them, so we know the fields for the query
    # parser.

    # model_classes - model classes to search within, e.g. [PublicBody,
    # User]. Can take a single model class, or you can express the model
    # class names in strings if you like.
    # query_string - user inputed query string, with syntax much like Google Search
    def initialize(model_classes, query_string, options = {})
      # Check parameters, convert to actual array of model classes
      new_model_classes = []
      model_classes = [model_classes] if model_classes.class != Array
      model_classes.each do |model_class|
        raise "pass in the model class itself, or a string containing its name" if model_class.class != Class && model_class.class != String
        model_class = model_class.constantize if model_class.class == String
        new_model_classes.push(model_class)
      end
      model_classes = new_model_classes

      # Set things up
      self.initialize_db

      # Case of a string, searching for a Google-like syntax query
      self.query_string = query_string

      # Construct query which only finds things from specified models
      model_query = Xapian::Query.new(Xapian::Query::OP_OR, model_classes.map {|mc| "M#{mc}" })
      user_query = ActsAsXapian.query_parser.parse_query(self.query_string,
            Xapian::QueryParser::FLAG_BOOLEAN | Xapian::QueryParser::FLAG_PHRASE |
            Xapian::QueryParser::FLAG_LOVEHATE | Xapian::QueryParser::FLAG_WILDCARD |
            Xapian::QueryParser::FLAG_SPELLING_CORRECTION)
      self.query = Xapian::Query.new(Xapian::Query::OP_AND, model_query, user_query)

      # Call base class constructor
      self.initialize_query(options)
    end

    # Return just normal words in the query i.e. Not operators, ones in
    # date ranges or similar. Use this for cheap highlighting with
    # TextHelper::highlight, and excerpt.
    def words_to_highlight
      query_nopunc = self.query_string.gsub(/[^\w:\.\/_]/i, " ")
      query_nopunc = query_nopunc.gsub(/\s+/, " ")
      words = query_nopunc.split(" ")
      # Remove anything with a :, . or / in it
      words = words.find_all {|o| !o.match(/(:|\.|\/)/) }
      words = words.find_all {|o| !o.match(/^(AND|NOT|OR|XOR)$/) }
      words
    end

    # Text for lines in log file
    def log_description
      "Search: #{self.query_string}"
    end
  end
end
