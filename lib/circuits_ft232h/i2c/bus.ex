defmodule CircuitsFT232H.I2C.Bus do
  @moduledoc """
  The struct returned by `Circuits.I2C.open/2` when `CircuitsFT232H.I2C.Backend`
  is configured as the I2C backend.

  Holds the device id and the resolved configuration. Implements the
  `Circuits.I2C.Bus` protocol by delegating to `CircuitsFT232H.I2C`.
  """

  alias CircuitsFT232H.{Device, I2C}

  @enforce_keys [:id, :config]
  defstruct [:id, :config]

  @type t :: %__MODULE__{id: Device.id(), config: I2C.config()}

  defimpl Circuits.I2C.Bus do
    alias CircuitsFT232H.I2C

    def flags(%{config: %{flags: flags}}), do: flags

    def read(%{id: id}, address, count, opts), do: I2C.read(id, address, count, opts)

    def write(%{id: id}, address, data, opts), do: I2C.write(id, address, data, opts)

    def write_read(%{id: id}, address, write_data, read_count, opts) do
      I2C.write_read(id, address, write_data, read_count, opts)
    end

    def close(%{id: id}), do: I2C.close(id)
  end
end
