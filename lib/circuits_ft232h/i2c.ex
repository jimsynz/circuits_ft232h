defmodule CircuitsFT232H.I2C do
  @moduledoc """
  Wires the FT232H's MPSSE engine up as an I2C master.

  The FT232H has no native I2C peripheral — I2C is bit-banged via MPSSE
  using two FT232H-specific tricks:

    * The `DRIVE_ZERO` opcode (0x9E) makes the chosen pins behave as true
      open-drain outputs — `0` drives low, `1` tristates. With external
      pull-ups this matches I2C's electrical model.
    * `ENABLE_3_PHASE_CLOCKING` (0x8C) adds an extra phase per bit so that
      SDA setup/hold around SCL meets the I2C spec. The effective SCK rate
      becomes 2/3 of the MPSSE divisor rate, so this module compensates by
      programming SCK = 1.5 × the requested I2C rate.

  Pin assignments (fixed for v0.1):

  | Pin      | Role |
  | -------- | ---- |
  | `ADBUS0` | SCL  |
  | `ADBUS1` | SDA (out) — **must be tied externally to ADBUS2** |
  | `ADBUS2` | SDA (in)  — sees what's on the SDA wire |

  External pull-ups on SCL and SDA are required: 4.7 kΩ for 100 kHz,
  2.2 kΩ for 400 kHz, 1 kΩ for 1 MHz.

  Public API lives on `CircuitsFT232H.I2C.Backend` and
  `CircuitsFT232H.I2C.Bus`. This module holds the shared MPSSE encoding
  logic and bus-name conventions.
  """

  alias CircuitsFT232H.{Device, MPSSE, USB}
  alias CircuitsFT232H.USB.Descriptor

  import Bitwise

  @bus_name_prefix "ftdi-"
  @bus_name_suffix "-i2c"
  @bus_name_regex ~r/^ftdi-(.+)-i2c$/

  # Low-byte pin masks
  @scl_bit 0x01
  @sda_o_bit 0x02
  @sda_i_bit 0x04
  @scl_feedback_bit 0x80
  @scl_feedback_pin 7

  @i2c_pins @scl_bit ||| @sda_o_bit ||| @sda_i_bit
  @i2c_pins_with_feedback @i2c_pins ||| @scl_feedback_bit

  # Direction masks
  @drive_dir @scl_bit ||| @sda_o_bit
  @release_dir @scl_bit

  # ADBUS value combinations (with DRIVE_ZERO, 1 = tristate / pulled-up high, 0 = driven low)
  @both_high @scl_bit ||| @sda_o_bit
  @scl_high_sda_low @scl_bit
  @scl_low_sda_low 0x00
  @scl_low_sda_high @sda_o_bit

  @default_speed_hz 100_000
  @max_speed_hz 1_000_000
  @default_timeout 5_000

  # FTDI quirk: read_bits with count=1 right-justifies the bit, placing it
  # at bit 0 (LSB), even though the opcode mnemonic claims MSB-first.
  # Verified against pyftdi/i2c.py:1068 (`ack[0] & self.BIT0`).
  @ack_mask 0x01
  @ack_byte 0x00
  @nack_byte 0xFF

  # MPSSE processes a 3-byte set_bits_low opcode in ~208 ns on the FT232H's
  # 60 MHz engine (calibrated against an INA219 at 100 kHz — 24 repeats
  # gave the ~5 μs hold needed to satisfy I²C tHD;STA/tSU;STA/tHIGH/tLOW).
  @ns_per_hold_rep 208
  @min_hold_repeats 4

  @typedoc "Resolved I2C bus configuration."
  @type config :: %{
          speed_hz: pos_integer(),
          clock_stretching: boolean(),
          hold_repeats: pos_integer(),
          flags: [Circuits.I2C.Bus.flag()]
        }

  @doc """
  Returns the additional pins this backend reserves for a given config —
  used by `CircuitsFT232H.I2C.Backend` when claiming the I2C mode lock.

  With clock stretching enabled, `ADBUS7` (`AD7`) is reserved as the
  SCL-feedback input.
  """
  @spec extra_reserved_pins(config()) :: [Device.pin()]
  def extra_reserved_pins(%{clock_stretching: true}), do: [@scl_feedback_pin]
  def extra_reserved_pins(_), do: []

  @doc "Builds the canonical I2C bus name for a device id."
  @spec bus_name(Device.id()) :: String.t()
  def bus_name(id), do: @bus_name_prefix <> id <> @bus_name_suffix

  @doc """
  Parses an I2C bus name into the underlying device id, or returns
  `{:error, :invalid_bus_name}`.
  """
  @spec parse_bus_name(String.t()) :: {:ok, Device.id()} | {:error, :invalid_bus_name}
  def parse_bus_name(name) when is_binary(name) do
    case Regex.run(@bus_name_regex, name) do
      [_, id] -> {:ok, id}
      _ -> {:error, :invalid_bus_name}
    end
  end

  @doc "Looks up the `USB.Descriptor` whose id matches the I2C bus name."
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
  Validates and merges user options against the I2C defaults.

  Options:
    * `:speed_hz` (default 100&nbsp;000, max 1&nbsp;000&nbsp;000)
    * `:clock_stretching` (default `false`) — enable adaptive-clocking-based
      I2C clock stretching detection. Requires `ADBUS0` (SCL) to be
      externally jumpered to `ADBUS7` so MPSSE can see when a slave is
      holding SCL low. Reserves `ADBUS7` (pin `AD7`) for the duration of
      the bus.
  """
  @spec build_config(keyword()) :: {:ok, config()} | {:error, term()}
  def build_config(opts) do
    speed_hz = Keyword.get(opts, :speed_hz, @default_speed_hz)
    clock_stretching = Keyword.get(opts, :clock_stretching, false)

    cond do
      not is_integer(speed_hz) or speed_hz <= 0 ->
        {:error, {:invalid_speed_hz, speed_hz}}

      speed_hz > @max_speed_hz ->
        {:error, {:speed_too_high, speed_hz, @max_speed_hz}}

      not is_boolean(clock_stretching) ->
        {:error, {:invalid_clock_stretching, clock_stretching}}

      true ->
        {:ok,
         %{
           speed_hz: speed_hz,
           clock_stretching: clock_stretching,
           hold_repeats: hold_repeats_for(speed_hz),
           flags: [:supports_empty_write]
         }}
    end
  end

  # Number of times each bus-control set_bits_low is repeated in start/stop/
  # repeated-start sequences to give the slave enough setup/hold time. Targets
  # a half-SCL-period hold so we comfortably meet the I²C spec's minima
  # (tHD;STA/tSU;STA/tSU;STO of 4 μs / 0.6 μs / 0.26 μs at 100k / 400k / 1M).
  defp hold_repeats_for(speed_hz) do
    target_ns = div(1_000_000_000, 2 * speed_hz)
    max(@min_hold_repeats, div(target_ns + @ns_per_hold_rep - 1, @ns_per_hold_rep))
  end

  @doc """
  Configures the FT232H for I2C traffic with the given config. Assumes the
  chip is in baseline MPSSE state and the I2C mode lock has been claimed.

  Also runs an I2C bus-recovery sequence — 16 SCL pulses with SDA released
  followed by a stop — to free any slave that's stuck mid-transaction (which
  can happen if a previous program crashed during a read).
  """
  @spec configure(Device.id(), config()) :: :ok | {:error, term()}
  def configure(id, config) do
    sck_target = round(config.speed_hz * 1.5)
    divisor = MPSSE.clock_divisor(sck_target)
    drive_zero_mask = if config.clock_stretching, do: @i2c_pins_with_feedback, else: @i2c_pins

    setup =
      IO.iodata_to_binary([
        MPSSE.enable_3_phase_clocking(),
        MPSSE.enable_drive_zero(drive_zero_mask, 0x00),
        MPSSE.set_tck_divisor(divisor),
        bus_recovery_sequence(config),
        MPSSE.set_bits_low(@both_high, @drive_dir)
      ])

    Device.transaction(id, setup)
  end

  defp bus_recovery_sequence(config) do
    pulses =
      for _ <- 1..16 do
        [
          hold(@both_high, @drive_dir, config),
          hold(@scl_low_sda_high, @drive_dir, config)
        ]
      end

    [pulses, stop_sequence(config)]
  end

  @doc """
  Tears down the I2C-specific MPSSE config so the chip can be reused for a
  different mode without restarting the Device.
  """
  @spec close(Device.id()) :: :ok
  def close(id) do
    teardown =
      IO.iodata_to_binary([
        MPSSE.set_bits_low(@both_high, @drive_dir),
        MPSSE.disable_3_phase_clocking(),
        MPSSE.enable_drive_zero(0x00, 0x00)
      ])

    _ = Device.transaction(id, teardown)
    Device.release_mode(id)
    :ok
  end

  # ----- Transactions -----

  @doc "Writes `data` to `address`. Empty `data` is the I2C device-present probe."
  @spec write(Device.id(), config(), 0..127, binary(), keyword()) ::
          :ok | {:error, term()}
  def write(id, config, address, data, _opts \\ [])
      when address in 0..127 and is_binary(data) do
    {command, expected} = build_write(address, data, config)

    with {:ok, response} <- Device.transaction(id, command, expected, @default_timeout) do
      check_write_response(response, byte_size(data))
    end
  end

  @doc "Reads `count` bytes from `address`."
  @spec read(Device.id(), config(), 0..127, pos_integer(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def read(id, config, address, count, _opts \\ [])
      when address in 0..127 and count > 0 do
    {command, expected} = build_read(address, count, config)

    with {:ok, response} <- Device.transaction(id, command, expected, @default_timeout) do
      check_read_response(response, count)
    end
  end

  @doc "Writes `write_data` then reads `read_count` bytes, with a repeated start in between."
  @spec write_read(Device.id(), config(), 0..127, binary(), pos_integer(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def write_read(id, config, address, write_data, read_count, _opts \\ [])
      when address in 0..127 and is_binary(write_data) and read_count > 0 do
    {command, expected} = build_write_read(address, write_data, read_count, config)

    with {:ok, response} <- Device.transaction(id, command, expected, @default_timeout) do
      check_write_read_response(response, byte_size(write_data), read_count)
    end
  end

  # ----- Sequence builders -----

  defp build_write(address, data, config) do
    bytes = <<address <<< 1>> <> data

    command =
      wrap_transaction(config, [
        start_sequence(config),
        write_bytes_with_acks(bytes),
        stop_sequence(config)
      ])

    # One ACK byte per byte written, including the address byte.
    {command, byte_size(bytes)}
  end

  defp build_read(address, count, config) do
    address_byte = <<address <<< 1 ||| 1>>

    command =
      wrap_transaction(config, [
        start_sequence(config),
        write_bytes_with_acks(address_byte),
        read_bytes_with_acks(count),
        stop_sequence(config)
      ])

    # 1 ACK byte (address) + `count` data bytes.
    {command, 1 + count}
  end

  defp build_write_read(address, write_data, read_count, config) do
    write_bytes = <<address <<< 1>> <> write_data
    read_address = <<address <<< 1 ||| 1>>

    command =
      wrap_transaction(config, [
        start_sequence(config),
        write_bytes_with_acks(write_bytes),
        repeated_start_sequence(config),
        write_bytes_with_acks(read_address),
        read_bytes_with_acks(read_count),
        stop_sequence(config)
      ])

    # ACKs: write address + write data + read address. Data: read_count.
    {command, byte_size(write_bytes) + 1 + read_count}
  end

  # Wraps a transaction body in adaptive-clocking enable/disable opcodes when
  # the config asks for clock stretching. Pyftdi does the same per-transaction
  # — adaptive clocking is left off between transactions so other operations
  # (e.g. GPIO reads through `CircuitsFT232H.Device.read_gpio_bytes/1`) don't
  # wait on the AD7 feedback pin.
  defp wrap_transaction(%{clock_stretching: true}, body) do
    IO.iodata_to_binary([
      MPSSE.enable_adaptive_clocking(),
      body,
      MPSSE.disable_adaptive_clocking(),
      MPSSE.send_immediate()
    ])
  end

  defp wrap_transaction(_config, body) do
    IO.iodata_to_binary([body, MPSSE.send_immediate()])
  end

  # ----- MPSSE primitives -----

  # set_bits_low executes at the MPSSE engine rate (~200 ns per opcode),
  # which is far faster than I²C standard-mode setup/hold times (~5 μs).
  # Each control-line transition in start/stop/repeated-start needs to hold
  # its state long enough for the slave to register the edge, so each state
  # is emitted `config.hold_repeats` times to consume time without changing
  # the bus. The count is derived from the bus speed in `build_config/1`.
  defp hold(state, direction, %{hold_repeats: n}),
    do: List.duplicate(MPSSE.set_bits_low(state, direction), n)

  defp start_sequence(config) do
    [
      hold(@both_high, @drive_dir, config),
      hold(@scl_high_sda_low, @drive_dir, config),
      hold(@scl_low_sda_low, @drive_dir, config)
    ]
  end

  defp stop_sequence(config) do
    [
      hold(@scl_low_sda_low, @drive_dir, config),
      hold(@scl_high_sda_low, @drive_dir, config),
      hold(@both_high, @drive_dir, config)
    ]
  end

  defp repeated_start_sequence(config) do
    [
      hold(@scl_low_sda_high, @drive_dir, config),
      hold(@both_high, @drive_dir, config),
      hold(@scl_high_sda_low, @drive_dir, config),
      hold(@scl_low_sda_low, @drive_dir, config)
    ]
  end

  defp write_bytes_with_acks(bytes) do
    for <<byte <- bytes>> do
      [
        MPSSE.set_bits_low(@scl_low_sda_low, @drive_dir),
        MPSSE.write_bytes(<<byte>>, edge: :negative, bit_order: :msb_first),
        MPSSE.set_bits_low(@scl_low_sda_high, @release_dir),
        MPSSE.read_bits(1, edge: :positive, bit_order: :msb_first)
      ]
    end
  end

  defp read_bytes_with_acks(count) do
    for i <- 1..count do
      ack_value = if i == count, do: @nack_byte, else: @ack_byte

      [
        MPSSE.set_bits_low(@scl_low_sda_high, @release_dir),
        MPSSE.read_bytes(1, edge: :positive, bit_order: :msb_first),
        MPSSE.set_bits_low(@scl_low_sda_low, @drive_dir),
        MPSSE.write_bits(ack_value, 1, edge: :negative, bit_order: :msb_first)
      ]
    end
  end

  # ----- Response parsers -----

  defp check_write_response(response, data_len) when byte_size(response) == 1 + data_len do
    <<addr_ack, data_acks::binary>> = response

    cond do
      (addr_ack &&& @ack_mask) != 0 -> {:error, :i2c_nak}
      any_nack?(data_acks) -> {:error, :i2c_nak}
      true -> :ok
    end
  end

  defp check_write_response(response, expected) do
    {:error, {:short_response, byte_size(response), 1 + expected}}
  end

  defp check_read_response(response, count) when byte_size(response) == 1 + count do
    <<addr_ack, data::binary>> = response

    if (addr_ack &&& @ack_mask) != 0 do
      {:error, :i2c_nak}
    else
      {:ok, data}
    end
  end

  defp check_read_response(response, count) do
    {:error, {:short_response, byte_size(response), 1 + count}}
  end

  defp check_write_read_response(response, write_len, read_len) do
    expected = 1 + write_len + 1 + read_len

    case response do
      <<bin::binary-size(^expected)>> ->
        parse_write_read_bytes(bin, write_len, read_len)

      _ ->
        {:error, {:short_response, byte_size(response), expected}}
    end
  end

  defp parse_write_read_bytes(bin, write_len, read_len) do
    <<write_addr_ack, write_acks::binary-size(^write_len), read_addr_ack,
      data::binary-size(^read_len)>> = bin

    cond do
      (write_addr_ack &&& @ack_mask) != 0 -> {:error, :i2c_nak}
      any_nack?(write_acks) -> {:error, :i2c_nak}
      (read_addr_ack &&& @ack_mask) != 0 -> {:error, :i2c_nak}
      true -> {:ok, data}
    end
  end

  defp any_nack?(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.any?(fn b -> (b &&& @ack_mask) != 0 end)
  end
end
