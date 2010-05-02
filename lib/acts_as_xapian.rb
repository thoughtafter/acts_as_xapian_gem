%w(base query_base search similar index writeable_index readable_index).each do |file|
	require File.join(File.dirname(__FILE__), 'acts_as_xapian', file)
end
require File.join(File.dirname(__FILE__), 'acts_as_xapian', 'core_ext', 'array')