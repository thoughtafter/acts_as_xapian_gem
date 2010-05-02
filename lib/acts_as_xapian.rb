%w(base query_base search similar index writable_index readable_index core_ext/array).each do |file|
	require File.join(File.dirname(__FILE__), 'acts_as_xapian', file)
end