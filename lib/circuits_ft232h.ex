defmodule CircuitsFT232H do
  @moduledoc """
  Use an [Adafruit FT232H breakout](https://www.adafruit.com/product/2264) as an
  I2C or SPI master from your host machine, via the
  [`circuits_i2c`](https://hex.pm/packages/circuits_i2c) and
  [`circuits_spi`](https://hex.pm/packages/circuits_spi) APIs.

  Plug the FT232H into a USB port, point `circuits_i2c` and/or `circuits_spi` at
  the backends supplied by this package, and your existing drivers run unchanged
  against real hardware on your laptop.

      # config/config.exs
      import Config

      config :circuits_i2c, default_backend: CircuitsFT232H.I2C.Backend
      config :circuits_spi, default_backend: CircuitsFT232H.SPI.Backend

  See the [README](readme.html) for wiring diagrams, Linux/macOS setup, and
  per-mode caveats.
  """
end
