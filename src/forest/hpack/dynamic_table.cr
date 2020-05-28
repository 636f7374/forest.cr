module Forest::Hpack
  class DynamicTable
    property capacity : Int32
    property byteSize : Int32
    property storage : Array(Tuple(String, String))

    # property storage : Immutable::Vector(Tuple(String, String))

    def initialize(@capacity : Int32, @byteSize : Int32 = 0_i32)
      @storage = [] of Tuple(String, String)
      @mutex = Mutex.new :unchecked
    end

    def add(name : String, value : String)
      @mutex.synchronize do
        header = Tuple.new name, value

        # self.storage =
        storage.unshift header
        self.byteSize += count header
        cleanup
      end

      nil
    end

    def [](index : Int)
      storage[index]
    end

    def []?(index : Int)
      storage[index]?
    end

    def each
      storage.each { |header, index| yield header, index }
    end

    def each_with_index
      storage.each_with_index { |header, index| yield header, index }
    end

    def size
      storage.size
    end

    def empty?
      storage.empty?
    end

    def resize(capacity : Int32)
      @mutex.synchronize do
        self.capacity = capacity
        cleanup
      end

      nil
    end

    private def cleanup
      while byteSize > capacity
        # item, _storage =

        # self.storage = _storage
        item = storage.pop
        self.byteSize -= count item
      end
    end

    private def count(header : Tuple(String, String))
      header[0_i32].bytesize + header[1_i32].bytesize + 32_i32
    end
  end
end
