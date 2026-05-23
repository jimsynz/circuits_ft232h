defmodule CircuitsFT232H.GPIO.CoexistenceTest do
  use ExUnit.Case, async: false

  alias Circuits.GPIO.Handle, as: GPIOHandle
  alias CircuitsFT232H.{Device, USB}
  alias CircuitsFT232H.GPIO.Backend, as: GPIO
  alias CircuitsFT232H.I2C.Backend, as: I2C
  alias CircuitsFT232H.SPI.Backend, as: SPI

  @moduletag :hardware

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

    {:ok, [descriptor | _]} = USB.list_devices()
    {:ok, id: Device.id_for(descriptor)}
  end

  describe "GPIO alongside I2C" do
    setup do
      [name | _] = I2C.bus_names([])
      {:ok, _bus} = I2C.open(name, [])
      :ok
    end

    test "rejects GPIO open on pins reserved by I2C (AD0-AD2)" do
      for pin <- 0..2 do
        assert {:error, {:pin_reserved_by_protocol, :i2c, ^pin}} =
                 GPIO.open(pin, :output, [])
      end
    end

    test "allows GPIO open on free pins (AD3-AD7, AC0-AC7)" do
      {:ok, h1} = GPIO.open("AD5", :output, initial_value: 1)
      {:ok, h2} = GPIO.open("AC3", :output, initial_value: 0)

      assert GPIOHandle.read(h1) == 1
      assert GPIOHandle.read(h2) == 0

      :ok = GPIOHandle.close(h1)
      :ok = GPIOHandle.close(h2)
    end
  end

  describe "GPIO alongside SPI" do
    setup do
      [name | _] = SPI.bus_names([])
      {:ok, _bus} = SPI.open(name, [])
      :ok
    end

    test "rejects GPIO open on pins reserved by SPI (AD0-AD3)" do
      for pin <- 0..3 do
        assert {:error, {:pin_reserved_by_protocol, :spi, ^pin}} =
                 GPIO.open(pin, :output, [])
      end
    end

    test "allows GPIO open on free pins (AD4-AD7, AC0-AC7)" do
      {:ok, h} = GPIO.open("AD6", :output, initial_value: 1)
      assert GPIOHandle.read(h) == 1
      :ok = GPIOHandle.close(h)
    end
  end

  describe "claim_mode after GPIO" do
    test "I2C claim fails if a conflicting GPIO is open", %{id: id} do
      {:ok, h} = GPIO.open("AD2", :output, [])
      assert {:error, {:pin_busy, 2}} = Device.claim_mode(id, :i2c)
      :ok = GPIOHandle.close(h)
    end

    test "SPI claim succeeds if GPIO is only on non-reserved pins", %{id: id} do
      {:ok, h} = GPIO.open("AC0", :output, [])
      assert :ok = Device.claim_mode(id, :spi)
      :ok = Device.release_mode(id)
      :ok = GPIOHandle.close(h)
    end
  end
end
