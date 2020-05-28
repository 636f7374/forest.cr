module Forest::Hpack
  class Encoder
    enum Indexing : UInt8
      Indexed = 128_u8
      Always  =  64_u8
      Never   =  16_u8
      None    =   0_u8
    end

    property defaultIndexing : Indexing
    property defaultHuffman : Bool
    property tableCapacity : Int32
    property dynamicTable : DynamicTable

    def initialize(@defaultIndexing : Indexing = Indexing::None, @defaultHuffman : Bool = false, @tableCapacity : Int32 = 4096_i32)
      @dynamicTable = DynamicTable.new tableCapacity
    end

    def encode(writer : IO = IO::Memory.new, headers : HTTP::Headers = HTTP::Headers.new, indexing : Indexing = self.defaultIndexing,
               huffman : Bool = self.defaultHuffman)
      headers.each { |name, values| encode writer, name.downcase, values, indexing, huffman if name.starts_with? ':' }
      headers.each { |name, values| encode writer, name.downcase, values, indexing, huffman unless name.starts_with? ':' }

      writer.to_slice
    end

    def encode(writer : IO, name : String, values : String | Array(String), indexing : Indexing, huffman : Bool)
      values.each do |value|
        unless header = indexed name, value
          dynamicTable.add name, value if indexing.always?
          writer.write_byte indexing.value

          string writer, name, huffman
          string writer, value, huffman

          next
        end

        next integer writer, header.first, 7_i32, prefix: Indexing::Indexed if header.last

        case indexing
        when .always?
          integer writer, header.first, 6_i32, prefix: indexing
          string writer, value, huffman

          dynamicTable.add name, value
        else
          integer writer, header.first, 4_i32, prefix: Indexing::None
          string writer, value, huffman
        end
      end
    end

    # Optimize: Use a cached {name => {value => index}} struct (?)

    protected def indexed(name : String, value : String) : Tuple(Int32, String?)?
      idx = nil

      StaticTable::VALUE.each_with_index do |header, index|
        next unless header[0_i32] == name
        return Tuple.new index + 1_i32, value if header[1_i32] == value

        idx ||= index + 1_i32
      end

      dynamicTable.each_with_index do |header, index|
        next unless header[0_i32] == name
        next unless header[1_i32] == value

        return Tuple.new index + StaticTable::SIZE + 1_i32, value
      end

      Tuple.new idx, nil if idx
    end

    protected def integer(writer : IO, integer : Int32, n : Int, prefix : Indexing = Indexing::None)
      n2 = 2_i32 ** n - 1_i32

      if integer < n2
        writer.write_byte integer.to_u8 | prefix.to_u8

        return
      end

      writer.write_byte n2.to_u8 | prefix.to_u8
      integer -= n2

      while integer >= 128_i32
        writer.write_byte ((integer % 128_i32) + 128_i32).to_u8
        integer /= 128_i32
      end

      writer.write_byte integer.to_u8
    end

    protected def string(writer : IO, string : String, huffman : Bool = false)
      if huffman
        encoded = Hpack::Huffman.huffman.encode string
        integer writer, encoded.size, 7_i32, prefix: Indexing::Indexed

        writer.write encoded

        return
      end

      integer writer, string.bytesize, 7_i32
      writer << string
    end
  end
end
