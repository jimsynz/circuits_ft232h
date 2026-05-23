if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.CircuitsFt232h.Install do
    @moduledoc """
    Configures the host application to use the FT232H backends for
    `circuits_i2c`, `circuits_spi`, and `circuits_gpio` in the `:dev`
    environment.

        mix igniter.install circuits_ft232h
    """
    @shortdoc "Wire up CircuitsFT232H backends in config/dev.exs"

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :circuits_ft232h,
        example: "mix igniter.install circuits_ft232h",
        schema: [],
        aliases: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> Igniter.Project.Config.configure(
        "dev.exs",
        :circuits_i2c,
        [:default_backend],
        CircuitsFT232H.I2C.Backend
      )
      |> Igniter.Project.Config.configure(
        "dev.exs",
        :circuits_spi,
        [:default_backend],
        CircuitsFT232H.SPI.Backend
      )
      |> Igniter.Project.Config.configure(
        "dev.exs",
        :circuits_gpio,
        [:default_backend],
        CircuitsFT232H.GPIO.Backend
      )
    end
  end
else
  defmodule Mix.Tasks.CircuitsFt232h.Install do
    @moduledoc "Install task for CircuitsFT232H — requires the `:igniter` dep."
    @shortdoc "Wire up CircuitsFT232H backends in config/dev.exs"

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      `mix circuits_ft232h.install` requires the `igniter` package.

      Add `{:igniter, "~> 0.8"}` to your deps and run `mix deps.get`, or
      install via `mix igniter.install circuits_ft232h`.
      """)

      exit({:shutdown, 1})
    end
  end
end
