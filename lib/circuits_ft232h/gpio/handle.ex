defmodule CircuitsFT232H.GPIO.Handle do
  @moduledoc """
  The struct returned by `Circuits.GPIO.open/3` when
  `CircuitsFT232H.GPIO.Backend` is configured as the GPIO backend.

  Implements the `Circuits.GPIO.Handle` protocol by delegating to the
  per-chip `CircuitsFT232H.Device` GenServer.
  """

  alias CircuitsFT232H.Device

  @enforce_keys [:controller, :pin, :direction, :label]
  defstruct [:controller, :pin, :direction, :label]

  @type t :: %__MODULE__{
          controller: Device.id(),
          pin: Device.pin(),
          direction: Device.pin_direction(),
          label: String.t()
        }

  defimpl Circuits.GPIO.Handle do
    alias CircuitsFT232H.Device

    def read(%{controller: id, pin: pin}) do
      case Device.read_gpio_pin(id, pin) do
        v when v in 0..1 -> v
        _ -> 0
      end
    end

    def write(%{controller: id, pin: pin}, value) when value in 0..1 do
      _ = Device.write_gpio_pin(id, pin, value)
      :ok
    end

    def set_direction(%{controller: id, pin: pin}, direction)
        when direction in [:input, :output] do
      Device.set_gpio_pin_direction(id, pin, direction)
    end

    def set_pull_mode(%{controller: _id, pin: _pin}, mode) when mode in [:not_set, :pullup] do
      # FT232H always has internal weak pull-ups (~75 kΩ) on inputs and there
      # is no runtime control to disable them or add a pull-down. We accept
      # the no-op modes and reject the rest.
      :ok
    end

    def set_pull_mode(_handle, _mode), do: {:error, :not_supported}

    def close(%{controller: id, pin: pin}) do
      _ = CircuitsFT232H.GPIO.Poller.unsubscribe(id, pin)
      Device.release_gpio_pin(id, pin)
    end

    def set_interrupts(%{controller: id, pin: pin}, :none, _opts) do
      CircuitsFT232H.GPIO.Poller.unsubscribe(id, pin)
    end

    def set_interrupts(%{controller: id, pin: pin}, trigger, opts)
        when trigger in [:rising, :falling, :both] do
      CircuitsFT232H.GPIO.Poller.subscribe(id, pin, trigger, opts)
    end
  end
end
