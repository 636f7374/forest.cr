class Forest::ConnectionPool
  property flowControl : FlowControl
  property storage : Hash(Int32, Channel(Frame))
  property mutex : Mutex

  def initialize(@flowControl : FlowControl)
    @storage = Hash(Int32, Channel(Frame)).new
    @mutex = Mutex.new :unchecked
  end

  def concurrent_full?
    actives = storage.count { |stream_identifier, channel| !channel.closed? }
    flowControl.max_concurrent_streams <= actives
  end

  def add(stream_identifier : Int32, channel : Channel(Frame))
    return if storage[stream_identifier]?

    @mutex.synchronize do
      storage[stream_identifier] = channel
    end
  end

  def delete(stream_identifier : Int32)
    return unless channel = storage[stream_identifier]?
    return unless channel.closed?

    delete! stream_identifier
  end

  def delete!(stream_identifier : Int32)
    @mutex.synchronize do
      storage.delete stream_identifier
    end
  end

  def get(stream_identifier : Int32)
    storage[stream_identifier]
  end

  def get?(stream_identifier : Int32)
    storage[stream_identifier]?
  end

  def [](stream_identifier : Int32)
    storage[stream_identifier]
  end

  def []?(stream_identifier : Int32)
    storage[stream_identifier]?
  end

  def each(&block : Int32, Channel(Frame) ->)
    storage.each { |stream_identifier, channel| yield stream_identifier, channel }
  end
end
