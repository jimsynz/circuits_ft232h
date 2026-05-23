defmodule CircuitsFT232H do
  @moduledoc """
  Use an [Adafruit FT232H breakout](https://www.adafruit.com/product/2264) as an
  I2C master, SPI master, or GPIO controller from your host machine, via the
  [`circuits_i2c`](https://hex.pm/packages/circuits_i2c),
  [`circuits_spi`](https://hex.pm/packages/circuits_spi), and
  [`circuits_gpio`](https://hex.pm/packages/circuits_gpio) APIs.

  Plug the FT232H into a USB port, point one or more of the Circuits libraries
  at the backends supplied by this package, and your existing drivers run
  unchanged against real hardware on your laptop.

      # config/config.exs
      import Config

      config :circuits_i2c, default_backend: CircuitsFT232H.I2C.Backend
      config :circuits_spi, default_backend: CircuitsFT232H.SPI.Backend
      config :circuits_gpio, default_backend: CircuitsFT232H.GPIO.Backend

  A single chip can act as either an I2C *or* an SPI master at any one time
  (first-open wins), and as a GPIO controller alongside whichever protocol is
  active — the `CircuitsFT232H.Device` GenServer enforces this and rejects
  open requests that would conflict.

  See the [README](readme.html) for wiring diagrams, Linux/macOS setup, and
  per-backend caveats.
  """
end
