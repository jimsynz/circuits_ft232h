defmodule CircuitsFT232H.USBTest do
  use ExUnit.Case, async: true

  alias CircuitsFT232H.USB

  describe "decode_string_descriptor/1" do
    test "decodes a well-formed UTF-16LE string descriptor" do
      # Header: length=14, type=0x03; payload: "FT232H" in UTF-16LE
      utf16 = :unicode.characters_to_binary("FT232H", :utf8, {:utf16, :little})
      raw = <<byte_size(utf16) + 2, 0x03, utf16::binary>>

      assert {:ok, "FT232H"} = USB.decode_string_descriptor(raw)
    end

    test "ignores trailing bytes past the declared length" do
      utf16 = :unicode.characters_to_binary("AB", :utf8, {:utf16, :little})
      raw = <<6, 0x03, utf16::binary, 0xFF, 0xFF, 0xFF>>

      assert {:ok, "AB"} = USB.decode_string_descriptor(raw)
    end

    test "decodes an empty string when length is 2" do
      assert {:ok, ""} = USB.decode_string_descriptor(<<2, 0x03>>)
    end

    test "rejects descriptors that aren't a string-descriptor type" do
      # type byte 0x01 = DEVICE descriptor, not 0x03
      assert {:error, :invalid_descriptor} = USB.decode_string_descriptor(<<4, 0x01, 0x09, 0x04>>)
    end

    test "rejects 0xFF-filled garbage from an unprogrammed EEPROM" do
      assert {:error, :invalid_descriptor} =
               USB.decode_string_descriptor(:binary.copy(<<0xFF>>, 18))
    end

    test "rejects descriptors shorter than the declared length" do
      assert {:error, :invalid_descriptor} =
               USB.decode_string_descriptor(<<10, 0x03, 0x41, 0x00>>)
    end

    test "rejects empty input" do
      assert {:error, :invalid_descriptor} = USB.decode_string_descriptor(<<>>)
    end
  end

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
