defmodule CircuitsFT232H.Device.IdForTest do
  use ExUnit.Case, async: true

  @moduletag :pure

  alias CircuitsFT232H.{Device, USB}

  describe "id_for/1" do
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
end
