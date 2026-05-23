defmodule CircuitsFT232H.SPI do
  @moduledoc """
  Wires the FT232H's MPSSE engine up as an SPI master.

  Pin assignments are fixed for v0.1:

  | Pin      | Role          |
  | -------- | ------------- |
  | `ADBUS0` | SCK (output)  |
  | `ADBUS1` | MOSI (output) |
  | `ADBUS2` | MISO (input)  |
  | `ADBUS3` | CS (active-low, output) |

  Public API lives on `CircuitsFT232H.SPI.Backend` (a `Circuits.SPI.Backend`
  implementation) and `CircuitsFT232H.SPI.Bus` (the struct returned by
  `Circuits.SPI.open/2`). This module holds the shared MPSSE encoding logic
  and bus-name conventions used by both.
  """

  alias CircuitsFT232H.{Device, MPSSE, USB}
  alias CircuitsFT232H.USB.Descriptor

  import Bitwise

  @bus_name_prefix "ftdi-"
  @bus_name_suffix "-spi"
  @bus_name_regex ~r/^ftdi-(.+)-spi$/

  # Low-byte pin masks. MISO is on ADBUS2 (0x04) but doesn't appear here
  # because it's an input — it's neither in the direction mask nor set as a
  # value.
  @sck_bit 0x01
  @mosi_bit 0x02
  @cs_bit 0x08

  # Output direction mask for ADBUS — SCK, MOSI, CS are outputs; MISO is input
  @direction @sck_bit ||| @mosi_bit ||| @cs_bit

  # Per spi_dev defaults; we match them so behaviour is portable.
  @default_mode 0
  @default_bits_per_word 8
  @default_speed_hz 1_000_000
  @default_delay_us 10
  @default_lsb_first false

  @max_transfer_size 0x10000

  @typedoc "Resolved SPI configuration map — matches `Circuits.SPI`'s `spi_option_map()`."
  @type config :: %{
          mode: 0..3,
          bits_per_word: pos_integer(),
          speed_hz: pos_integer(),
          delay_us: non_neg_integer(),
          lsb_first: boolean(),
          sw_lsb_first: boolean()
        }

  @doc "Maximum number of bytes that can be transferred in one MPSSE call."
  @spec max_transfer_size() :: pos_integer()
  def max_transfer_size, do: @max_transfer_size

  @doc "Builds the canonical SPI bus name for a device id."
  @spec bus_name(Device.id()) :: String.t()
  def bus_name(id), do: @bus_name_prefix <> id <> @bus_name_suffix

  @doc """
  Parses an SPI bus name into the underlying device id, or returns
  `{:error, :invalid_bus_name}`.
  """
  @spec parse_bus_name(String.t()) :: {:ok, Device.id()} | {:error, :invalid_bus_name}
  def parse_bus_name(name) when is_binary(name) do
    case Regex.run(@bus_name_regex, name) do
      [_, id] -> {:ok, id}
      _ -> {:error, :invalid_bus_name}
    end
  end

  @doc """
  Looks up the `USB.Descriptor` whose id matches the SPI bus name.
  """
  @spec find_descriptor(String.t()) ::
          {:ok, Descriptor.t()} | {:error, :invalid_bus_name | :not_found | term()}
  def find_descriptor(bus_name) do
    with {:ok, id} <- parse_bus_name(bus_name),
         {:ok, descriptors} <- USB.list_devices() do
      match_descriptor(descriptors, id)
    end
  end

  defp match_descriptor(descriptors, id) do
    case Enum.find(descriptors, fn d -> Device.id_for(d) == id end) do
      nil -> {:error, :not_found}
      d -> {:ok, d}
    end
  end

  @doc """
  Validates and merges user options against the SPI defaults.
  """
  @spec build_config(keyword()) :: {:ok, config()} | {:error, term()}
  def build_config(opts) do
    config = %{
      mode: Keyword.get(opts, :mode, @default_mode),
      bits_per_word: Keyword.get(opts, :bits_per_word, @default_bits_per_word),
      speed_hz: Keyword.get(opts, :speed_hz, @default_speed_hz),
      delay_us: Keyword.get(opts, :delay_us, @default_delay_us),
      lsb_first: Keyword.get(opts, :lsb_first, @default_lsb_first),
      sw_lsb_first: false
    }

    cond do
      config.mode not in 0..3 ->
        {:error, {:unsupported_mode, config.mode}}

      config.bits_per_word != 8 ->
        {:error, {:unsupported_bits_per_word, config.bits_per_word}}

      config.speed_hz <= 0 ->
        {:error, {:invalid_speed_hz, config.speed_hz}}

      true ->
        {:ok, config}
    end
  end

  @doc """
  Configures the FT232H for SPI traffic with the given config. Assumes the
  chip is already in MPSSE mode and the SPI mode lock has been claimed.
  """
  @spec configure(Device.id(), config()) :: :ok | {:error, term()}
  def configure(id, config) do
    divisor = MPSSE.clock_divisor(config.speed_hz)

    setup =
      IO.iodata_to_binary([
        three_phase_command(config.mode),
        MPSSE.set_tck_divisor(divisor),
        MPSSE.set_bits_low(idle_pin_state(config.mode), @direction)
      ])

    Device.transaction(id, setup)
  end

  @doc """
  Runs a full-duplex SPI transfer. Asserts CS, exchanges `data` for an equal
  number of MISO bytes, then deasserts CS.
  """
  @spec transfer(Device.id(), config(), binary()) :: {:ok, binary()} | {:error, term()}
  def transfer(_id, _config, <<>>), do: {:ok, <<>>}

  def transfer(id, config, data) when is_binary(data) do
    if byte_size(data) > @max_transfer_size do
      {:error, {:transfer_too_large, byte_size(data), @max_transfer_size}}
    else
      do_transfer(id, config, data)
    end
  end

  @doc """
  Tears down an SPI bus: deasserts CS and releases the mode lock so the
  chip can be reused (e.g. for I2C) without restarting the Device.
  """
  @spec close(Device.id(), config()) :: :ok
  def close(id, config) do
    teardown =
      IO.iodata_to_binary([
        MPSSE.set_bits_low(idle_pin_state(config.mode), @direction)
      ])

    _ = Device.transaction(id, teardown)
    Device.release_mode(id)
    :ok
  end

  defp do_transfer(id, config, data) do
    {write_edge, read_edge} = duplex_edges(config.mode)
    bit_order = if config.lsb_first, do: :lsb_first, else: :msb_first
    idle = idle_pin_state(config.mode)
    asserted = sck_idle(config.mode)

    command =
      IO.iodata_to_binary([
        MPSSE.set_bits_low(asserted, @direction),
        MPSSE.transfer_bytes(data,
          write_edge: write_edge,
          read_edge: read_edge,
          bit_order: bit_order
        ),
        MPSSE.set_bits_low(idle, @direction),
        MPSSE.send_immediate()
      ])

    Device.transaction(id, command, byte_size(data))
  end

  # SPI mode → MPSSE encoding tables.
  #
  # Pyftdi's SpiController spells these out at pyftdi/spi.py:807-829. The
  # mapping reflects the absolute clock edges MPSSE uses, irrespective of
  # CPOL — only the SCK idle level changes between modes 0/1 and 2/3.

  defp sck_idle(mode) when mode in [0, 1], do: 0
  defp sck_idle(mode) when mode in [2, 3], do: @sck_bit

  defp idle_pin_state(mode), do: sck_idle(mode) ||| @cs_bit

  defp duplex_edges(mode) when mode in [0, 3], do: {:negative, :positive}
  defp duplex_edges(mode) when mode in [1, 2], do: {:positive, :negative}

  defp three_phase_command(mode) when mode in [1, 3], do: MPSSE.enable_3_phase_clocking()
  defp three_phase_command(_), do: MPSSE.disable_3_phase_clocking()
end
