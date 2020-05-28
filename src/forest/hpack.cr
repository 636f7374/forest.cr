module Forest::Hpack
  class Error < Exception
  end
end

require "./slice_reader.cr"
require "./hpack/*"
