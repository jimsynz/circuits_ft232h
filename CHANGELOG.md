# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [v0.1.0](https://harton.dev/james/circuits_ft232h) (2026-05-23)

### Features

- Initial release.
- `CircuitsFT232H.USB` transport over the [`:usb`](https://hex.pm/packages/usb)
  (libusb) NIF. Enumeration filtered to FTDI VID `0x0403` / PID `0x6014`,
  auto-detach of the `ftdi_sio` kernel driver on open, FTDI SIO control
  transfers, bulk read/write with modem-status-byte stripping, and a
  bulk-read loop that survives the FT232H's latency-timer heartbeat.
- `CircuitsFT232H.MPSSE` pure-function encoder for the FT232H's MPSSE
  command stream — opcodes, clock divisor math, byte/bit shifts in every
  edge/order combination, open-drain (`DRIVE_ZERO`), 3-phase clocking,
  `BAD_COMMAND` parsing. Tested without hardware.
- `CircuitsFT232H.Device` GenServer that owns the USB handle per chip,
  serialises all MPSSE traffic, enforces an I2C-vs-SPI mode lock, and
  tracks per-pin GPIO allocation. Started under
  `CircuitsFT232H.DeviceSupervisor` and addressed by an id (currently
  `"<bus>:<address>"`).
- `CircuitsFT232H.SPI.Backend` — `Circuits.SPI.Backend` implementation.
  Honours `:mode` (0-3), `:speed_hz` (up to 30 MHz), `:lsb_first`.
- `CircuitsFT232H.I2C.Backend` — `Circuits.I2C.Backend` implementation.
  Honours `:speed_hz` (100 kHz default, up to 1 MHz). Includes a 16-pulse
  bus-recovery sequence on each open to free slaves stuck mid-transaction.
- `CircuitsFT232H.GPIO.Backend` — `Circuits.GPIO.Backend` implementation.
  Exposes all 16 GPIO pins (`AD0`-`AD7`, `AC0`-`AC7`) and coexists with an
  active I2C or SPI bus, rejecting opens on protocol-reserved pins.
- `CircuitsFT232H.GPIO.Poller` — host-side polling GenServer that emulates
  GPIO interrupts. The FT232H has no hardware pin-change notifications;
  pulses shorter than the poll interval (default 10&nbsp;ms) will be missed.
  Configurable via `config :circuits_ft232h, gpio_poll_interval_ms: N`.
- `udev/99-ft232h.rules` shipped in-repo for non-root USB access on Linux.

### Known limitations

- Windows is not yet supported.
- GPIO interrupts are not supported (the FT232H has no hardware pin-change
  notifications; a polling implementation is planned).
- FTDI serial numbers aren't read yet; chips are identified by `bus:address`
  which changes across replugs.
- I2C clock stretching is not detected.
- SPI `:bits_per_word` is hardcoded to 8 and `:delay_us` is ignored.
- `write_read/5` uses a repeated-start condition; some I2C peripherals (e.g.
  the Bosch BNO055) don't support repeated-start and need separate
  `write/4` + `read/4` calls.
