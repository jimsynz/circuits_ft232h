defmodule Mix.Tasks.CircuitsFt232h.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "writes the three FT232H backends into config/dev.exs" do
    test_project()
    |> Igniter.compose_task("circuits_ft232h.install", [])
    |> assert_creates("config/dev.exs", """
    import Config
    config :circuits_gpio, default_backend: CircuitsFT232H.GPIO.Backend
    config :circuits_spi, default_backend: CircuitsFT232H.SPI.Backend
    config :circuits_i2c, default_backend: CircuitsFT232H.I2C.Backend
    """)
  end

  test "is idempotent — re-running makes no further changes" do
    test_project()
    |> Igniter.compose_task("circuits_ft232h.install", [])
    |> apply_igniter!()
    |> Igniter.compose_task("circuits_ft232h.install", [])
    |> assert_unchanged()
  end
end
