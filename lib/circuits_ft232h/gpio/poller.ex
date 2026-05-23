defmodule CircuitsFT232H.GPIO.Poller do
  @moduledoc """
  Per-chip polling GenServer that **emulates** GPIO interrupts.

  > ### These are NOT hardware interrupts {: .warning}
  >
  > The FT232H has no hardware-generated pin-change notifications. We sample
  > the pin state on a fixed interval and emit
  > `{:circuits_gpio, gpio_spec, timestamp, value}` messages when subscribed
  > pins change in the desired direction.
  >
  > **Pulses shorter than the poll interval (default 10 ms) will be
  > missed.** Multiple edges within a single interval are collapsed into one
  > notification with the final state.

  One Poller per chip is started lazily on the first interrupt subscription
  and registered in `CircuitsFT232H.Registry` under `{:poller, device_id}`.
  When the last subscription goes away the Poller stops itself.

  Each poll tick is one USB round-trip (~1 ms) that reads both the
  ADBUS and ACBUS ports in a single MPSSE transaction. All subscribed pins
  on the chip are sampled together, so adding more subscribed pins does
  *not* increase USB load.

  ## Tuning the poll interval

  The default interval is **10 ms** (~100 Hz sampling). To change
  it:

      config :circuits_ft232h, gpio_poll_interval_ms: 5

  Lower values reduce the size of pulses you can miss but cost more USB
  bandwidth and CPU. Practical floor is ~2 ms (the USB round-trip
  time). For mechanical buttons 10-20 ms is plenty; for fast signals
  you should look at an actual microcontroller.

  ## Other notes

    * `:suppress_glitches` is accepted but currently a no-op — there's only
      one sample per poll tick. Filtering glitches shorter than the poll
      interval would require over-sampling, which isn't implemented.
    * Subscriptions are auto-removed if the receiving process dies.
  """

  use GenServer

  alias CircuitsFT232H.Device
  alias CircuitsFT232H.GPIO

  require Logger

  @default_interval_ms 10
  @app :circuits_ft232h

  defstruct device_id: nil,
            subscriptions: %{},
            monitors: %{},
            timer: nil,
            interval_ms: @default_interval_ms

  @typedoc "Per-pin subscription record."
  @type subscription :: %{
          trigger: :rising | :falling | :both,
          receiver: pid(),
          suppress_glitches: boolean(),
          last_value: 0..1
        }

  @typedoc "Poller GenServer state."
  @type t :: %__MODULE__{
          device_id: Device.id(),
          subscriptions: %{optional(Device.pin()) => subscription()},
          monitors: %{optional(pid()) => reference()},
          timer: reference() | nil,
          interval_ms: pos_integer()
        }

  # ----- Public API -----

  @doc """
  Subscribes the given receiver to edge notifications for `pin` on the chip
  identified by `device_id`. Starts the Poller if it isn't running.

  `trigger` is one of `:rising`, `:falling`, `:both`.

  Options:
    * `:receiver` (default the calling process) — the pid (or registered
      name) that will receive `{:circuits_gpio, gpio_spec, timestamp, value}`
      messages.
    * `:suppress_glitches` (default `true`) — accepted but currently a
      no-op; see the moduledoc.
  """
  @spec subscribe(Device.id(), Device.pin(), :rising | :falling | :both, keyword()) ::
          :ok | {:error, term()}
  def subscribe(device_id, pin, trigger, opts \\ [])
      when trigger in [:rising, :falling, :both] do
    with {:ok, pid} <- ensure_started(device_id) do
      caller = self()
      receiver = resolve_receiver(Keyword.get(opts, :receiver, caller))
      suppress = Keyword.get(opts, :suppress_glitches, true)
      GenServer.call(pid, {:subscribe, pin, trigger, receiver, suppress})
    end
  end

  @doc """
  Removes any active subscription for `pin` on the chip identified by
  `device_id`. The Poller stops itself once the last subscription goes away.
  """
  @spec unsubscribe(Device.id(), Device.pin()) :: :ok
  def unsubscribe(device_id, pin) do
    case whereis(device_id) do
      {:ok, pid} ->
        # The Poller stops itself when its last subscription goes away, so
        # an unsubscribe arriving during that shutdown window will hit a
        # dying GenServer. Treat that as already-unsubscribed.
        try do
          GenServer.call(pid, {:unsubscribe, pin})
        catch
          :exit, _ -> :ok
        end

      {:error, :not_started} ->
        :ok
    end
  end

  @doc "Returns the current subscriptions table for inspection in tests."
  @spec subscriptions(Device.id()) :: %{optional(Device.pin()) => subscription()}
  def subscriptions(device_id) do
    case whereis(device_id) do
      {:ok, pid} -> GenServer.call(pid, :subscriptions)
      {:error, :not_started} -> %{}
    end
  end

  # ----- Lifecycle -----

  @doc false
  def start_link(device_id) do
    GenServer.start_link(__MODULE__, device_id, name: via(device_id))
  end

  @doc false
  def child_spec(device_id) do
    %{
      id: {:poller, device_id},
      start: {__MODULE__, :start_link, [device_id]},
      restart: :transient,
      type: :worker
    }
  end

  @spec whereis(Device.id()) :: {:ok, pid()} | {:error, :not_started}
  def whereis(device_id) do
    case Registry.lookup(CircuitsFT232H.Registry, {:poller, device_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_started}
    end
  end

  defp ensure_started(device_id) do
    case whereis(device_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_started} ->
        case DynamicSupervisor.start_child(
               CircuitsFT232H.DeviceSupervisor,
               {__MODULE__, device_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          err -> err
        end
    end
  end

  defp via(device_id), do: {:via, Registry, {CircuitsFT232H.Registry, {:poller, device_id}}}

  defp resolve_receiver(receiver) when is_pid(receiver), do: receiver

  defp resolve_receiver(receiver) when is_atom(receiver),
    do: Process.whereis(receiver) || receiver

  # ----- Server -----

  @impl true
  def init(device_id) do
    Process.flag(:trap_exit, true)

    interval =
      Application.get_env(@app, :gpio_poll_interval_ms, @default_interval_ms)

    {:ok,
     %__MODULE__{
       device_id: device_id,
       interval_ms: interval
     }}
  end

  @impl true
  def handle_call({:subscribe, pin, trigger, receiver, suppress}, _from, state) do
    case sample_pin(state.device_id, pin) do
      {:ok, value} when value in 0..1 ->
        subscription = %{
          trigger: trigger,
          receiver: receiver,
          suppress_glitches: suppress,
          last_value: value
        }

        new_subs = Map.put(state.subscriptions, pin, subscription)
        new_monitors = ensure_monitor(state.monitors, receiver)

        {:reply, :ok,
         %{state | subscriptions: new_subs, monitors: new_monitors}
         |> ensure_polling()}

      err ->
        {:reply, err, state}
    end
  end

  def handle_call({:unsubscribe, pin}, _from, state) do
    {removed, remaining} = Map.pop(state.subscriptions, pin)
    new_monitors = release_monitor(state.monitors, removed, remaining)
    new_state = %{state | subscriptions: remaining, monitors: new_monitors}

    if map_size(remaining) == 0 do
      cancel_timer(new_state.timer)
      {:stop, :normal, :ok, %{new_state | timer: nil}}
    else
      {:reply, :ok, new_state}
    end
  end

  def handle_call(:subscriptions, _from, state) do
    {:reply, state.subscriptions, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state =
      state
      |> do_poll()
      |> schedule_poll()

    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    remaining =
      Map.reject(state.subscriptions, fn {_pin, sub} -> sub.receiver == pid end)

    new_monitors =
      state.monitors
      |> Map.delete(pid)
      |> Map.reject(fn {_p, r} -> r == ref end)

    new_state = %{state | subscriptions: remaining, monitors: new_monitors}

    if map_size(remaining) == 0 do
      cancel_timer(new_state.timer)
      {:stop, :normal, %{new_state | timer: nil}}
    else
      {:noreply, new_state}
    end
  end

  # ----- Polling internals -----

  defp ensure_polling(%{timer: nil} = state) when map_size(state.subscriptions) > 0 do
    schedule_poll(state)
  end

  defp ensure_polling(state), do: state

  defp schedule_poll(state) do
    cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :poll, state.interval_ms)}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp do_poll(%{subscriptions: subs} = state) when map_size(subs) == 0, do: state

  defp do_poll(state) do
    case Device.read_gpio_bytes(state.device_id) do
      {:ok, {low, high}} ->
        process_samples(state, low, high)

      {:error, reason} ->
        Logger.debug(fn -> "CircuitsFT232H.GPIO.Poller read failed: #{inspect(reason)}" end)
        state
    end
  end

  defp process_samples(state, low, high) do
    timestamp = System.monotonic_time()

    Enum.reduce(state.subscriptions, state, fn {pin, sub}, acc ->
      current = pin_value(pin, low, high)
      maybe_emit(acc, pin, sub, current, timestamp)
    end)
  end

  defp pin_value(pin, low, _high) when pin in 0..7, do: bit_at(low, pin)
  defp pin_value(pin, _low, high) when pin in 8..15, do: bit_at(high, pin - 8)

  defp bit_at(byte, offset), do: byte |> Bitwise.bsr(offset) |> Bitwise.band(1)

  defp maybe_emit(state, _pin, %{last_value: current}, current, _ts), do: state

  defp maybe_emit(state, pin, sub, new_value, timestamp) do
    edge = if new_value == 1, do: :rising, else: :falling

    if matches_trigger?(sub.trigger, edge) do
      send(
        sub.receiver,
        {:circuits_gpio, gpio_spec_for(state.device_id, pin), timestamp, new_value}
      )
    end

    put_in(state.subscriptions[pin].last_value, new_value)
  end

  defp matches_trigger?(:both, _), do: true
  defp matches_trigger?(:rising, :rising), do: true
  defp matches_trigger?(:falling, :falling), do: true
  defp matches_trigger?(_, _), do: false

  defp gpio_spec_for(device_id, pin), do: {device_id, GPIO.label(pin)}

  defp sample_pin(device_id, pin) do
    with {:ok, {low, high}} <- Device.read_gpio_bytes(device_id) do
      {:ok, pin_value(pin, low, high)}
    end
  end

  # ----- Monitor management -----

  defp ensure_monitor(monitors, receiver) when is_pid(receiver) do
    case Map.fetch(monitors, receiver) do
      {:ok, _ref} -> monitors
      :error -> Map.put(monitors, receiver, Process.monitor(receiver))
    end
  end

  defp ensure_monitor(monitors, _receiver), do: monitors

  defp release_monitor(monitors, nil, _remaining), do: monitors

  defp release_monitor(monitors, removed_sub, remaining) do
    receiver = removed_sub.receiver
    still_subscribed? = Enum.any?(remaining, fn {_pin, sub} -> sub.receiver == receiver end)

    if still_subscribed? do
      monitors
    else
      case Map.pop(monitors, receiver) do
        {nil, monitors} ->
          monitors

        {ref, monitors} ->
          Process.demonitor(ref, [:flush])
          monitors
      end
    end
  end
end
