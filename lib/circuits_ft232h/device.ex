defmodule CircuitsFT232H.Device do
  @moduledoc """
  A GenServer that owns the USB handle to one FT232H and serialises all
  traffic with it.

  Started once per physical chip and registered in `CircuitsFT232H.Registry`
  by the device's id (currently `"<bus>:<address>"` — once we read FTDI
  serial numbers this becomes the serial). All MPSSE traffic flows through
  `transaction/4`, so the chip sees commands from at most one process at a
  time.

  The Device also enforces the I2C/SPI mutual-exclusion lock: a chip is in
  one of three modes — `:none`, `:i2c`, or `:spi` — and `claim_mode/2`
  returns `{:error, {:mode_busy, current}}` if the requested mode conflicts
  with whatever's currently claimed. GPIO operations are *not* mode-gated;
  they can run alongside whichever protocol is active (subject to pin
  availability, enforced in a later step).
  """

  use GenServer

  alias CircuitsFT232H.{MPSSE, USB}
  alias CircuitsFT232H.USB.Descriptor

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

  defstruct [:usb, :id, mode: :none]

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

  Returns the existing pid if one is found. Use this from the I2C/SPI
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
  """
  @spec claim_mode(id(), :i2c | :spi) :: :ok | {:error, {:mode_busy, mode()}}
  def claim_mode(id, requested) when requested in [:i2c, :spi] do
    GenServer.call(via(id), {:claim_mode, requested})
  end

  @doc "Releases whichever mode the chip is currently locked into."
  @spec release_mode(id()) :: :ok
  def release_mode(id), do: GenServer.call(via(id), :release_mode)

  # ----- Transactions -----

  @doc """
  Sends `command` (an MPSSE byte stream) to the chip and optionally reads
  `response_length` bytes back.

  `command` may be any `iodata`. If `response_length` is `0` the call
  returns `:ok` once the bytes have been queued to the chip. Otherwise it
  returns `{:ok, binary}` of exactly `response_length` payload bytes (the
  USB status prefix is stripped).
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
    {:reply, :ok, %{state | mode: mode}}
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
end
