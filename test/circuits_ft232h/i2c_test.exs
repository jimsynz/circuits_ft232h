defmodule CircuitsFT232H.I2CTest do
  use ExUnit.Case, async: true

  alias CircuitsFT232H.I2C

  describe "parse_bus_name/1" do
    test "parses a well-formed name into its id" do
      assert {:ok, "3:8"} = I2C.parse_bus_name("ftdi-3:8-i2c")
    end

    test "round-trips through bus_name/1" do
      assert "ftdi-3:8-i2c" = I2C.bus_name("3:8")
      assert {:ok, "3:8"} = I2C.parse_bus_name(I2C.bus_name("3:8"))
    end

    test "rejects names without the ftdi prefix" do
      assert {:error, :invalid_bus_name} = I2C.parse_bus_name("i2c-3:8")
    end

    test "rejects names without the -i2c suffix" do
      assert {:error, :invalid_bus_name} = I2C.parse_bus_name("ftdi-3:8-spi")
    end
  end

  describe "build_config/1" do
    test "fills in defaults" do
      assert {:ok,
              %{
                speed_hz: 100_000,
                clock_stretching: false,
                flags: [:supports_empty_write]
              }} = I2C.build_config([])
    end

    test "accepts a custom speed" do
      assert {:ok, %{speed_hz: 400_000}} = I2C.build_config(speed_hz: 400_000)
    end

    test "accepts clock_stretching: true" do
      assert {:ok, %{clock_stretching: true}} = I2C.build_config(clock_stretching: true)
    end

    test "rejects non-boolean clock_stretching" do
      assert {:error, {:invalid_clock_stretching, "yes"}} =
               I2C.build_config(clock_stretching: "yes")
    end

    test "rejects non-positive speed" do
      assert {:error, {:invalid_speed_hz, 0}} = I2C.build_config(speed_hz: 0)
      assert {:error, {:invalid_speed_hz, -1}} = I2C.build_config(speed_hz: -1)
    end

    test "rejects speeds above 1 MHz" do
      assert {:error, {:speed_too_high, _, _}} = I2C.build_config(speed_hz: 2_000_000)
    end

    test "rejects non-integer speeds" do
      assert {:error, {:invalid_speed_hz, :fast}} = I2C.build_config(speed_hz: :fast)
    end
  end

  describe "extra_reserved_pins/1" do
    test "reserves AD7 when clock stretching is enabled" do
      assert [7] = I2C.extra_reserved_pins(%{clock_stretching: true})
    end

    test "reserves no extra pins by default" do
      assert [] = I2C.extra_reserved_pins(%{clock_stretching: false})
    end
  end
end
