defmodule CircuitsFT232H.SPI.BackendTest do
  use ExUnit.Case, async: false

  alias CircuitsFT232H.SPI.Backend

  @moduletag :hardware

  setup do
    # The first call to Backend.open/2 starts the Device under the
    # application's DynamicSupervisor. We need to make sure it's torn down
    # between tests so each test starts from a clean state. The Bus's
    # protocol-level `close/1` releases the mode lock but leaves the Device
    # running; that's fine — claim_mode is idempotent and releasing returns
    # the chip to a clean baseline.
    on_exit(fn ->
      Enum.each(DynamicSupervisor.which_children(CircuitsFT232H.DeviceSupervisor), fn
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
    assert String.ends_with?(name, "-spi")
  end

  test "info/0 reports the backend module" do
    assert %{backend: Backend} = Backend.info()
  end

  test "open/2 returns a Bus struct with the requested config", %{bus_name: name} do
    {:ok, bus} = Backend.open(name, mode: 0, speed_hz: 500_000)
    assert %CircuitsFT232H.SPI.Bus{config: config} = bus
    assert config.mode == 0
    assert config.speed_hz == 500_000

    :ok = Circuits.SPI.close(bus)
  end

  test "loopback (MOSI ↔ MISO via AD1<->AD2 jumper) round-trips an 8-byte pattern",
       %{bus_name: name} do
    {:ok, bus} = Backend.open(name, mode: 0, speed_hz: 1_000_000)
    pattern = <<0xA5, 0x5A, 0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF>>

    assert {:ok, ^pattern} = Circuits.SPI.transfer(bus, pattern)

    :ok = Circuits.SPI.close(bus)
  end

  test "transfer/2 with a 256-byte pattern", %{bus_name: name} do
    {:ok, bus} = Backend.open(name, speed_hz: 4_000_000)
    pattern = for i <- 0..255, into: <<>>, do: <<i>>

    assert {:ok, ^pattern} = Circuits.SPI.transfer(bus, pattern)

    :ok = Circuits.SPI.close(bus)
  end

  test "open + close + open again works (mode lock releases cleanly)", %{bus_name: name} do
    {:ok, bus1} = Backend.open(name, [])
    :ok = Circuits.SPI.close(bus1)

    {:ok, bus2} = Backend.open(name, [])
    pattern = <<0x42>>
    assert {:ok, ^pattern} = Circuits.SPI.transfer(bus2, pattern)
    :ok = Circuits.SPI.close(bus2)
  end

  test "rejects unsupported options at open", %{bus_name: name} do
    assert {:error, {:unsupported_mode, 4}} = Backend.open(name, mode: 4)
    assert {:error, {:unsupported_bits_per_word, 16}} = Backend.open(name, bits_per_word: 16)
  end
end
