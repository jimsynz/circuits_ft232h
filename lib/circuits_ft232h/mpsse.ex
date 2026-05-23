defmodule CircuitsFT232H.MPSSE do
  @moduledoc """
  Pure-function encoder for the FT232H Multi-Protocol Synchronous Serial
  Engine (MPSSE) command stream.

  This module knows nothing about USB or transports. It builds binaries you
  hand to `CircuitsFT232H.USB.write/3`, and helps interpret bytes you read
  back via `CircuitsFT232H.USB.read/3`.

  Opcode names and semantics mirror FTDI Application Note
  [AN_108](https://ftdichip.com/wp-content/uploads/2020/08/AN_108_Command_Processor_for_MPSSE_and_MCU_Host_Bus_Emulation_Modes.pdf).
  """

  import Bitwise

  # ----- Data shifting opcodes (bit 7 = 0) -----
  #
  # Bit layout:
  #   bit 6 = 0   (not TMS — JTAG only)
  #   bit 5 = 1   read TDO/DI
  #   bit 4 = 1   write TDI/DO
  #   bit 3 = 1   LSB first
  #   bit 2 = 1   read on -ve edge of CLK
  #   bit 1 = 1   bit mode (otherwise byte mode)
  #   bit 0 = 1   write on -ve edge of CLK

  # ----- GPIO and control opcodes -----
  @op_set_bits_low 0x80
  @op_get_bits_low 0x81
  @op_set_bits_high 0x82
  @op_get_bits_high 0x83
  @op_loopback_start 0x84
  @op_loopback_end 0x85
  @op_set_tck_divisor 0x86
  @op_send_immediate 0x87
  @op_disable_clock_divide_by_5 0x8A
  @op_enable_clock_divide_by_5 0x8B
  @op_enable_3_phase_clocking 0x8C
  @op_disable_3_phase_clocking 0x8D
  @op_disable_adaptive_clocking 0x97
  @op_enable_drive_zero 0x9E

  # FT232H acks an unknown opcode by sending this byte followed by the
  # offending opcode.
  @bad_command 0xFA

  @max_byte_chunk 0x10000
  @max_bit_chunk 8

  # H-series base clocks
  @clock_base_60mhz 60_000_000
  @clock_base_12mhz 12_000_000

  @typedoc "Order in which a byte's bits are clocked out / in."
  @type bit_order :: :msb_first | :lsb_first

  @typedoc "Clock edge on which a data bit is driven or sampled."
  @type clock_edge :: :positive | :negative

  @typedoc "Which MPSSE base clock to compute against."
  @type clock_base :: :high_speed | :legacy

  @doc "The MPSSE byte that precedes the echo of an unrecognised opcode."
  @spec bad_command_byte() :: byte()
  def bad_command_byte, do: @bad_command

  # ----- GPIO -----

  @doc """
  Sets the low-byte GPIO port (`ADBUS0`..`ADBUS7`) state.

  `value` is the level each output pin should drive (bit 0 = `ADBUS0`).
  `direction` is the per-pin direction mask — `1` for output, `0` for input.
  In MPSSE mode the engine overrides direction for SCK / MOSI / MISO so it
  is safe to leave those as outputs in the direction mask.
  """
  @spec set_bits_low(byte(), byte()) :: binary()
  def set_bits_low(value, direction) when value in 0..255 and direction in 0..255 do
    <<@op_set_bits_low, value, direction>>
  end

  @doc """
  Sets the high-byte GPIO port (`ACBUS0`..`ACBUS7`) state. See `set_bits_low/2`.
  """
  @spec set_bits_high(byte(), byte()) :: binary()
  def set_bits_high(value, direction) when value in 0..255 and direction in 0..255 do
    <<@op_set_bits_high, value, direction>>
  end

  @doc "Reads the current state of `ADBUS0`..`ADBUS7`. Response is 1 byte."
  @spec get_bits_low() :: binary()
  def get_bits_low, do: <<@op_get_bits_low>>

  @doc "Reads the current state of `ACBUS0`..`ACBUS7`. Response is 1 byte."
  @spec get_bits_high() :: binary()
  def get_bits_high, do: <<@op_get_bits_high>>

  # ----- Clocking -----

  @doc """
  Selects the 60&nbsp;MHz MPSSE base clock (H-series chips only). Required
  for SCK frequencies above 6&nbsp;MHz.
  """
  @spec disable_clock_divide_by_5() :: binary()
  def disable_clock_divide_by_5, do: <<@op_disable_clock_divide_by_5>>

  @doc """
  Selects the legacy 12&nbsp;MHz MPSSE base clock (for compatibility with
  FT2232D-style code).
  """
  @spec enable_clock_divide_by_5() :: binary()
  def enable_clock_divide_by_5, do: <<@op_enable_clock_divide_by_5>>

  @doc """
  Enables 3-phase data clocking. Required for I2C, and for SPI modes that
  drive on one edge and sample on the same edge (`CPHA = 1`).
  """
  @spec enable_3_phase_clocking() :: binary()
  def enable_3_phase_clocking, do: <<@op_enable_3_phase_clocking>>

  @doc "Disables 3-phase data clocking (normal 2-phase SPI behaviour)."
  @spec disable_3_phase_clocking() :: binary()
  def disable_3_phase_clocking, do: <<@op_disable_3_phase_clocking>>

  @doc "Disables JTAG adaptive clocking. We never want it for I2C or SPI."
  @spec disable_adaptive_clocking() :: binary()
  def disable_adaptive_clocking, do: <<@op_disable_adaptive_clocking>>

  @doc """
  Sets the SCK clock divisor. Get the right divisor via `clock_divisor/2`.
  """
  @spec set_tck_divisor(0..0xFFFF) :: binary()
  def set_tck_divisor(divisor) when divisor in 0..0xFFFF do
    <<@op_set_tck_divisor, divisor::little-16>>
  end

  @doc """
  Computes the MPSSE divisor that produces `target_hz` SCK, given the base
  clock.

  Use `:high_speed` (default) for the 60&nbsp;MHz base (FT232H, requires
  `disable_clock_divide_by_5/0`) and `:legacy` for the 12&nbsp;MHz base
  (FT2232D-compatible, requires `enable_clock_divide_by_5/0`).

  The formula is `SCK = base / ((1 + divisor) × 2)`. Result is rounded and
  clamped to `0..0xFFFF`.
  """
  @spec clock_divisor(pos_integer(), clock_base()) :: 0..0xFFFF
  def clock_divisor(target_hz, base \\ :high_speed) when target_hz > 0 do
    base_hz = base_clock_hz(base)
    raw = round(base_hz / (2 * target_hz)) - 1
    raw |> max(0) |> min(0xFFFF)
  end

  @doc """
  Returns the SCK frequency produced by the given divisor on the given base
  clock. Inverse of `clock_divisor/2` (with rounding).
  """
  @spec sck_frequency(0..0xFFFF, clock_base()) :: float()
  def sck_frequency(divisor, base \\ :high_speed) when divisor in 0..0xFFFF do
    base_clock_hz(base) / ((1 + divisor) * 2)
  end

  # ----- Open-drain (FT232H exclusive) -----

  @doc """
  Configures pins to operate in open-drain mode.

  Pins set in the masks drive low when their output bit is `0`, and are
  tristated when their output bit is `1`. Combined with external pull-up
  resistors this provides true open-drain behaviour — the key trick that
  makes I2C work on the FT232H.

  Available on FT232H only (not FT2232D / FT2232C).
  """
  @spec enable_drive_zero(byte(), byte()) :: binary()
  def enable_drive_zero(low_mask, high_mask)
      when low_mask in 0..255 and high_mask in 0..255 do
    <<@op_enable_drive_zero, low_mask, high_mask>>
  end

  # ----- Loopback -----

  @doc "Enables internal TDI→TDO loopback. Useful for init self-tests."
  @spec loopback_on() :: binary()
  def loopback_on, do: <<@op_loopback_start>>

  @doc "Disables internal loopback (the normal state)."
  @spec loopback_off() :: binary()
  def loopback_off, do: <<@op_loopback_end>>

  # ----- Flush -----

  @doc """
  Flushes any pending bytes in the chip's internal IN buffer back to the
  host. Append this whenever you need to read a response right away.
  """
  @spec send_immediate() :: binary()
  def send_immediate, do: <<@op_send_immediate>>

  # ----- Data shifting (bytes) -----

  @doc """
  Writes `data` out the TDI/DO pin while clocking SCK.

  Options:
    * `:edge` (default `:negative`) — clock edge on which to drive each bit.
    * `:bit_order` (default `:msb_first`) — bit order within each byte.

  The chip transmits `byte_size(data)` bytes. The command auto-splits into
  multiple `0x1?` blocks if `data` is longer than 65536 bytes.
  """
  @spec write_bytes(binary(), keyword()) :: iodata()
  def write_bytes(data, opts \\ []) when is_binary(data) and byte_size(data) > 0 do
    opcode = shift_opcode(write: true, read: false, mode: :byte, opts: opts)
    chunked_byte_command(opcode, data)
  end

  @doc """
  Reads `count` bytes in on the TDO/DI pin while clocking SCK. No data is
  driven out.

  Options:
    * `:edge` (default `:positive`) — clock edge on which to sample each bit.
    * `:bit_order` (default `:msb_first`).
  """
  @spec read_bytes(pos_integer(), keyword()) :: iodata()
  def read_bytes(count, opts \\ []) when count > 0 do
    opcode =
      shift_opcode(
        write: false,
        read: true,
        mode: :byte,
        opts: Keyword.put_new(opts, :edge, :positive)
      )

    chunked_byte_request(opcode, count)
  end

  @doc """
  Full-duplex byte transfer — drives `data` out on TDI/DO and simultaneously
  samples TDO/DI back. The response is `byte_size(data)` bytes long.

  Options:
    * `:write_edge` (default `:negative`) — clock edge on which to drive.
    * `:read_edge` (default `:positive`) — clock edge on which to sample.
    * `:bit_order` (default `:msb_first`).
  """
  @spec transfer_bytes(binary(), keyword()) :: iodata()
  def transfer_bytes(data, opts \\ []) when is_binary(data) and byte_size(data) > 0 do
    write_edge = Keyword.get(opts, :write_edge, :negative)
    read_edge = Keyword.get(opts, :read_edge, :positive)
    bit_order = Keyword.get(opts, :bit_order, :msb_first)

    opcode =
      shift_opcode(
        write: true,
        read: true,
        mode: :byte,
        opts: [write_edge: write_edge, read_edge: read_edge, bit_order: bit_order]
      )

    chunked_byte_command(opcode, data)
  end

  # ----- Data shifting (bits) -----

  @doc """
  Writes the bottom `count` bits of `value` out the TDI/DO pin while
  clocking SCK. `count` must be in `1..8`.

  Same options as `write_bytes/2`.
  """
  @spec write_bits(byte(), 1..8, keyword()) :: binary()
  def write_bits(value, count, opts \\ [])
      when value in 0..255 and count in 1..@max_bit_chunk do
    opcode = shift_opcode(write: true, read: false, mode: :bit, opts: opts)
    <<opcode, count - 1, value>>
  end

  @doc """
  Clocks `count` bits in from TDO/DI. Response is one byte; the relevant
  bits are right-justified (MSB-first) or left-justified (LSB-first)
  depending on `:bit_order`.

  Same options as `read_bytes/2`.
  """
  @spec read_bits(1..8, keyword()) :: binary()
  def read_bits(count, opts \\ []) when count in 1..@max_bit_chunk do
    opcode =
      shift_opcode(
        write: false,
        read: true,
        mode: :bit,
        opts: Keyword.put_new(opts, :edge, :positive)
      )

    <<opcode, count - 1>>
  end

  @doc """
  Full-duplex bit transfer. Drives the bottom `count` bits of `value` while
  sampling TDO/DI. Response is one byte.

  Same options as `transfer_bytes/2`.
  """
  @spec transfer_bits(byte(), 1..8, keyword()) :: binary()
  def transfer_bits(value, count, opts \\ [])
      when value in 0..255 and count in 1..@max_bit_chunk do
    write_edge = Keyword.get(opts, :write_edge, :negative)
    read_edge = Keyword.get(opts, :read_edge, :positive)
    bit_order = Keyword.get(opts, :bit_order, :msb_first)

    opcode =
      shift_opcode(
        write: true,
        read: true,
        mode: :bit,
        opts: [write_edge: write_edge, read_edge: read_edge, bit_order: bit_order]
      )

    <<opcode, count - 1, value>>
  end

  # ----- Response parsing -----

  @doc """
  Scans `response` for a `BAD_COMMAND` marker (`0xFA`) and returns the
  offending opcode if found.
  """
  @spec find_bad_command(binary()) :: {:bad_command, byte()} | :ok
  def find_bad_command(response) when is_binary(response) do
    case :binary.match(response, <<@bad_command>>) do
      {pos, _} ->
        case response do
          <<_::binary-size(pos), @bad_command, offender, _::binary>> ->
            {:bad_command, offender}

          _ ->
            :ok
        end

      :nomatch ->
        :ok
    end
  end

  # ----- Internals -----

  defp shift_opcode(write: write?, read: read?, mode: mode, opts: opts) do
    bit_order = Keyword.get(opts, :bit_order, :msb_first)

    {write_edge, read_edge} =
      case {write?, read?} do
        {true, true} ->
          {Keyword.get(opts, :write_edge, :negative), Keyword.get(opts, :read_edge, :positive)}

        {true, false} ->
          {Keyword.get(opts, :edge, :negative), :positive}

        {false, true} ->
          {:positive, Keyword.get(opts, :edge, :positive)}
      end

    bor_flags([
      {read?, 0x20},
      {write?, 0x10},
      {bit_order == :lsb_first, 0x08},
      {read_edge == :negative, 0x04},
      {mode == :bit, 0x02},
      {write_edge == :negative, 0x01}
    ])
  end

  defp bor_flags(flags) do
    Enum.reduce(flags, 0, fn
      {true, bit}, acc -> bor(acc, bit)
      {false, _}, acc -> acc
    end)
  end

  defp chunked_byte_command(_opcode, <<>>), do: []

  defp chunked_byte_command(opcode, data) when byte_size(data) <= @max_byte_chunk do
    len = byte_size(data) - 1
    [<<opcode, len::little-16>>, data]
  end

  defp chunked_byte_command(opcode, data) do
    <<chunk::binary-size(@max_byte_chunk), rest::binary>> = data
    [chunked_byte_command(opcode, chunk), chunked_byte_command(opcode, rest)]
  end

  defp chunked_byte_request(_opcode, 0), do: []

  defp chunked_byte_request(opcode, count) when count <= @max_byte_chunk do
    [<<opcode, count - 1::little-16>>]
  end

  defp chunked_byte_request(opcode, count) do
    [
      chunked_byte_request(opcode, @max_byte_chunk),
      chunked_byte_request(opcode, count - @max_byte_chunk)
    ]
  end

  defp base_clock_hz(:high_speed), do: @clock_base_60mhz
  defp base_clock_hz(:legacy), do: @clock_base_12mhz
end
