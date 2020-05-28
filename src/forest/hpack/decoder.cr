module Forest::Hpack
  class Decoder
    property dynamicTable : DynamicTable

    def initialize(@dynamicTable : DynamicTable)
    end

    def self.new(table_capacity : Int32 = 4096_i32)
      new DynamicTable.new table_capacity
    end

    private def slice_reader=(value : SliceReader)
      @sliceReader = value
    end

    def slice_reader
      @sliceReader
    end

    def self.decode(bytes : Bytes, headers : HTTP::Headers = HTTP::Headers.new, table_capacity : Int32 = 4096_i32)
      decoder = new table_capacity
      decoder.decode bytes, headers
    end

    def decode(bytes : Bytes, headers : HTTP::Headers = HTTP::Headers.new)
      self.slice_reader = slice_reader = SliceReader.new bytes
      decoded_common_headers = false

      begin
        until slice_reader.done?
          if 1_i32 == slice_reader.current_byte.bit(7_i32)
            # 1.......  Indexed

            index = integer 7_i32
            raise Error.new "Invalid index: 0" if index.zero?

            name, value = indexed index
          elsif 1_i32 == slice_reader.current_byte.bit(6_i32)
            # 01......  Literal with incremental indexing

            index = integer 6_i32
            name = index.zero? ? string : indexed(index).first
            value = string

            dynamicTable.add name, value
          elsif 1_i32 == slice_reader.current_byte.bit(5_i32)
            # 001.....  Table max size update

            raise Error.new "Unexpected dynamic table size update" if decoded_common_headers

            new_size = integer 5_i32

            if new_size > dynamicTable.capacity
              raise Error.new "Dynamic table size update is larger than SETTINGS_HEADER_TABLE_SIZE"
            end

            dynamicTable.resize new_size

            next
          elsif 1_i32 == slice_reader.current_byte.bit 4_i32
            # 0001....  Literal never indexed
            # Todo: Retain the never_indexed property

            index = integer 4_i32
            name = index.zero? ? string : indexed(index).first

            value = string
          else
            # 0000....  Literal without indexing

            index = integer 4_i32
            name = index.zero? ? string : indexed(index).first

            value = string
          end

          decoded_common_headers = 0_i32 < index < StaticTable::SIZE
          headers.add name, value
        end

        headers
      rescue ex : IndexError
        raise Error.new "Invalid compression"
      end
    end

    protected def indexed(index : Int)
      return StaticTable::VALUE[index - 1_i32] if 0_i32 < index < StaticTable::SIZE

      header = dynamicTable[index - StaticTable::SIZE - 1_i32]?
      return header if header

      raise Error.new String.build { |io| io << "Invalid index: " << index }
    end

    protected def integer(n : Int) : Int32
      raise Error.new "Missing SliceReader" unless _slice_reader = self.slice_reader
      integer = (_slice_reader.read_byte & (0xff_i32 >> (8_i32 - n))).to_i

      n2 = 2_i32 ** n - 1_i32
      return integer if integer < n2

      m = 0_i32

      loop do
        # Todo: Raise if integer grows over limit

        byte = _slice_reader.read_byte
        integer += (byte & 127_i32).to_i * (2_i32 ** (m * 7_i32))
        break unless byte & 128_i32 == 128_i32

        m += 1_i32
      end

      integer
    end

    protected def string : String
      raise Error.new "Missing SliceReader" unless _slice_reader = self.slice_reader

      huffman = 1_i32 == _slice_reader.current_byte.bit(7_i32)
      length = integer 7_i32
      bytes = _slice_reader.read length

      huffman ? Hpack::Huffman.huffman.decode(bytes) : String.new(bytes)
    end
  end
end
