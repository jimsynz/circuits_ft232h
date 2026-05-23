defmodule CircuitsFT232H.SPI.Bus do
  @moduledoc """
  The struct returned by `Circuits.SPI.open/2` when `CircuitsFT232H.SPI.Backend`
  is configured as the SPI backend.

  Holds the device id and the resolved configuration. Implements the
  `Circuits.SPI.Bus` protocol by delegating to `CircuitsFT232H.SPI` and
  ultimately the per-chip `CircuitsFT232H.Device` GenServer.
  """

  alias CircuitsFT232H.{Device, SPI}

  @enforce_keys [:id, :config]
  defstruct [:id, :config]

  @type t :: %__MODULE__{id: Device.id(), config: SPI.config()}

  defimpl Circuits.SPI.Bus do
    alias CircuitsFT232H.SPI

    def config(%{config: config}), do: {:ok, config}

    def transfer(%{id: id, config: config}, data) when is_binary(data) do
      SPI.transfer(id, config, data)
    end

    def close(%{id: id, config: config}), do: SPI.close(id, config)

    def max_transfer_size(_bus), do: SPI.max_transfer_size()
  end
end
