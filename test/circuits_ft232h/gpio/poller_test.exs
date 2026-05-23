defmodule CircuitsFT232H.GPIO.PollerTest do
  use ExUnit.Case, async: false

  alias Circuits.GPIO.Handle
  alias CircuitsFT232H.GPIO.Backend
  alias CircuitsFT232H.GPIO.Poller

  @moduletag :hardware

  setup do
    on_exit(fn ->
      DynamicSupervisor.which_children(CircuitsFT232H.DeviceSupervisor)
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(CircuitsFT232H.DeviceSupervisor, pid)

        _ ->
          :ok
      end)
    end)

    :ok
  end

  describe "subscribe / unsubscribe" do
    test "subscribing kicks off polling, unsubscribing stops it" do
      {:ok, handle} = Backend.open("AD4", :output, initial_value: 0)
      controller = handle.controller

      assert {:error, :not_started} = Poller.whereis(controller)

      assert :ok = Handle.set_interrupts(handle, :both, [])
      assert {:ok, pid} = Poller.whereis(controller)
      assert is_pid(pid)
      assert Map.has_key?(Poller.subscriptions(controller), 4)

      assert :ok = Handle.set_interrupts(handle, :none, [])
      :timer.sleep(20)
      assert {:error, :not_started} = Poller.whereis(controller)

      :ok = Handle.close(handle)
    end

    test "closing the handle releases any active subscription" do
      {:ok, handle} = Backend.open("AD4", :output, initial_value: 0)
      :ok = Handle.set_interrupts(handle, :both, [])
      :ok = Handle.close(handle)
      :timer.sleep(20)
      assert {:error, :not_started} = Poller.whereis(handle.controller)
    end
  end

  describe "edge detection" do
    test "delivers :rising and :falling events when the pin toggles" do
      {:ok, handle} = Backend.open("AD4", :output, initial_value: 0)
      :ok = Handle.set_interrupts(handle, :both, [])

      toggle_with_settle(handle, [1, 0, 1])

      messages = drain_messages(500)

      values = Enum.map(messages, fn {:circuits_gpio, _, _, v} -> v end)
      assert 1 in values
      assert 0 in values

      :ok = Handle.close(handle)
    end

    test ":rising trigger only emits on low->high transitions" do
      {:ok, handle} = Backend.open("AD4", :output, initial_value: 0)
      :ok = Handle.set_interrupts(handle, :rising, [])

      toggle_with_settle(handle, [1, 0, 1, 0, 1])

      messages = drain_messages(500)
      values = Enum.map(messages, fn {:circuits_gpio, _, _, v} -> v end)
      assert values != []
      assert Enum.all?(values, &(&1 == 1))

      :ok = Handle.close(handle)
    end

    test ":falling trigger only emits on high->low transitions" do
      {:ok, handle} = Backend.open("AD4", :output, initial_value: 1)
      :ok = Handle.set_interrupts(handle, :falling, [])

      toggle_with_settle(handle, [0, 1, 0, 1, 0])

      messages = drain_messages(500)
      values = Enum.map(messages, fn {:circuits_gpio, _, _, v} -> v end)
      assert values != []
      assert Enum.all?(values, &(&1 == 0))

      :ok = Handle.close(handle)
    end

    test "events carry the {controller, label} gpio spec" do
      {:ok, handle} = Backend.open("AC3", :output, initial_value: 0)
      :ok = Handle.set_interrupts(handle, :both, [])

      toggle_with_settle(handle, [1])

      assert [{:circuits_gpio, {_, "AC3"}, _, 1} | _] = drain_messages(500)

      :ok = Handle.close(handle)
    end
  end

  describe "receiver lifecycle" do
    test "subscriptions tied to a dead process are cleaned up" do
      {:ok, handle} = Backend.open("AD4", :output, initial_value: 0)
      {:ok, subscriber} = spawn_subscriber(handle.controller, 4)
      assert {:ok, _} = Poller.whereis(handle.controller)

      Process.exit(subscriber, :kill)

      assert :ok = wait_for_no_poller(handle.controller, 500)
      :ok = Handle.close(handle)
    end
  end

  defp spawn_subscriber(controller, pin) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Poller.subscribe(controller, pin, :both, [])
        send(parent, :subscribed)

        receive do
          :stop -> :ok
        end
      end)

    receive do
      :subscribed -> {:ok, pid}
    after
      1000 -> flunk("subscriber didn't start")
    end
  end

  defp wait_for_no_poller(controller, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_no_poller(controller, deadline)
  end

  defp do_wait_for_no_poller(controller, deadline) do
    case Poller.whereis(controller) do
      {:error, :not_started} ->
        :ok

      {:ok, _pid} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          :timer.sleep(10)
          do_wait_for_no_poller(controller, deadline)
        end
    end
  end

  # Write a sequence of values to the pin with enough delay between each that
  # the 10 ms-default poller has a chance to sample every state.
  defp toggle_with_settle(handle, values) do
    Enum.each(values, fn v ->
      :ok = Handle.write(handle, v)
      :timer.sleep(30)
    end)
  end

  defp drain_messages(deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_drain([], deadline)
  end

  defp do_drain(acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:circuits_gpio, _, _, _} = msg ->
        do_drain([msg | acc], deadline)
    after
      remaining -> Enum.reverse(acc)
    end
  end
end
