# CircuitsFT232H

[![Hex.pm](https://img.shields.io/hexpm/v/circuits_ft232h.svg)](https://hex.pm/packages/circuits_ft232h)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Use an [Adafruit FT232H breakout board](https://www.adafruit.com/product/2264)
(or any USB-attached FT232H) as an I2C master, SPI master, or GPIO controller
from your host machine via the
[`circuits_i2c`](https://hex.pm/packages/circuits_i2c),
[`circuits_spi`](https://hex.pm/packages/circuits_spi), and
[`circuits_gpio`](https://hex.pm/packages/circuits_gpio) APIs.

This lets you develop and test I2C/SPI/GPIO device drivers on your laptop with
real hardware on the bus — no Raspberry Pi or Nerves target needed in the loop.

> **Status:** early release. Tested against an Adafruit FT232H breakout on
> Linux. See [`CHANGELOG.md`](CHANGELOG.md) for what's in each version.

## Quick start

```elixir
# mix.exs
def deps do
  [
    {:circuits_ft232h, "~> 0.1"}
  ]
end
```

```elixir
# config/config.exs
import Config

# Pick the backends you actually want. Pulling in the dep is harmless if you
# only enable one or two.
config :circuits_i2c, default_backend: CircuitsFT232H.I2C.Backend
config :circuits_spi, default_backend: CircuitsFT232H.SPI.Backend
config :circuits_gpio, default_backend: CircuitsFT232H.GPIO.Backend
```

Then use the Circuits libraries as usual:

```elixir
# Enumerate
Circuits.I2C.bus_names()
#=> ["ftdi-3:8-i2c"]

# Open + scan
{:ok, i2c} = Circuits.I2C.open("ftdi-3:8-i2c")
Circuits.I2C.detect_devices(i2c)
#=> [0x29]
```

Bus / controller names are `"ftdi-<id>"` where `<id>` is the chip's USB bus
and address (e.g. `"3:8"`). Once FTDI serial numbers are read at init, this
will become the serial string instead.

## How modes share a chip

A single FT232H has one MPSSE engine. We can use it as **either** an I2C
master **or** an SPI master at any one moment — whichever bus is opened
first locks the chip into that mode until it's closed. **GPIO can run
alongside whichever protocol is active**, on any pin the protocol doesn't
reserve:

| Active mode | Reserved pins         | Free for GPIO              |
| ----------- | --------------------- | -------------------------- |
| none        | —                     | `AD0`-`AD7`, `AC0`-`AC7`   |
| I2C         | `AD0`-`AD2`           | `AD3`-`AD7`, `AC0`-`AC7`   |
| SPI         | `AD0`-`AD3`           | `AD4`-`AD7`, `AC0`-`AC7`   |

Opening a GPIO pin reserved by the active protocol fails with
`{:error, {:pin_reserved_by_protocol, mode, pin}}`. Claiming an I2C/SPI
mode while a conflicting GPIO is open fails with
`{:error, {:pin_busy, pin}}`.

## Wiring

The FT232H breakout exposes the MPSSE port on the `D0`-`D7` pins (matching
the silkscreen labels `AD0`-`AD7` in code) and the `C0`-`C7` pins (matching
the labels `AC0`-`AC7`).

### SPI

| Breakout pin | Code label | SPI signal      |
| ------------ | ---------- | --------------- |
| `D0`         | `AD0`      | SCK             |
| `D1`         | `AD1`      | MOSI            |
| `D2`         | `AD2`      | MISO            |
| `D3`         | `AD3`      | CS (active low) |
| `GND`        | —          | GND             |

```elixir
{:ok, spi} = Circuits.SPI.open("ftdi-3:8-spi", mode: 0, speed_hz: 1_000_000)
{:ok, response} = Circuits.SPI.transfer(spi, <<0xAA, 0x55>>)
Circuits.SPI.close(spi)
```

Supported SPI options:

- `:mode` (0..3, default 0). Modes 1 and 3 (`CPHA=1`) enable MPSSE 3-phase
  clocking; the effective SCK is ~2/3 of the requested rate in those modes.
- `:speed_hz` (default 1 MHz). FT232H supports up to 30 MHz.
- `:lsb_first` (default false).
- `:bits_per_word` accepted only when 8.
- `:delay_us` accepted but ignored — MPSSE has no native inter-byte delay.

### I2C

| Breakout pin    | Code label    | I2C signal                |
| --------------- | ------------- | ------------------------- |
| `D0`            | `AD0`         | SCL                       |
| `D1` and `D2`   | `AD1` + `AD2` | SDA (tied together)       |
| `GND`           | —             | GND                       |

I2C requires:

- **`D1` and `D2` jumpered together externally** — the FT232H drives SDA on
  `AD1` and samples it on `AD2`. Without the jumper, reads always come back
  as `0xFF`.
- **External pull-ups on SCL and SDA.** Use 4.7 kΩ for 100 kHz
  buses, 2.2 kΩ for 400 kHz, 1 kΩ for 1 MHz. The
  FT232H's internal pull-ups are far too weak.

```elixir
{:ok, i2c} = Circuits.I2C.open("ftdi-3:8-i2c", speed_hz: 100_000)
{:ok, chip_id} = Circuits.I2C.write_read(i2c, 0x29, <<0x00>>, 1)
Circuits.I2C.close(i2c)
```

Supported I2C options:

- `:speed_hz` (default 100 kHz, max 1 MHz).
- `:clock_stretching` (default `false`) — see below.

I2C transactions run at the requested bus rate via MPSSE 3-phase clocking
(`ENABLE_DRIVE_ZERO` + `ENABLE_3_PHASE_CLOCKING` per FTDI AN_108). On every
bus open, a 16-pulse bus-recovery sequence runs to free any slave stuck
holding SDA low from a previous crashed program.

#### Clock stretching

I2C slaves are allowed to hold SCL low to make the master wait while they
finish internal work (page writes, A/D conversions, etc.). MPSSE doesn't
detect this natively — its clock generator just keeps running. We can fix
this by reusing MPSSE's JTAG "adaptive clocking" feature: with `ADBUS0`
(SCL) externally jumpered to `ADBUS7` (the `RTCK` pin), MPSSE can be told
to pause its clock until `ADBUS7` actually reads high.

Enable per bus:

```elixir
{:ok, i2c} = Circuits.I2C.open("ftdi-3:9-i2c", clock_stretching: true)
```

When `:clock_stretching` is `true`:

- `ADBUS7` is reserved for the lifetime of the bus and rejected for GPIO opens.
- Every I2C transaction is wrapped in `ENABLE_CLK_ADAPTIVE`/`DISABLE_CLK_ADAPTIVE`
  opcodes, leaving the chip free between transactions.

Wiring requirement: a wire jumpering `D0` (SCL) directly to `D7` (the silkscreen
label corresponding to `ADBUS7`).

Note: enabling clock stretching subtly changes the SCL waveform timing. A
few well-behaved slaves with picky tolerances may NACK when adaptive clocking
is on. If you only enable this for slaves that actually need it, you'll be fine.

### GPIO

```elixir
# By label (matches the breakout silkscreen)
{:ok, led} = Circuits.GPIO.open("AD7", :output, initial_value: 0)
Circuits.GPIO.write(led, 1)
Circuits.GPIO.read(led)
Circuits.GPIO.close(led)

# By integer (0..7 = AD0..AD7, 8..15 = AC0..AC7)
{:ok, pin} = Circuits.GPIO.open(12, :input)
Circuits.GPIO.read(pin)

# Fully qualified — required when multiple FT232Hs are attached
{:ok, pin} = Circuits.GPIO.open({"ftdi-3:8", "AD4"}, :output)
```

Pull modes:

- `:not_set` and `:pullup` accepted as no-ops. The FT232H always has weak
  internal pull-ups (~75 kΩ) on inputs.
- `:pulldown` and `:none` return `{:error, :not_supported}` — neither is
  controllable at runtime.

#### GPIO interrupts are emulated

`Circuits.GPIO.set_interrupts/3` is supported, but **be aware that the
FT232H has no hardware-generated pin-change notifications**. We emulate
interrupts by sampling pin state on a fixed interval — by default every
10 ms — and emitting `{:circuits_gpio, gpio_spec, timestamp, value}`
messages on edges.

**Pulses shorter than the poll interval will be missed.** Multiple edges
within a single interval are collapsed into one notification with the final
state. Edge detection is purely host-side polling, not chip hardware.

Configure the poll interval with:

```elixir
config :circuits_ft232h, gpio_poll_interval_ms: 5
```

Lower values reduce missable pulse width but use more USB bandwidth and
CPU. Practical floor is ~2 ms (USB round-trip latency). For fast
signals, use an actual microcontroller — this is a host-side development
tool, not a real-time peripheral.

`:suppress_glitches` is accepted but currently a no-op.

## Installation

You need `libusb-1.0` on the host:

- Debian/Ubuntu: `sudo apt install libusb-1.0-0-dev`
- macOS: `brew install libusb`

### Linux

The kernel auto-binds the `ftdi_sio` driver to the FT232H, exposing it as a
serial port. `CircuitsFT232H` detaches that driver automatically each time
it opens the device — no permanent unbind is needed.

You'll need permission to talk to the USB device. The simplest fix is the
udev rule we ship in [`udev/99-ft232h.rules`](udev/99-ft232h.rules):

```sh
sudo cp udev/99-ft232h.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

The rule combines a `plugdev`-group ownership with the modern `uaccess` tag,
so members of `plugdev` and the current local seat user both get access
without re-login.

### macOS

Works with `libusb` once installed. Apple's built-in FTDI VCP driver
auto-binds similarly to Linux's `ftdi_sio`; the same detach-on-open approach
handles it.

### Windows

Not yet supported.

## Limitations

- **No Windows support** yet.
- **GPIO "interrupts" are emulated via host-side polling** (default 10 ms).
  Pulses shorter than the poll interval will be missed. See the GPIO
  section above.
- **I2C clock stretching is opt-in** and requires an external jumper from
  `D0` (SCL) to `D7`. See the I2C clock-stretching section above.
- **FTDI serial numbers are read** on enumeration and used as the canonical
  chip id when programmed. Chips with a blank EEPROM fall back to
  `\"<bus>:<address>\"`, which is not stable across replugs.
- **`Circuits.I2C.write_read/5`** uses a repeated-start condition; some I2C
  peripherals (notably the Bosch BNO055) don't support repeated-start
  reliably. Use separate `write/4` + `read/4` calls for those devices.
- **`:bits_per_word`** on SPI is hardcoded to 8.
- **`:delay_us`** between SPI transfers is accepted but ignored.

## Documentation

Generated docs are at <https://hexdocs.pm/circuits_ft232h>. Or build them
yourself with `mix docs`.

## Acknowledgements

The MPSSE protocol details, especially the I2C bit-banging tricks
(`DRIVE_ZERO`, 3-phase clocking, the `AD1`/`AD2` SDA tied-pin pattern), and
the FTDI 1-bit-read LSB-positioning quirk, were all reverse-engineered from
[pyftdi](https://github.com/eblot/pyftdi) and FTDI Application Note
[AN_108](https://ftdichip.com/wp-content/uploads/2020/08/AN_108_Command_Processor_for_MPSSE_and_MCU_Host_Bus_Emulation_Modes.pdf).

## GitHub mirror

This repository is mirrored
[on GitHub](https://github.com/jimsynz/circuits_ft232h) from its primary
location [on my Forgejo instance](https://harton.dev/james/circuits_ft232h).
Feel free to raise issues and open PRs on GitHub.

## License

This software is licensed under the terms of the
[Apache 2.0 license](https://www.apache.org/licenses/LICENSE-2.0). See the
[`LICENSE`](LICENSE) file in this repository for the full terms.
