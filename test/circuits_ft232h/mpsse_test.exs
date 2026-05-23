defmodule CircuitsFT232H.MPSSETest do
  use ExUnit.Case, async: true

  alias CircuitsFT232H.MPSSE

  describe "GPIO opcodes" do
    test "set_bits_low/2 emits opcode 0x80 with value and direction" do
      assert MPSSE.set_bits_low(0x03, 0x0B) == <<0x80, 0x03, 0x0B>>
    end

    test "set_bits_high/2 emits opcode 0x82 with value and direction" do
      assert MPSSE.set_bits_high(0xAA, 0xFF) == <<0x82, 0xAA, 0xFF>>
    end

    test "get_bits_low/0 and get_bits_high/0 emit one-byte queries" do
      assert MPSSE.get_bits_low() == <<0x81>>
      assert MPSSE.get_bits_high() == <<0x83>>
    end
  end

  describe "clock opcodes" do
    test "disable_clock_divide_by_5/0 selects the 60 MHz base" do
      assert MPSSE.disable_clock_divide_by_5() == <<0x8A>>
    end

    test "enable_clock_divide_by_5/0 selects the 12 MHz base" do
      assert MPSSE.enable_clock_divide_by_5() == <<0x8B>>
    end

    test "enable_3_phase_clocking/0 and disable_3_phase_clocking/0" do
      assert MPSSE.enable_3_phase_clocking() == <<0x8C>>
      assert MPSSE.disable_3_phase_clocking() == <<0x8D>>
    end

    test "disable_adaptive_clocking/0 emits 0x97" do
      assert MPSSE.disable_adaptive_clocking() == <<0x97>>
    end

    test "set_tck_divisor/1 encodes a little-endian 16-bit divisor" do
      assert MPSSE.set_tck_divisor(0x0000) == <<0x86, 0x00, 0x00>>
      assert MPSSE.set_tck_divisor(0x0001) == <<0x86, 0x01, 0x00>>
      assert MPSSE.set_tck_divisor(0xFFFF) == <<0x86, 0xFF, 0xFF>>
      assert MPSSE.set_tck_divisor(0x1234) == <<0x86, 0x34, 0x12>>
    end
  end

  describe "clock_divisor/2" do
    test "30 MHz from the 60 MHz base needs divisor 0" do
      assert MPSSE.clock_divisor(30_000_000) == 0
    end

    test "15 MHz from the 60 MHz base needs divisor 1" do
      assert MPSSE.clock_divisor(15_000_000) == 1
    end

    test "1 MHz from the 60 MHz base needs divisor 29" do
      assert MPSSE.clock_divisor(1_000_000) == 29
    end

    test "100 kHz from the 60 MHz base needs divisor 299" do
      assert MPSSE.clock_divisor(100_000) == 299
    end

    test "rates above the maximum clamp to divisor 0" do
      assert MPSSE.clock_divisor(60_000_000) == 0
    end

    test "rates below the minimum clamp to divisor 0xFFFF" do
      assert MPSSE.clock_divisor(1) == 0xFFFF
    end

    test "legacy 12 MHz base produces matching divisor" do
      assert MPSSE.clock_divisor(6_000_000, :legacy) == 0
      assert MPSSE.clock_divisor(100_000, :legacy) == 59
    end
  end

  describe "sck_frequency/2" do
    test "round-trips with clock_divisor/2 for typical I2C/SPI rates" do
      for target <- [100_000, 400_000, 1_000_000, 10_000_000] do
        divisor = MPSSE.clock_divisor(target)
        actual = MPSSE.sck_frequency(divisor)
        # Allow 1 % tolerance for the integer-divisor rounding
        assert_in_delta actual, target, target * 0.01
      end
    end
  end

  describe "enable_drive_zero/2" do
    test "encodes opcode 0x9E with low and high masks" do
      assert MPSSE.enable_drive_zero(0x07, 0x00) == <<0x9E, 0x07, 0x00>>
    end
  end

  describe "loopback and flush" do
    test "loopback_on/0 and loopback_off/0" do
      assert MPSSE.loopback_on() == <<0x84>>
      assert MPSSE.loopback_off() == <<0x85>>
    end

    test "send_immediate/0 emits 0x87" do
      assert MPSSE.send_immediate() == <<0x87>>
    end
  end

  describe "write_bytes/2" do
    test "MSB-first, -ve write edge (default) emits opcode 0x11" do
      out = MPSSE.write_bytes(<<0xA5>>) |> IO.iodata_to_binary()
      assert out == <<0x11, 0x00, 0x00, 0xA5>>
    end

    test "MSB-first, +ve write edge emits opcode 0x10" do
      out = MPSSE.write_bytes(<<0xA5>>, edge: :positive) |> IO.iodata_to_binary()
      assert out == <<0x10, 0x00, 0x00, 0xA5>>
    end

    test "LSB-first, -ve write edge emits opcode 0x19" do
      out = MPSSE.write_bytes(<<0xA5>>, bit_order: :lsb_first) |> IO.iodata_to_binary()
      assert out == <<0x19, 0x00, 0x00, 0xA5>>
    end

    test "encodes (length - 1) as little-endian 16-bit" do
      data = :binary.copy(<<0xFF>>, 256)
      out = MPSSE.write_bytes(data) |> IO.iodata_to_binary()
      assert <<0x11, lo, hi, payload::binary>> = out
      assert lo == 0xFF
      assert hi == 0x00
      assert payload == data
    end

    test "splits writes larger than 65536 bytes into multiple commands" do
      data = :binary.copy(<<0xAA>>, 70_000)
      out = MPSSE.write_bytes(data) |> IO.iodata_to_binary()
      assert <<0x11, 0xFF, 0xFF, chunk1::binary-size(65_536), 0x11, lo, hi, chunk2::binary>> = out

      assert chunk1 == :binary.copy(<<0xAA>>, 65_536)
      assert :binary.decode_unsigned(<<lo, hi>>, :little) + 1 == 70_000 - 65_536
      assert chunk2 == :binary.copy(<<0xAA>>, 70_000 - 65_536)
    end
  end

  describe "read_bytes/2" do
    test "MSB-first, +ve read edge (default) emits opcode 0x20" do
      out = MPSSE.read_bytes(1) |> IO.iodata_to_binary()
      assert out == <<0x20, 0x00, 0x00>>
    end

    test "MSB-first, -ve read edge emits opcode 0x24" do
      out = MPSSE.read_bytes(1, edge: :negative) |> IO.iodata_to_binary()
      assert out == <<0x24, 0x00, 0x00>>
    end

    test "LSB-first, +ve read edge emits opcode 0x28" do
      out = MPSSE.read_bytes(1, bit_order: :lsb_first) |> IO.iodata_to_binary()
      assert out == <<0x28, 0x00, 0x00>>
    end

    test "encodes (count - 1) as little-endian 16-bit" do
      out = MPSSE.read_bytes(256) |> IO.iodata_to_binary()
      assert out == <<0x20, 0xFF, 0x00>>
    end

    test "splits reads larger than 65536 bytes" do
      out = MPSSE.read_bytes(70_000) |> IO.iodata_to_binary()
      assert <<0x20, 0xFF, 0xFF, 0x20, lo, hi>> = out
      assert :binary.decode_unsigned(<<lo, hi>>, :little) + 1 == 70_000 - 65_536
    end
  end

  describe "transfer_bytes/2" do
    test "defaults to opcode 0x31 (SPI mode 0: write -ve, read +ve, MSB)" do
      out = MPSSE.transfer_bytes(<<0xAB>>) |> IO.iodata_to_binary()
      assert out == <<0x31, 0x00, 0x00, 0xAB>>
    end

    test "SPI mode 1/2 (write +ve, read -ve, MSB) emits 0x34" do
      out =
        MPSSE.transfer_bytes(<<0xAB>>, write_edge: :positive, read_edge: :negative)
        |> IO.iodata_to_binary()

      assert out == <<0x34, 0x00, 0x00, 0xAB>>
    end
  end

  describe "write_bits/3" do
    test "MSB-first, -ve write edge (default) emits opcode 0x13" do
      assert MPSSE.write_bits(0x01, 1) == <<0x13, 0x00, 0x01>>
    end

    test "encodes (count - 1) in the length byte" do
      assert MPSSE.write_bits(0xFF, 8) == <<0x13, 0x07, 0xFF>>
    end
  end

  describe "read_bits/2" do
    test "MSB-first, +ve read edge (default) emits opcode 0x22" do
      assert MPSSE.read_bits(1) == <<0x22, 0x00>>
    end

    test "encodes (count - 1) in the length byte" do
      assert MPSSE.read_bits(8) == <<0x22, 0x07>>
    end
  end

  describe "transfer_bits/3" do
    test "defaults to opcode 0x33 (write -ve, read +ve, bit, MSB)" do
      assert MPSSE.transfer_bits(0x55, 4) == <<0x33, 0x03, 0x55>>
    end
  end

  describe "find_bad_command/1" do
    test "returns :ok when there is no marker" do
      assert MPSSE.find_bad_command(<<0xDE, 0xAD, 0xBE, 0xEF>>) == :ok
    end

    test "returns the offending opcode when 0xFA precedes another byte" do
      assert MPSSE.find_bad_command(<<0xFA, 0xAB>>) == {:bad_command, 0xAB}
    end

    test "finds 0xFA at any position in the response" do
      response = <<0x00, 0x01, 0xFA, 0x42, 0xFF>>
      assert MPSSE.find_bad_command(response) == {:bad_command, 0x42}
    end

    test "returns :ok if 0xFA is the very last byte (no offender to read)" do
      assert MPSSE.find_bad_command(<<0xAA, 0xFA>>) == :ok
    end
  end
end
