defmodule CircuitsFT232H.I2C.Backend do
  @moduledoc """
  `Circuits.I2C.Backend` implementation that exposes each connected FT232H as
  an I2C bus named `\"ftdi-<id>-i2c\"`.

  Configure with:

      config :circuits_i2c, default_backend: CircuitsFT232H.I2C.Backend

  Then use `Circuits.I2C.open/2` as you would on a Nerves target. The first
  call for a given chip starts a `CircuitsFT232H.Device` GenServer under
  `CircuitsFT232H.DeviceSupervisor`; the bus then claims the I2C mode lock
  until it is closed.
  """

  @behaviour Circuits.I2C.Backend

  alias CircuitsFT232H.{Device, I2C, USB}
  alias CircuitsFT232H.I2C.Bus

  @impl true
  def bus_names(_opts) do
    case USB.list_devices() do
      {:ok, descriptors} ->
        Enum.map(descriptors, fn d -> I2C.bus_name(Device.id_for(d)) end)

      _ ->
        []
    end
  end

  @impl true
  def open(bus_name, opts) do
    with {:ok, descriptor} <- I2C.find_descriptor(bus_name),
         {:ok, _pid} <- Device.find_or_start(descriptor),
         id = Device.id_for(descriptor),
         {:ok, config} <- I2C.build_config(opts),
         :ok <- Device.claim_mode(id, :i2c, I2C.extra_reserved_pins(config)),
         :ok <- configure_or_release(id, config) do
      {:ok, %Bus{id: id, config: config}}
    end
  end

  @impl true
  def info, do: %{backend: __MODULE__}

  defp configure_or_release(id, config) do
    case I2C.configure(id, config) do
      :ok ->
        :ok

      err ->
        Device.release_mode(id)
        err
    end
  end
end
