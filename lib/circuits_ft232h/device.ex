defmodule CircuitsFT232H.Device do
  @moduledoc """
  Composes `CircuitsFT232H.USB` and `CircuitsFT232H.MPSSE` to drive an FT232H
  through its initialisation sequence and confirm it's responsive.

  These functions are stateless. They take an open `CircuitsFT232H.USB` handle
  and issue the right SIO control transfers and MPSSE configuration commands.
  The `CircuitsFT232H.Device` GenServer (coming in a later step) will own the
  handle and serialise access, but the protocol is defined here.
  """

  alias CircuitsFT232H.{MPSSE, USB}

  @default_latency_ms 16

  @doc """
  Drives the FT232H through the SIO and MPSSE init sequence.

  After this returns `:ok` the chip is in MPSSE mode with a clean baseline:
  60&nbsp;MHz base clock selected, adaptive clocking off, 3-phase clocking
  off, internal loopback off. SCK is left at its post-reset minimum
  (~458&nbsp;Hz). The SPI and I2C backends layer their mode-specific config
  (clock divisor, open-drain, idle pin state) on top.

  Options:
    * `:latency_ms` (default `#{@default_latency_ms}`) — USB latency timer in
      milliseconds. Lower values make `read/3` snappier at the cost of more
      USB traffic.
  """
  @spec init_mpsse(USB.t(), keyword()) :: :ok | {:error, term()}
  def init_mpsse(%USB{} = usb, opts \\ []) do
    latency = Keyword.get(opts, :latency_ms, @default_latency_ms)

    with :ok <- USB.reset(usb),
         :ok <- USB.set_latency_timer(usb, latency),
         :ok <- USB.exit_bitmode(usb),
         :ok <- USB.purge_rx(usb),
         :ok <- USB.purge_tx(usb),
         :ok <- USB.disable_special_characters(usb),
         :ok <- USB.enter_mpsse_mode(usb) do
      configure_mpsse(usb)
    end
  end

  @doc """
  Verifies the chip is in MPSSE mode and responding to commands.

  Sends an unrecognised opcode (`0xAB`) and expects the standard FTDI
  bad-command echo (`0xFA 0xAB`) back. If anything else comes back the chip
  is in the wrong state or has been silently reset.
  """
  @spec validate(USB.t()) :: :ok | {:error, term()}
  def validate(%USB{} = usb) do
    bogus = 0xAB

    with :ok <- USB.write(usb, <<bogus, MPSSE.send_immediate()::binary>>),
         {:ok, response} <- USB.read(usb, 2) do
      case response do
        <<0xFA, ^bogus>> -> :ok
        _ -> {:error, {:unexpected_response, response}}
      end
    end
  end

  defp configure_mpsse(usb) do
    config =
      IO.iodata_to_binary([
        MPSSE.disable_clock_divide_by_5(),
        MPSSE.disable_adaptive_clocking(),
        MPSSE.disable_3_phase_clocking(),
        MPSSE.loopback_off()
      ])

    USB.write(usb, config)
  end
end
