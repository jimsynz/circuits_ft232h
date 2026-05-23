defmodule CircuitsFT232H.SPITest do
  use ExUnit.Case, async: true

  alias CircuitsFT232H.SPI

  describe "parse_bus_name/1" do
    test "parses a well-formed name into its id" do
      assert {:ok, "3:8"} = SPI.parse_bus_name("ftdi-3:8-spi")
    end

    test "round-trips through bus_name/1" do
      assert "ftdi-3:8-spi" = SPI.bus_name("3:8")
      assert {:ok, "3:8"} = SPI.parse_bus_name(SPI.bus_name("3:8"))
    end

    test "rejects names without the ftdi prefix" do
      assert {:error, :invalid_bus_name} = SPI.parse_bus_name("spi-3:8")
    end

    test "rejects names without the -spi suffix" do
      assert {:error, :invalid_bus_name} = SPI.parse_bus_name("ftdi-3:8-i2c")
    end
  end

  describe "build_config/1" do
    test "fills in defaults when nothing is supplied" do
      assert {:ok, config} = SPI.build_config([])

      assert %{
               mode: 0,
               bits_per_word: 8,
               speed_hz: 1_000_000,
               delay_us: 10,
               lsb_first: false,
               sw_lsb_first: false
             } = config
    end

    test "honours user-supplied values" do
      assert {:ok,
              %{
                mode: 3,
                speed_hz: 8_000_000,
                lsb_first: true
              }} =
               SPI.build_config(mode: 3, speed_hz: 8_000_000, lsb_first: true)
    end

    test "rejects modes outside 0..3" do
      assert {:error, {:unsupported_mode, 4}} = SPI.build_config(mode: 4)
      assert {:error, {:unsupported_mode, -1}} = SPI.build_config(mode: -1)
    end

    test "rejects bits_per_word other than 8" do
      assert {:error, {:unsupported_bits_per_word, 16}} = SPI.build_config(bits_per_word: 16)
    end

    test "rejects non-positive speed" do
      assert {:error, {:invalid_speed_hz, 0}} = SPI.build_config(speed_hz: 0)
      assert {:error, {:invalid_speed_hz, -100}} = SPI.build_config(speed_hz: -100)
    end
  end
end
