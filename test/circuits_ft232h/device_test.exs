defmodule CircuitsFT232H.DeviceTest do
  use ExUnit.Case, async: false

  alias CircuitsFT232H.{Device, USB}

  describe "id_for/1" do
    @describetag :pure

    test "prefers the FTDI serial number when one is set" do
      descriptor = %USB.Descriptor{
        device: make_ref(),
        bus: 3,
        address: 9,
        serial: "FT9XYZAB"
      }

      assert "FT9XYZAB" = Device.id_for(descriptor)
    end

    test "falls back to bus:address when serial is nil" do
      descriptor = %USB.Descriptor{device: make_ref(), bus: 3, address: 9, serial: nil}
      assert "3:9" = Device.id_for(descriptor)
    end

    test "falls back to bus:address when serial is an empty string" do
      descriptor = %USB.Descriptor{device: make_ref(), bus: 3, address: 9, serial: ""}
      assert "3:9" = Device.id_for(descriptor)
    end
  end

  @moduletag :hardware

  setup do
    {:ok, [descriptor | _]} = USB.list_devices()
    start_supervised!({Device, descriptor: descriptor})
    {:ok, descriptor: descriptor, id: Device.id_for(descriptor)}
  end

  describe "init" do
    test "puts the chip in MPSSE mode and validates", %{id: id} do
      assert :ok = Device.validate(id)
    end

    test "survives repeated validate cycles", %{id: id} do
      for _ <- 1..5, do: assert(:ok = Device.validate(id))
    end
  end

  describe "registry" do
    test "registers under id_for/1", %{id: id} do
      assert {:ok, pid} = Device.whereis(id)
      assert is_pid(pid)
    end

    test "find_or_start/2 returns the running pid", %{descriptor: descriptor, id: id} do
      {:ok, original} = Device.whereis(id)
      assert {:ok, ^original} = Device.find_or_start(descriptor)
    end
  end

  describe "mode lock" do
    test "starts in :none", %{id: id} do
      assert :none = Device.mode(id)
    end

    test "claims :spi from :none", %{id: id} do
      assert :ok = Device.claim_mode(id, :spi)
      assert :spi = Device.mode(id)
    end

    test "claims :i2c from :none", %{id: id} do
      assert :ok = Device.claim_mode(id, :i2c)
      assert :i2c = Device.mode(id)
    end

    test "second claim of the same mode is idempotent", %{id: id} do
      assert :ok = Device.claim_mode(id, :spi)
      assert :ok = Device.claim_mode(id, :spi)
    end

    test "conflicting claim returns :mode_busy", %{id: id} do
      assert :ok = Device.claim_mode(id, :spi)
      assert {:error, {:mode_busy, :spi}} = Device.claim_mode(id, :i2c)
    end

    test "release returns to :none and lets the other mode claim", %{id: id} do
      :ok = Device.claim_mode(id, :spi)
      assert :ok = Device.release_mode(id)
      assert :none = Device.mode(id)
      assert :ok = Device.claim_mode(id, :i2c)
    end
  end
end
