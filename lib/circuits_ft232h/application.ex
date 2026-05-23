defmodule CircuitsFT232H.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: CircuitsFT232H.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: CircuitsFT232H.DeviceSupervisor}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: CircuitsFT232H.Supervisor)
  end
end
