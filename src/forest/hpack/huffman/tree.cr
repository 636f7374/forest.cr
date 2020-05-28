module Forest::Hpack
  class Huffman
    class Node
      property left : Node?
      property right : Node?
      property value : UInt8?

      # left: Bit0, right: Bit1
      def initialize(@left : Node? = nil, @right : Node? = nil, @value : UInt8? = nil)
      end

      def leaf?
        left.nil? && right.nil?
      end

      def add(binary : Int32, length : Int32, value : UInt8)
        node = self

        (length - 1_i32).downto 0_i32 do |item|
          next node = node.right ||= Node.new if 1_i32 == binary.bit(item)
          node = node.left ||= Node.new
        end

        node.value = value
        node
      end
    end
  end
end
