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

    def read(%{id: id, config: config}, address, count, opts) do
      I2C.read(id, config, address, count, opts)
    end

    def write(%{id: id, config: config}, address, data, opts) do
      I2C.write(id, config, address, data, opts)
    end

    def write_read(%{id: id, config: config}, address, write_data, read_count, opts) do
      I2C.write_read(id, config, address, write_data, read_count, opts)
    end

    def close(%{id: id}), do: I2C.close(id)
  end
end
