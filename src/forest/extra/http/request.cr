# Commits on May 11, 2020

class HTTP::Request
  private def self.parse_request_line(slice : Bytes) : RequestLine | HTTP::Status
    space_index = slice.index ' '.ord.to_u8

    # Oops, only a single part (should be three)
    return HTTP::Status::BAD_REQUEST unless space_index

    subslice = slice[0_i32...space_index]

    # Optimization: see if it's one of the common methods
    # (avoids a string allocation for these methods)
    method = METHODS.find { |method| method.to_slice == subslice } || String.new subslice

    # Skip spaces.
    # The RFC just mentions a single space but most servers allow multiple.
    while space_index < slice.size && slice[space_index] == ' '.ord.to_u8
      space_index += 1_i32
    end

    # Oops, we only found the "method" part followed by spaces
    return HTTP::Status::BAD_REQUEST if space_index == slice.size

    next_space_index = slice.index ' '.ord.to_u8, offset: space_index

    # Oops, we only found two parts (should be three)
    return HTTP::Status::BAD_REQUEST unless next_space_index

    resource = String.new slice[space_index...next_space_index]

    # Skip spaces again
    space_index = next_space_index
    while space_index < slice.size && slice[space_index] == ' '.ord.to_u8
      space_index += 1_i32
    end

    next_space_index = slice.index(' '.ord.to_u8, offset: space_index) || slice.size

    subslice = slice[space_index...next_space_index]

    # Optimization: avoid allocating a string for common HTTP version
    http_version = HTTP::SUPPORTED_VERSIONS_.find { |version| version.to_slice == subslice }
    return HTTP::Status::BAD_REQUEST unless http_version

    # Skip trailing spaces
    space_index = next_space_index
    while space_index < slice.size
      # Oops, we find something else (more than three parts)
      return HTTP::Status::BAD_REQUEST unless slice[space_index] == ' '.ord.to_u8
      space_index += 1_i32
    end

    RequestLine.new method: method, resource: resource, http_version: http_version
  end

  def host
    host = version == "HTTP/2.0" ? @headers[":authority"]? : @headers["Host"]?
    return unless host

    index = host.index ":"
    index ? host[0_i32...index] : host
  end

  def host_with_port
    version == "HTTP/2.0" ? @headers[":authority"]? : @headers["Host"]?
  end
end
