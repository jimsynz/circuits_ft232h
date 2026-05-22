# CircuitsFT232H

[![Hex.pm](https://img.shields.io/hexpm/v/circuits_ft232h.svg)](https://hex.pm/packages/circuits_ft232h)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Use an [Adafruit FT232H breakout board](https://www.adafruit.com/product/2264)
as an I2C or SPI master from your host machine, via the
[`circuits_i2c`](https://hex.pm/packages/circuits_i2c) and
[`circuits_spi`](https://hex.pm/packages/circuits_spi) APIs.

This lets you develop and test I2C/SPI device drivers on your laptop, with
real hardware on the bus, without needing a Raspberry Pi or Nerves target in
the loop.

> **Status:** very early — see [CHANGELOG.md](CHANGELOG.md) for what works.

## Usage

```elixir
# config/config.exs
import Config

config :circuits_i2c, default_backend: CircuitsFT232H.I2C.Backend
config :circuits_spi, default_backend: CircuitsFT232H.SPI.Backend
```

Then use `Circuits.I2C` / `Circuits.SPI` as normal:

```elixir
{:ok, i2c} = Circuits.I2C.open("ftdi-A-i2c")
Circuits.I2C.detect_devices(i2c)
```

A single FT232H can act as either an I2C *or* an SPI master at any one time —
whichever bus is opened first locks the chip into that mode until it's closed.

## Wiring

The FT232H breakout exposes the MPSSE port on the `D0`-`D7` pins.

### SPI

| FT232H pin | SPI signal |
|------------|------------|
| `D0`       | SCK        |
| `D1`       | MOSI       |
| `D2`       | MISO       |
| `D3`       | CS (active low) |
| `GND`      | GND        |

### I2C

| FT232H pin | I2C signal |
|------------|------------|
| `D0`       | SCL        |
| `D1` + `D2` *(tied together)* | SDA |
| `GND`      | GND        |

I2C requires:

- **`D1` and `D2` jumpered together externally** — the FT232H drives SDA on
  `D1` and samples it on `D2`. Without the jumper, reads will always come back
  as `0xFF`.
- **External pull-ups on SCL and SDA.** Use 4.7&nbsp;kΩ for 100&nbsp;kHz buses,
  2.2&nbsp;kΩ for 400&nbsp;kHz, 1&nbsp;kΩ for 1&nbsp;MHz. The FT232H's internal
  pull-ups are far too weak.

## Installation

Add `circuits_ft232h` to your dependencies:

```elixir
def deps do
  [
    {:circuits_ft232h, "~> 0.1"}
  ]
end
```

You'll also need `libusb-1.0` installed on the host:

- Debian/Ubuntu: `sudo apt install libusb-1.0-0-dev`
- macOS: `brew install libusb`

### Linux

On Linux the kernel auto-binds the `ftdi_sio` driver to the FT232H, exposing
it as a serial port. `CircuitsFT232H` detaches that driver automatically each
time it opens the device, so no permanent unbind is needed.

You will need permission to talk to the USB device. The simplest fix is a
`udev` rule — drop the following into `/etc/udev/rules.d/99-ft232h.rules` and
run `sudo udevadm control --reload`:

```
SUBSYSTEM=="usb", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6014", \
  MODE="0660", GROUP="plugdev", TAG+="uaccess"
```

Add yourself to the `plugdev` group, log out and back in.

### macOS

Works with `libusb` once installed. Apple's built-in FTDI VCP driver auto-binds
similarly to Linux's `ftdi_sio`; the same detach-on-open approach handles it.

### Windows

Not yet supported.

## Documentation generation

Documentation can be generated with
[ExDoc](https://github.com/elixir-lang/ex_doc) and published on
[HexDocs](https://hexdocs.pm). Once published, the docs can be found at
<https://hexdocs.pm/circuits_ft232h>.

## GitHub mirror

This repository is mirrored [on GitHub](https://github.com/jimsynz/circuits_ft232h)
from its primary location [on my Forgejo instance](https://harton.dev/james/circuits_ft232h).
Feel free to raise issues and open PRs on GitHub.

## License

This software is licensed under the terms of the
[Apache 2.0 license](https://www.apache.org/licenses/LICENSE-2.0). See the
[`LICENSE`](LICENSE) file in this repository for the full terms.
