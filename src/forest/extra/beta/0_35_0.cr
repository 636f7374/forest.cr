class HTTP::Server
  def bind_tls(host : String, port : Int32, context : OpenSSL::SSL::Context::Server, reuse_port : Bool = false) : Socket::IPAddress
    tcp_server = TCPServer.new(host, port, reuse_port: reuse_port)
    server = OpenSSL::SSL::Server.new(tcp_server, context)
    server.start_immediately = false

    begin
      bind(server)
    rescue exc
      server.close
      raise exc
    end

    tcp_server.local_address
  end

  private def handle_client(io : IO)
    io.read_timeout = 5_i32 if io.responds_to? :read_timeout=
    io.write_timeout = 5_i32 if io.responds_to? :write_timeout=

    if io.is_a?(IO::Buffered)
      io.sync = false
    end

    {% unless flag?(:without_openssl) %}
      if io.is_a?(OpenSSL::SSL::Socket::Server)
        begin
          io.accept
        rescue ex
          return
        end
      end
    {% end %}

    @processor.process(io, io)
  end
end

class OpenSSL::SSL::Server
  property start_immediately : Bool = true

  # Implements `::Socket::Server#accept`.
  #
  # This method calls `@wrapped.accept` and wraps the resulting IO in a SSL socket (`OpenSSL::SSL::Socket::Server`) with `context` configuration.
  def accept : OpenSSL::SSL::Socket::Server
    new_ssl_socket(@wrapped.accept)
  end

  # Implements `::Socket::Server#accept?`.
  #
  # This method calls `@wrapped.accept?` and wraps the resulting IO in a SSL socket (`OpenSSL::SSL::Socket::Server`) with `context` configuration.
  def accept? : OpenSSL::SSL::Socket::Server?
    if socket = @wrapped.accept?
      new_ssl_socket(socket)
    end
  end

  private def new_ssl_socket(io)
    OpenSSL::SSL::Socket::Server.new(io, @context, sync_close: @sync_close, accept: @start_immediately)
  end
end

abstract class OpenSSL::SSL::Socket < IO
  class Server < Socket
    def initialize(io, context : Context::Server = Context::Server.new,
                   sync_close : Bool = false, accept : Bool = true)
      super(io, context, sync_close)

      if accept
        begin
          self.accept
        rescue ex
          LibSSL.ssl_free(@ssl) # GC never calls finalize, avoid mem leak
          raise ex
        end
      end
    end

    def accept
      ret = LibSSL.ssl_accept(@ssl)
      unless ret == 1
        @bio.io.close if @sync_close
        raise OpenSSL::SSL::Error.new(@ssl, ret, "SSL_accept")
      end
    end
  end
end
