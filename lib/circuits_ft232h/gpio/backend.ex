defmodule CircuitsFT232H.GPIO.Backend do
  @moduledoc """
  `Circuits.GPIO.Backend` implementation for the FT232H.

  Configure with:

      config :circuits_gpio, default_backend: CircuitsFT232H.GPIO.Backend

  Each connected FT232H is a GPIO controller named `\"ftdi-<id>\"`, exposing
  the 16 pins `AD0..AD7` and `AC0..AC7`. The pins are addressable as
  integers `0..15` or by their `AD?`/`AC?` labels — see
  `CircuitsFT232H.GPIO` for the full mapping.

  GPIO operations coexist with `CircuitsFT232H.SPI.Backend` and
  `CircuitsFT232H.I2C.Backend` on the same chip — pins reserved by an
  active protocol fail with `{:error, {:pin_reserved_by_protocol, mode, pin}}`
  if you try to open them as GPIO.

  ## Interrupts are emulated by polling

  `Circuits.GPIO.set_interrupts/3` is supported via a per-chip polling
  GenServer (`CircuitsFT232H.GPIO.Poller`) that samples pin state at a
  fixed interval — **the FT232H has no hardware pin-change notifications,
  so pulses shorter than the poll interval will be missed.** Default
  interval is 10&nbsp;ms; configure via:

      config :circuits_ft232h, gpio_poll_interval_ms: 5

  See `CircuitsFT232H.GPIO.Poller` for the full caveats.
  """

  @behaviour Circuits.GPIO.Backend

  alias CircuitsFT232H.{Device, GPIO}
  alias CircuitsFT232H.GPIO.Handle

  @impl true
  def enumerate(_options) do
    Enum.map(GPIO.all_pin_refs(), &GPIO.identifiers/1)
  end

  @impl true
  def identifiers(gpio_spec, _options) do
    case GPIO.resolve(gpio_spec) do
      {:ok, pin_ref} -> {:ok, GPIO.identifiers(pin_ref)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def status(gpio_spec, _options) do
    with {:ok, pin_ref} <- GPIO.resolve(gpio_spec) do
      direction =
        case Device.whereis(pin_ref.controller) do
          {:ok, _pid} -> Device.gpio_pin_direction(pin_ref.controller, pin_ref.pin) || :input
          {:error, _} -> :input
        end

      {:ok, %{consumer: "", direction: direction, pull_mode: :pullup}}
    end
  end

  @impl true
  def open(gpio_spec, direction, options) when direction in [:input, :output] do
    with {:ok, pin_ref} <- GPIO.resolve(gpio_spec),
         {:ok, descriptor} <- GPIO.find_descriptor(pin_ref.controller),
         {:ok, _pid} <- Device.find_or_start(descriptor),
         initial = initial_value(options),
         :ok <- Device.claim_gpio_pin(pin_ref.controller, pin_ref.pin, direction, initial) do
      {:ok,
       %Handle{
         controller: pin_ref.controller,
         pin: pin_ref.pin,
         direction: direction,
         label: pin_ref.label
       }}
    end
  end

  @impl true
  def backend_info, do: %{backend: __MODULE__, name: "circuits_ft232h"}

  defp initial_value(options) do
    case Keyword.get(options, :initial_value, 0) do
      0 -> 0
      1 -> 1
      _ -> 0
    end
  end
end
