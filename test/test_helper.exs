# Hardware tests are tagged to identify which physical rig they require:
#
#   :hardware       — any FT232H plugged in; no specific wiring (init / validate /
#                     mode-lock smoke tests)
#   :hardware_spi   — SPI loopback rig: AD1 (MOSI) jumpered to AD2 (MISO)
#   :hardware_i2c   — I2C rig: AD1 + AD2 tied together as SDA, external pull-ups
#                     on AD0 (SCL) and SDA, and a known I2C peripheral on the bus
#
# SPI and I2C wirings are mutually exclusive — you can't have both rigged at
# once — so run them separately:
#
#   mix test --include hardware --include hardware_spi
#   mix test --include hardware --include hardware_i2c
#
# Plain `mix test` skips everything that needs hardware.

ExUnit.start(exclude: [:hardware, :hardware_spi, :hardware_i2c])
