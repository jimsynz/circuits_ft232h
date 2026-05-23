defmodule CircuitsFT232H.GPIO.BackendTest do
  use ExUnit.Case, async: false

  alias CircuitsFT232H.GPIO.Backend
  alias CircuitsFT232H.GPIO.Handle

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

    :ok
  end

  describe "enumerate/1" do
    test "lists 16 pins per connected FT232H" do
      pins = Backend.enumerate([])
      assert length(pins) == 16

      labels = Enum.map(pins, & &1.label) |> Enum.sort()
      expected = (Enum.map(0..7, &"AD#{&1}") ++ Enum.map(0..7, &"AC#{&1}")) |> Enum.sort()
      assert labels == expected
    end
  end

  describe "open/3" do
    test "opens an output pin and read-after-write reflects the driven value" do
      {:ok, handle} = Backend.open("AD7", :output, initial_value: 0)
      assert %Handle{pin: 7, direction: :output, label: "AD7"} = handle

      :ok = Circuits.GPIO.Handle.write(handle, 1)
      assert 1 = Circuits.GPIO.Handle.read(handle)

      :ok = Circuits.GPIO.Handle.write(handle, 0)
      assert 0 = Circuits.GPIO.Handle.read(handle)

      :ok = Circuits.GPIO.Handle.close(handle)
    end

    test "opens an input pin and reads the floating-with-pullup value" do
      {:ok, handle} = Backend.open("AC0", :input, [])
      # The FT232H has weak internal pull-ups, so an unconnected input reads 1.
      assert 1 = Circuits.GPIO.Handle.read(handle)
      :ok = Circuits.GPIO.Handle.close(handle)
    end

    test "rejects opening the same pin twice" do
      {:ok, handle} = Backend.open("AD7", :output, [])
      assert {:error, {:pin_busy, 7}} = Backend.open("AD7", :input, [])
      :ok = Circuits.GPIO.Handle.close(handle)
    end

    test "rejects an out-of-range integer spec" do
      assert {:error, :invalid_pin} = Backend.open(99, :input, [])
    end

    test "accepts {controller, label} specs" do
      [%{controller: controller} | _] = Backend.enumerate([])
      {:ok, handle} = Backend.open({controller, "AD7"}, :output, initial_value: 1)
      assert handle.pin == 7
      :ok = Circuits.GPIO.Handle.close(handle)
    end

    test "set_direction/2 flips an open pin without reopening" do
      {:ok, handle} = Backend.open("AD7", :output, initial_value: 1)
      assert :ok = Circuits.GPIO.Handle.set_direction(handle, :input)
      assert :ok = Circuits.GPIO.Handle.set_direction(handle, :output)
      :ok = Circuits.GPIO.Handle.close(handle)
    end
  end

  describe "pull modes" do
    test "accepts :not_set and :pullup as no-ops" do
      {:ok, handle} = Backend.open("AC0", :input, [])
      assert :ok = Circuits.GPIO.Handle.set_pull_mode(handle, :not_set)
      assert :ok = Circuits.GPIO.Handle.set_pull_mode(handle, :pullup)
      :ok = Circuits.GPIO.Handle.close(handle)
    end

    test "rejects :pulldown and :none — the FT232H can't do either at runtime" do
      {:ok, handle} = Backend.open("AC0", :input, [])
      assert {:error, :not_supported} = Circuits.GPIO.Handle.set_pull_mode(handle, :pulldown)
      assert {:error, :not_supported} = Circuits.GPIO.Handle.set_pull_mode(handle, :none)
      :ok = Circuits.GPIO.Handle.close(handle)
    end
  end

  describe "interrupts" do
    test "set_interrupts/3 subscribes via the Poller and returns :ok" do
      {:ok, handle} = Backend.open("AC0", :input, [])

      assert :ok = Circuits.GPIO.Handle.set_interrupts(handle, :both, [])
      assert :ok = Circuits.GPIO.Handle.set_interrupts(handle, :none, [])

      :ok = Circuits.GPIO.Handle.close(handle)
    end
  end

  describe "backend_info/0" do
    test "reports the backend module and name" do
      info = Backend.backend_info()
      assert info.backend == Backend
      assert info.name == "circuits_ft232h"
    end
  end
end
