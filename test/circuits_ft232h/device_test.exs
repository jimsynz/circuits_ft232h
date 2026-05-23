defmodule CircuitsFT232H.DeviceTest do
  use ExUnit.Case, async: false

  alias CircuitsFT232H.{Device, USB}

  @moduletag :hardware

  test "init_mpsse/2 puts the chip in MPSSE mode" do
    with_chip(fn usb ->
      assert :ok = Device.init_mpsse(usb)
    end)
  end

  test "validate/1 returns :ok once MPSSE is initialised" do
    with_chip(fn usb ->
      :ok = Device.init_mpsse(usb)
      assert :ok = Device.validate(usb)
    end)
  end

  test "validate/1 survives repeated cycles" do
    with_chip(fn usb ->
      :ok = Device.init_mpsse(usb)
      for _ <- 1..5, do: assert(:ok = Device.validate(usb))
    end)
  end

  # libusb resource handles get confused when close runs from an `on_exit`
  # process, so we do open/close inline per test instead.
  defp with_chip(fun) do
    {:ok, [descriptor | _]} = USB.list_devices()
    {:ok, usb} = USB.open(descriptor)

    try do
      fun.(usb)
    after
      USB.close(usb)
    end
  end
end
