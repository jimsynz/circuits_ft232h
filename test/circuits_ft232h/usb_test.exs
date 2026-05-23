defmodule CircuitsFT232H.USBTest do
  use ExUnit.Case, async: true

  alias CircuitsFT232H.USB

  describe "strip_status/2" do
    test "returns empty for empty input" do
      assert USB.strip_status(<<>>, 512) == <<>>
    end

    test "returns empty when only the modem-status bytes are present" do
      assert USB.strip_status(<<0x31, 0x60>>, 512) == <<>>
    end

    test "strips the leading 2 status bytes from a single short packet" do
      packet = <<0x31, 0x60, 0xFA, 0xAB>>
      assert USB.strip_status(packet, 512) == <<0xFA, 0xAB>>
    end

    test "strips status from a single full packet" do
      payload = :binary.copy(<<0xAA>>, 510)
      packet = <<0x31, 0x60, payload::binary>>
      assert byte_size(packet) == 512
      assert USB.strip_status(packet, 512) == payload
    end

    test "strips status from multiple back-to-back full packets" do
      payload_a = :binary.copy(<<0xAA>>, 510)
      payload_b = :binary.copy(<<0xBB>>, 510)
      data = <<0x31, 0x60, payload_a::binary, 0x31, 0x60, payload_b::binary>>
      assert USB.strip_status(data, 512) == <<payload_a::binary, payload_b::binary>>
    end

    test "strips status from a full packet followed by a short tail" do
      payload_a = :binary.copy(<<0xAA>>, 510)
      tail = <<0xDE, 0xAD, 0xBE, 0xEF>>
      data = <<0x31, 0x60, payload_a::binary, 0x31, 0x60, tail::binary>>
      assert USB.strip_status(data, 512) == <<payload_a::binary, tail::binary>>
    end

    test "respects a 64-byte (full-speed) packet size" do
      payload_a = :binary.copy(<<0x11>>, 62)
      payload_b = <<0x99>>
      data = <<0x31, 0x60, payload_a::binary, 0x31, 0x60, payload_b::binary>>
      assert USB.strip_status(data, 64) == <<payload_a::binary, payload_b::binary>>
    end
  end
end
