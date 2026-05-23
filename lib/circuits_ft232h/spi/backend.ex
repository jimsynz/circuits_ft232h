defmodule CircuitsFT232H.SPI.Backend do
  @moduledoc """
  `Circuits.SPI.Backend` implementation that exposes each connected FT232H as
  a SPI bus named `\"ftdi-<id>-spi\"`.

  Configure with:

      config :circuits_spi, default_backend: CircuitsFT232H.SPI.Backend

  Then use `Circuits.SPI.open/2` as you would on a Nerves target. The first
  call for a given chip starts a `CircuitsFT232H.Device` GenServer under
  `CircuitsFT232H.DeviceSupervisor`; the bus then claims the SPI mode lock
  until it is closed.
  """

  @behaviour Circuits.SPI.Backend

  alias CircuitsFT232H.{Device, SPI, USB}
  alias CircuitsFT232H.SPI.Bus

  @impl true
  def bus_names(_opts) do
    case USB.list_devices() do
      {:ok, descriptors} ->
        Enum.map(descriptors, fn d -> SPI.bus_name(Device.id_for(d)) end)

      _ ->
        []
    end
  end

  @impl true
  def open(bus_name, opts) do
    with {:ok, descriptor} <- SPI.find_descriptor(bus_name),
         {:ok, _pid} <- Device.find_or_start(descriptor),
         id = Device.id_for(descriptor),
         {:ok, config} <- SPI.build_config(opts),
         :ok <- Device.claim_mode(id, :spi),
         :ok <- configure_or_release(id, config) do
      {:ok, %Bus{id: id, config: config}}
    end
  end

  @impl true
  def info, do: %{backend: __MODULE__}

  defp configure_or_release(id, config) do
    case SPI.configure(id, config) do
      :ok ->
        :ok

      err ->
        Device.release_mode(id)
        err
    end
  end
end
