defmodule CircuitsFT232H.USB.Descriptor do
  @moduledoc """
  Metadata for a single FT232H device discovered on the USB bus.

  The `:device` field is an opaque reference handed back by the `:usb` library.
  It does not represent an open handle — it is just enough to identify the
  device and open it later via `CircuitsFT232H.USB.open/1`.
  """

  @enforce_keys [:device, :bus, :address]
  defstruct [:device, :bus, :address, port_numbers: [], speed: :unknown]

  @type t :: %__MODULE__{
          device: :usb.device(),
          bus: 0..255,
          address: 0..255,
          port_numbers: [0..255],
          speed: :unknown | :low | :full | :high | :super | :super_plus
        }
end
