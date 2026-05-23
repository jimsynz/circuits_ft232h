defmodule CircuitsFT232H.I2C.BackendTest do
  use ExUnit.Case, async: false

  alias CircuitsFT232H.I2C.Backend

  @moduletag :hardware_i2c

  # Rig: AD1+AD2 tied as SDA, AD0 is SCL, external pull-ups (4.7 kΩ to 3V3)
  # on both, BNO055 IMU on the bus.
  #
  # The BNO055 has well-documented I2C quirks — no repeated-start support,
  # picky setup/hold timing, occasional address ghosting when consecutive
  # transactions land near its address. We accept either of its two
  # documented addresses for the detection assertion below.
  @bno055_addresses [0x28, 0x29]

  setup do
    on_exit(fn ->
      DynamicSupervisor.which_children(CircuitsFT232H.DeviceSupervisor)
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(CircuitsFT232H.DeviceSupervisor, pid)

        _ ->
          :ok
      end)
    end)

    [name | _] = Backend.bus_names([])
    {:ok, bus_name: name}
  end

  test "bus_names/1 includes the connected FT232H", %{bus_name: name} do
    assert String.starts_with?(name, "ftdi-")
    assert String.ends_with?(name, "-i2c")
  end

  test "info/0 reports the backend module" do
    assert %{backend: Backend} = Backend.info()
  end

  test "open/2 returns a Bus struct with the requested config", %{bus_name: name} do
    {:ok, bus} = Backend.open(name, speed_hz: 100_000)
    assert %CircuitsFT232H.I2C.Bus{config: %{speed_hz: 100_000}} = bus
    :ok = Circuits.I2C.close(bus)
  end

  test "flags include :supports_empty_write", %{bus_name: name} do
    {:ok, bus} = Backend.open(name, [])
    assert :supports_empty_write in Circuits.I2C.Bus.flags(bus)
    :ok = Circuits.I2C.close(bus)
  end

  test "detect_devices finds the BNO055", %{bus_name: name} do
    {:ok, bus} = Backend.open(name, [])
    devices = Circuits.I2C.detect_devices(bus)

    found = Enum.find(@bno055_addresses, &(&1 in devices))

    assert found,
           "expected one of #{inspect(@bno055_addresses, base: :hex)} in #{inspect(devices, base: :hex)}"

    :ok = Circuits.I2C.close(bus)
  end

  test "writing to an absent address returns :i2c_nak", %{bus_name: name} do
    {:ok, bus} = Backend.open(name, [])
    # 0x77 is well outside the BNO055's range and not a special address
    assert {:error, :i2c_nak} = Circuits.I2C.write(bus, 0x77, <<0x00>>)
    :ok = Circuits.I2C.close(bus)
  end

  test "rejects unsupported options at open", %{bus_name: name} do
    assert {:error, {:speed_too_high, _, _}} = Backend.open(name, speed_hz: 2_000_000)
    assert {:error, {:invalid_speed_hz, _}} = Backend.open(name, speed_hz: 0)
  end

  describe "clock stretching" do
    test "config carries clock_stretching: true through to the Bus struct", %{bus_name: name} do
      {:ok, bus} = Backend.open(name, clock_stretching: true)
      assert bus.config.clock_stretching == true
      :ok = Circuits.I2C.close(bus)
    end

    test "claims AD7 so GPIO can't open it", %{bus_name: name} do
      {:ok, bus} = Backend.open(name, clock_stretching: true)

      assert {:error, {:pin_reserved_by_protocol, :i2c, 7}} =
               CircuitsFT232H.GPIO.Backend.open("AD7", :output, [])

      :ok = Circuits.I2C.close(bus)
    end

    test "doesn't claim AD7 when clock_stretching is off", %{bus_name: name} do
      {:ok, bus} = Backend.open(name, [])
      {:ok, handle} = CircuitsFT232H.GPIO.Backend.open("AD7", :output, [])
      :ok = Circuits.GPIO.Handle.close(handle)
      :ok = Circuits.I2C.close(bus)
    end
  end
end
