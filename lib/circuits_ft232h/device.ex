defmodule CircuitsFT232H.Device do
  @moduledoc """
  A GenServer that owns the USB handle to one FT232H and serialises all
  traffic with it.

  Started once per physical chip and registered in `CircuitsFT232H.Registry`
  by the device's id (currently `"<bus>:<address>"` — once we read FTDI
  serial numbers this becomes the serial). All MPSSE traffic flows through
  `transaction/4`, so the chip sees commands from at most one process at a
  time.

  The Device enforces two kinds of allocation:

    * **I2C/SPI mutual-exclusion lock** — at most one of `:i2c` or `:spi` may
      be active on a chip at once. `claim_mode/2` returns
      `{:error, {:mode_busy, current}}` for a conflicting claim.
    * **GPIO pin allocation** — individual pins may be opened by GPIO
      consumers, and the Device tracks which pins are claimed in which
      direction. Pin claims are checked against the active protocol's
      reserved pin set so the two don't fight over the same wires.
  """

  use GenServer

  alias CircuitsFT232H.{MPSSE, USB}
  alias CircuitsFT232H.USB.Descriptor

  import Bitwise

  require Logger

  @default_latency_ms 16
  @default_timeout 5_000

  @typedoc """
  Canonical identifier for a physical FT232H. Today this is `\"<bus>:<address>\"`;
  in a later iteration it will be the FTDI serial number string.
  """
  @type id :: String.t()

  @typedoc "Protocol modes a chip can be locked into."
  @type mode :: :none | :i2c | :spi

  @typedoc """
  Linear pin index. `0..7` map to ADBUS0..ADBUS7 (\"AD0\"..\"AD7\"); `8..15`
  map to ACBUS0..ACBUS7 (\"AC0\"..\"AC7\").
  """
  @type pin :: 0..15

  @typedoc "Direction of a GPIO pin."
  @type pin_direction :: :input | :output

  @typedoc "Internal GenServer state."
  @type t :: %__MODULE__{
          usb: CircuitsFT232H.USB.t() | nil,
          id: id() | nil,
          mode: mode(),
          adbus_value: byte(),
          adbus_dir: byte(),
          acbus_value: byte(),
          acbus_dir: byte(),
          gpio_pins: %{optional(pin()) => pin_direction()}
        }

  defstruct usb: nil,
            id: nil,
            mode: :none,
            adbus_value: 0x00,
            adbus_dir: 0x00,
            acbus_value: 0x00,
            acbus_dir: 0x00,
            gpio_pins: %{}

  # Pins reserved by each protocol mode. Anything outside these is available
  # for GPIO use even while the protocol is active.
  @protocol_pins %{
    none: [],
    # SCK + MOSI + MISO + CS on ADBUS0..ADBUS3
    spi: [0, 1, 2, 3],
    # SCL + SDA(out) + SDA(in) on ADBUS0..ADBUS2
    i2c: [0, 1, 2]
  }

  # ----- Discovery / lifecycle -----

  @doc "Returns the canonical id for a USB descriptor."
  @spec id_for(Descriptor.t()) :: id()
  def id_for(%Descriptor{bus: bus, address: address}), do: "#{bus}:#{address}"

  @doc """
  Starts a Device server for the FT232H described by `:descriptor`.

  Registers under the device's id in `CircuitsFT232H.Registry`. Subsequent
  callers can locate the server via `whereis/1` or by referring to it by
  id in any of the public functions on this module.

  Options:
    * `:descriptor` (required) — the `CircuitsFT232H.USB.Descriptor` for
      the chip.
    * `:latency_ms` (default `#{@default_latency_ms}`) — USB latency timer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    descriptor = Keyword.fetch!(opts, :descriptor)
    id = id_for(descriptor)
    GenServer.start_link(__MODULE__, {descriptor, id, opts}, name: via(id))
  end

  @doc false
  def child_spec(opts) do
    descriptor = Keyword.fetch!(opts, :descriptor)

    %{
      id: id_for(descriptor),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Finds the pid of the Device server with the given id, if one is running.
  """
  @spec whereis(id()) :: {:ok, pid()} | {:error, :not_started}
  def whereis(id) do
    case Registry.lookup(CircuitsFT232H.Registry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_started}
    end
  end

  @doc """
  Starts a Device under `CircuitsFT232H.DeviceSupervisor` if one isn't
  already running for the descriptor's id.

  Returns the existing pid if one is found. Use this from the I2C/SPI/GPIO
  backends — multiple buses may map to the same physical chip.
  """
  @spec find_or_start(Descriptor.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def find_or_start(%Descriptor{} = descriptor, opts \\ []) do
    id = id_for(descriptor)

    case whereis(id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_started} ->
        opts = Keyword.put(opts, :descriptor, descriptor)

        case DynamicSupervisor.start_child(CircuitsFT232H.DeviceSupervisor, {__MODULE__, opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          err -> err
        end
    end
  end

  # ----- Mode lock -----

  @doc "Returns the current protocol mode the chip is locked into."
  @spec mode(id()) :: mode()
  def mode(id), do: GenServer.call(via(id), :mode)

  @doc """
  Claims one of the mutually-exclusive protocol modes for the chip.

  Returns `:ok` if the chip is currently unclaimed (or already claimed in
  the requested mode), or `{:error, {:mode_busy, current_mode}}` otherwise.
  Also fails with `{:error, {:pin_busy, pin}}` if any currently-open GPIO
  pin would conflict with the new mode.
  """
  @spec claim_mode(id(), :i2c | :spi) ::
          :ok | {:error, {:mode_busy, mode()} | {:pin_busy, pin()}}
  def claim_mode(id, requested) when requested in [:i2c, :spi] do
    GenServer.call(via(id), {:claim_mode, requested})
  end

  @doc "Releases whichever mode the chip is currently locked into."
  @spec release_mode(id()) :: :ok
  def release_mode(id), do: GenServer.call(via(id), :release_mode)

  # ----- GPIO -----

  @doc """
  Returns the list of pins reserved by the given protocol mode. Pins outside
  this list are available for GPIO use.
  """
  @spec protocol_pins(mode()) :: [pin()]
  def protocol_pins(mode) when is_map_key(@protocol_pins, mode),
    do: Map.fetch!(@protocol_pins, mode)

  @doc """
  Claims `pin` for GPIO use in the given `direction`. Fails if the pin is
  already claimed, if it's reserved by the active protocol, or if `pin` is
  out of range.

  On success the pin is initialised — direction set, and for outputs the
  initial value driven.
  """
  @spec claim_gpio_pin(id(), pin(), pin_direction(), 0..1) ::
          :ok | {:error, term()}
  def claim_gpio_pin(id, pin, direction, initial_value \\ 0)
      when pin in 0..15 and direction in [:input, :output] and initial_value in 0..1 do
    GenServer.call(via(id), {:claim_gpio_pin, pin, direction, initial_value})
  end

  @doc "Releases a previously-claimed GPIO pin and switches it back to input."
  @spec release_gpio_pin(id(), pin()) :: :ok
  def release_gpio_pin(id, pin) when pin in 0..15 do
    GenServer.call(via(id), {:release_gpio_pin, pin})
  end

  @doc "Writes `value` (0 or 1) to a previously-opened GPIO output pin."
  @spec write_gpio_pin(id(), pin(), 0..1) :: :ok | {:error, term()}
  def write_gpio_pin(id, pin, value) when pin in 0..15 and value in 0..1 do
    GenServer.call(via(id), {:write_gpio_pin, pin, value})
  end

  @doc "Reads the current logic level of a previously-opened GPIO pin."
  @spec read_gpio_pin(id(), pin()) :: 0..1 | {:error, term()}
  def read_gpio_pin(id, pin) when pin in 0..15 do
    GenServer.call(via(id), {:read_gpio_pin, pin})
  end

  @doc """
  Changes the direction of an already-opened GPIO pin. The pin keeps its
  current driven value when switching to output.
  """
  @spec set_gpio_pin_direction(id(), pin(), pin_direction()) :: :ok | {:error, term()}
  def set_gpio_pin_direction(id, pin, direction)
      when pin in 0..15 and direction in [:input, :output] do
    GenServer.call(via(id), {:set_gpio_pin_direction, pin, direction})
  end

  @doc """
  Returns the direction currently configured for `pin`, or `nil` if the pin
  isn't open.
  """
  @spec gpio_pin_direction(id(), pin()) :: pin_direction() | nil
  def gpio_pin_direction(id, pin) when pin in 0..15 do
    GenServer.call(via(id), {:gpio_pin_direction, pin})
  end

  # ----- Transactions -----

  @doc """
  Sends `command` (an MPSSE byte stream) to the chip and optionally reads
  `response_length` bytes back.

  `command` may be any `iodata`. If `response_length` is `0` the call
  returns `:ok` once the bytes have been queued to the chip. Otherwise it
  returns `{:ok, binary}` of exactly `response_length` payload bytes (the
  USB status prefix is stripped).

  Use this for protocol-level MPSSE sequences. For pin-level operations,
  prefer `write_gpio_pin/3`, `read_gpio_pin/2`, and friends — they share
  the Device's pin-state tracking so GPIO and protocol traffic don't
  trample each other's bytes.
  """
  @spec transaction(id(), iodata(), non_neg_integer(), timeout()) ::
          :ok | {:ok, binary()} | {:error, term()}
  def transaction(id, command, response_length \\ 0, timeout \\ @default_timeout) do
    GenServer.call(via(id), {:transaction, command, response_length, timeout}, timeout + 1_000)
  end

  @doc """
  Verifies the chip is in MPSSE mode and responding to commands by issuing
  an unrecognised opcode and checking for the standard `0xFA <opcode>` echo.
  """
  @spec validate(id()) :: :ok | {:error, term()}
  def validate(id) do
    bogus = 0xAB
    command = <<bogus, MPSSE.send_immediate()::binary>>

    case transaction(id, command, 2) do
      {:ok, <<0xFA, ^bogus>>} -> :ok
      {:ok, other} -> {:error, {:unexpected_response, other}}
      err -> err
    end
  end

  @doc "Stops the Device server for the given id."
  @spec stop(id()) :: :ok
  def stop(id) do
    case whereis(id) do
      {:ok, pid} -> GenServer.stop(pid)
      {:error, _} -> :ok
    end
  end

  # ----- Server callbacks -----

  @impl true
  def init({descriptor, id, opts}) do
    Process.flag(:trap_exit, true)

    with {:ok, usb} <- USB.open(descriptor),
         :ok <- bootstrap_mpsse(usb, opts) do
      {:ok, %__MODULE__{usb: usb, id: id}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:mode, _from, state), do: {:reply, state.mode, state}

  def handle_call({:claim_mode, mode}, _from, %{mode: :none} = state) do
    case conflicting_gpio_pin(state, Map.fetch!(@protocol_pins, mode)) do
      nil -> {:reply, :ok, %{state | mode: mode}}
      pin -> {:reply, {:error, {:pin_busy, pin}}, state}
    end
  end

  def handle_call({:claim_mode, mode}, _from, %{mode: mode} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:claim_mode, _requested}, _from, %{mode: current} = state) do
    {:reply, {:error, {:mode_busy, current}}, state}
  end

  def handle_call(:release_mode, _from, state) do
    {:reply, :ok, %{state | mode: :none}}
  end

  def handle_call({:claim_gpio_pin, pin, direction, initial_value}, _from, state) do
    cond do
      Map.has_key?(state.gpio_pins, pin) ->
        {:reply, {:error, {:pin_busy, pin}}, state}

      pin in Map.fetch!(@protocol_pins, state.mode) ->
        {:reply, {:error, {:pin_reserved_by_protocol, state.mode, pin}}, state}

      true ->
        case apply_pin_change(state, pin, direction, initial_value) do
          {:ok, new_state} ->
            {:reply, :ok, %{new_state | gpio_pins: Map.put(state.gpio_pins, pin, direction)}}

          err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:release_gpio_pin, pin}, _from, state) do
    if Map.has_key?(state.gpio_pins, pin) do
      case apply_pin_change(state, pin, :input, 0) do
        {:ok, new_state} ->
          {:reply, :ok, %{new_state | gpio_pins: Map.delete(state.gpio_pins, pin)}}

        err ->
          {:reply, err, state}
      end
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:write_gpio_pin, pin, value}, _from, state) do
    case Map.get(state.gpio_pins, pin) do
      :output ->
        case apply_pin_change(state, pin, :output, value) do
          {:ok, new_state} -> {:reply, :ok, new_state}
          err -> {:reply, err, state}
        end

      :input ->
        {:reply, {:error, :not_an_output}, state}

      nil ->
        {:reply, {:error, :pin_not_open}, state}
    end
  end

  def handle_call({:read_gpio_pin, pin}, _from, state) do
    if Map.has_key?(state.gpio_pins, pin) do
      case read_pin(state, pin) do
        {:ok, value, new_state} -> {:reply, value, new_state}
        err -> {:reply, err, state}
      end
    else
      {:reply, {:error, :pin_not_open}, state}
    end
  end

  def handle_call({:gpio_pin_direction, pin}, _from, state) do
    {:reply, Map.get(state.gpio_pins, pin), state}
  end

  def handle_call({:set_gpio_pin_direction, pin, direction}, _from, state) do
    if Map.has_key?(state.gpio_pins, pin) do
      bit_value = pin_bit_from_byte(state, pin)

      case apply_pin_change(state, pin, direction, bit_value) do
        {:ok, new_state} ->
          {:reply, :ok, %{new_state | gpio_pins: Map.put(state.gpio_pins, pin, direction)}}

        err ->
          {:reply, err, state}
      end
    else
      {:reply, {:error, :pin_not_open}, state}
    end
  end

  def handle_call({:transaction, command, 0, _timeout}, _from, state) do
    {:reply, USB.write(state.usb, command), state}
  end

  def handle_call({:transaction, command, length, timeout}, _from, state) do
    result =
      with :ok <- USB.write(state.usb, command) do
        USB.read(state.usb, length, timeout)
      end

    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, %{usb: nil}), do: :ok

  def terminate(_reason, %{usb: usb}) do
    USB.close(usb)
    :ok
  end

  # ----- Internals -----

  defp via(id), do: {:via, Registry, {CircuitsFT232H.Registry, id}}

  defp bootstrap_mpsse(usb, opts) do
    latency = Keyword.get(opts, :latency_ms, @default_latency_ms)

    with :ok <- USB.reset(usb),
         :ok <- USB.set_latency_timer(usb, latency),
         :ok <- USB.exit_bitmode(usb),
         :ok <- USB.purge_rx(usb),
         :ok <- USB.purge_tx(usb),
         :ok <- USB.disable_special_characters(usb),
         :ok <- USB.enter_mpsse_mode(usb) do
      configure_mpsse(usb)
    end
  end

  defp configure_mpsse(usb) do
    config =
      IO.iodata_to_binary([
        MPSSE.disable_clock_divide_by_5(),
        MPSSE.disable_adaptive_clocking(),
        MPSSE.disable_3_phase_clocking(),
        MPSSE.loopback_off()
      ])

    USB.write(usb, config)
  end

  defp conflicting_gpio_pin(state, reserved_pins) do
    state.gpio_pins
    |> Map.keys()
    |> Enum.find(&(&1 in reserved_pins))
  end

  # Apply a direction + value change for `pin`, updating the relevant port's
  # tracked state and pushing a SET_BITS_LOW/HIGH to the chip.
  defp apply_pin_change(state, pin, direction, value) when pin in 0..7 do
    bit = 1 <<< pin

    new_value =
      case value do
        1 -> state.adbus_value ||| bit
        0 -> state.adbus_value &&& bnot(bit)
      end

    new_dir =
      case direction do
        :output -> state.adbus_dir ||| bit
        :input -> state.adbus_dir &&& bnot(bit)
      end

    command = MPSSE.set_bits_low(new_value &&& 0xFF, new_dir &&& 0xFF)

    case USB.write(state.usb, command) do
      :ok -> {:ok, %{state | adbus_value: new_value &&& 0xFF, adbus_dir: new_dir &&& 0xFF}}
      err -> err
    end
  end

  defp apply_pin_change(state, pin, direction, value) when pin in 8..15 do
    bit = 1 <<< (pin - 8)

    new_value =
      case value do
        1 -> state.acbus_value ||| bit
        0 -> state.acbus_value &&& bnot(bit)
      end

    new_dir =
      case direction do
        :output -> state.acbus_dir ||| bit
        :input -> state.acbus_dir &&& bnot(bit)
      end

    command = MPSSE.set_bits_high(new_value &&& 0xFF, new_dir &&& 0xFF)

    case USB.write(state.usb, command) do
      :ok -> {:ok, %{state | acbus_value: new_value &&& 0xFF, acbus_dir: new_dir &&& 0xFF}}
      err -> err
    end
  end

  defp read_pin(state, pin) when pin in 0..7 do
    command = IO.iodata_to_binary([MPSSE.get_bits_low(), MPSSE.send_immediate()])

    with :ok <- USB.write(state.usb, command),
         {:ok, <<byte>>} <- USB.read(state.usb, 1) do
      {:ok, byte >>> pin &&& 1, state}
    end
  end

  defp read_pin(state, pin) when pin in 8..15 do
    command = IO.iodata_to_binary([MPSSE.get_bits_high(), MPSSE.send_immediate()])

    with :ok <- USB.write(state.usb, command),
         {:ok, <<byte>>} <- USB.read(state.usb, 1) do
      {:ok, byte >>> (pin - 8) &&& 1, state}
    end
  end

  defp pin_bit_from_byte(state, pin) when pin in 0..7, do: state.adbus_value >>> pin &&& 1
  defp pin_bit_from_byte(state, pin) when pin in 8..15, do: state.acbus_value >>> (pin - 8) &&& 1
end
