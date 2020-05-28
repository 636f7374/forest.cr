class Forest::Entry
  property wrapped : IO
  property flowControl : FlowControl
  property cellWriter : Cell::Writer
  property connectionPool : ConnectionPool
  property finished : Bool

  def initialize(@wrapped : IO, @flowControl : FlowControl = FlowControl.new)
    @cellWriter = Cell::Writer.new io: wrapped, flowControl: flowControl
    @connectionPool = ConnectionPool.new flowControl: flowControl
    @finished = false
  end

  def finished?
    @finished
  end
end
