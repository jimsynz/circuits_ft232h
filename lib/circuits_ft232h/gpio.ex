defmodule CircuitsFT232H.GPIO do
  @moduledoc """
  GPIO support for the FT232H's general-purpose pins.

  The FT232H exposes 16 GPIO pins. The labels match the silkscreen on the
  Adafruit FT232H breakout:

  | Label    | Linear pin number | Notes                           |
  | -------- | ----------------- | ------------------------------- |
  | `AD0`    | 0                 | Shared with SCK (SPI) / SCL (I2C) |
  | `AD1`    | 1                 | Shared with MOSI / SDA-out      |
  | `AD2`    | 2                 | Shared with MISO / SDA-in       |
  | `AD3`    | 3                 | Shared with CS (SPI)            |
  | `AD4`-`AD7` | 4..7           | Free                            |
  | `AC0`-`AC7` | 8..15          | Free                            |

  GPIO can run alongside an active I2C or SPI bus on the same chip, provided
  the pin doesn't overlap with the protocol's reserved pins (see the table
  above). The `CircuitsFT232H.Device` GenServer enforces this.

  Public API lives on `CircuitsFT232H.GPIO.Backend` (a `Circuits.GPIO.Backend`
  implementation) and `CircuitsFT232H.GPIO.Handle` (the per-pin handle
  returned by `Circuits.GPIO.open/3`). This module holds shared parsing and
  identifier helpers.
  """

  alias CircuitsFT232H.{Device, USB}
  alias CircuitsFT232H.USB.Descriptor

  @label_regex ~r/^A([DC])([0-7])$/

  @type pin :: Device.pin()

  @typedoc "Combined identifier for one FT232H pin: device id + pin number + label."
  @type pin_ref :: %{controller: Device.id(), pin: pin(), label: String.t()}

  @doc "Returns the label for a linear pin number (`0..15`)."
  @spec label(pin()) :: String.t()
  def label(pin) when pin in 0..7, do: "AD#{pin}"
  def label(pin) when pin in 8..15, do: "AC#{pin - 8}"

  @doc ~S{Parses an `"AD<n>"`/`"AC<n>"` label into a linear pin number.}
  @spec parse_label(String.t()) :: {:ok, pin()} | {:error, :invalid_label}
  def parse_label(label) when is_binary(label) do
    case Regex.run(@label_regex, label) do
      [_, "D", n] -> {:ok, String.to_integer(n)}
      [_, "C", n] -> {:ok, String.to_integer(n) + 8}
      _ -> {:error, :invalid_label}
    end
  end

  @doc """
  Resolves a `Circuits.GPIO.gpio_spec()` into a fully qualified `pin_ref`
  identifying both the chip and the pin within it.

  Accepted forms:
    * `{controller, line_offset}` — e.g. `{"ftdi-3:8", 4}`
    * `{controller, label}` — e.g. `{"ftdi-3:8", "AD4"}`
    * `label` — e.g. `"AD4"`; requires exactly one FT232H attached
    * `line_offset` (integer 0..15) — requires exactly one FT232H attached
  """
  @spec resolve(any()) ::
          {:ok, pin_ref()}
          | {:error, :invalid_label | :invalid_pin | :no_device | :ambiguous_device | term()}
  def resolve({controller, label_or_offset}) when is_binary(controller) do
    with {:ok, pin} <- parse_pin(label_or_offset) do
      {:ok, %{controller: controller, pin: pin, label: label(pin)}}
    end
  end

  def resolve(label_or_offset) do
    with {:ok, pin} <- parse_pin(label_or_offset),
         {:ok, descriptor} <- only_descriptor() do
      {:ok, %{controller: Device.id_for(descriptor), pin: pin, label: label(pin)}}
    end
  end

  @doc """
  Builds a `Circuits.GPIO.identifiers()` map for `pin_ref`.
  """
  @spec identifiers(pin_ref()) :: map()
  def identifiers(%{controller: controller, pin: pin, label: label}) do
    %{location: {controller, pin}, controller: controller, label: label}
  end

  @doc """
  Lists all GPIO pins on every connected FT232H, in canonical order.
  """
  @spec all_pin_refs() :: [pin_ref()]
  def all_pin_refs do
    case USB.list_devices() do
      {:ok, descriptors} ->
        for d <- descriptors,
            controller = Device.id_for(d),
            pin <- 0..15 do
          %{controller: controller, pin: pin, label: label(pin)}
        end

      _ ->
        []
    end
  end

  @doc """
  Looks up the `USB.Descriptor` for the given controller id, or an error if
  no chip with that id is connected.
  """
  @spec find_descriptor(Device.id()) :: {:ok, Descriptor.t()} | {:error, :not_found | term()}
  def find_descriptor(controller) do
    with {:ok, descriptors} <- USB.list_devices() do
      match_controller(descriptors, controller)
    end
  end

  defp match_controller(descriptors, controller) do
    case Enum.find(descriptors, fn d -> Device.id_for(d) == controller end) do
      nil -> {:error, :not_found}
      d -> {:ok, d}
    end
  end

  defp parse_pin(label) when is_binary(label), do: parse_label(label)

  defp parse_pin(pin) when is_integer(pin) and pin in 0..15, do: {:ok, pin}

  defp parse_pin(_), do: {:error, :invalid_pin}

  defp only_descriptor do
    case USB.list_devices() do
      {:ok, [d]} -> {:ok, d}
      {:ok, []} -> {:error, :no_device}
      {:ok, _} -> {:error, :ambiguous_device}
      err -> err
    end
  end
end
