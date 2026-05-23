defmodule CircuitsFT232H.USB do
  @moduledoc """
  Thin USB transport layer for the FT232H.

  Wraps the [`:usb`](https://hex.pm/packages/usb) NIF (libusb) with
  FT232H-specific endpoint addresses, FTDI SIO control-transfer helpers, and
  modem-status-byte stripping for bulk reads.

  This module is internal — higher layers (`CircuitsFT232H.MPSSE`,
  `CircuitsFT232H.Device`) compose it into something useful. You normally
  shouldn't need to call it directly.
  """

  alias CircuitsFT232H.USB.Descriptor

  require Logger

  # FTDI USB identifiers
  @ftdi_vendor_id 0x0403
  @ft232h_product_id 0x6014

  # FT232H is a single-channel chip — one interface, two bulk endpoints
  @interface_number 0
  @bulk_in_endpoint 0x81
  @bulk_out_endpoint 0x02

  # bmRequestType byte for FTDI vendor requests (host-to-device)
  @request_type_out 0x40

  # FTDI SIO request opcodes (FTDI AN_232B-04)
  @sio_request_reset 0x00
  @sio_request_set_event_char 0x06
  @sio_request_set_error_char 0x07
  @sio_request_set_latency_timer 0x09
  @sio_request_set_bitmode 0x0B

  # SIO_RESET wValue selectors
  @sio_reset_sio 0x00
  @sio_reset_purge_rx 0x01
  @sio_reset_purge_tx 0x02

  # SIO_SET_BITMODE high byte
  @bitmode_reset 0x00
  @bitmode_mpsse 0x02

  # Every bulk-IN packet from FT232H is prefixed with 2 modem-status bytes.
  @modem_status_size 2

  # FT232H on USB 2.0 high-speed has a 512-byte bulk packet size. On a USB 1.1
  # hub it'd drop to 64; we negotiate the right value from the device speed on
  # open/2.
  @high_speed_packet_size 512
  @full_speed_packet_size 64

  @default_timeout 1_000

  @typedoc "An open FT232H USB handle."
  @type t :: %__MODULE__{
          handle: :usb.device_handle(),
          bus: 0..255,
          address: 0..255,
          max_packet_size: pos_integer(),
          detached_kernel_driver?: boolean()
        }

  @enforce_keys [:handle, :bus, :address, :max_packet_size]
  defstruct [:handle, :bus, :address, :max_packet_size, detached_kernel_driver?: false]

  @doc """
  Lists every FT232H currently attached to the host's USB bus.

  Identification is by VID `0x#{Integer.to_string(@ftdi_vendor_id, 16)}`,
  PID `0x#{Integer.to_string(@ft232h_product_id, 16)}` — the values used by
  the raw FT232H and the Adafruit FT232H Breakout.
  """
  @spec list_devices() :: {:ok, [Descriptor.t()]} | {:error, term()}
  def list_devices do
    with {:ok, devices} <- :usb.get_device_list() do
      {:ok, devices |> Enum.filter(&ft232h?/1) |> Enum.map(&describe/1)}
    end
  end

  @doc """
  Opens `descriptor` and prepares the chip for MPSSE traffic.

  Detaches the kernel driver if one is attached (typically `ftdi_sio` on Linux
  or Apple's FTDI VCP driver on macOS) and claims the FT232H's single USB
  interface. Once open, use `write/2` and `read/3` to push and pull MPSSE
  bytes, and the various `set_*`/`purge_*`/`reset/1` helpers to configure the
  SIO via FTDI control transfers.

  Pair every successful `open/2` with `close/1`.
  """
  @spec open(Descriptor.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(%Descriptor{} = descriptor, _opts \\ []) do
    with {:ok, handle} <- :usb.open_device(descriptor.device),
         {:ok, detached?} <- maybe_detach_kernel_driver(handle),
         :ok <- claim_interface(handle, detached?) do
      {:ok,
       %__MODULE__{
         handle: handle,
         bus: descriptor.bus,
         address: descriptor.address,
         max_packet_size: packet_size_for_speed(descriptor.speed),
         detached_kernel_driver?: detached?
       }}
    end
  end

  @doc """
  Releases the interface, re-attaches the kernel driver if we detached it on
  open, and closes the device.

  Always returns `:ok`. Errors during teardown are logged but not surfaced —
  by the time we're closing there is nothing useful for the caller to do.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = usb) do
    log_close_error(:usb.release_interface(usb.handle, @interface_number), "release_interface")

    if usb.detached_kernel_driver? do
      log_close_error(
        :usb.attach_kernel_driver(usb.handle, @interface_number),
        "attach_kernel_driver"
      )
    end

    log_close_error(:usb.close_device(usb.handle), "close_device")
    :ok
  end

  @doc """
  Resets the FTDI SIO. Equivalent to issuing `SIO_RESET` with `wValue = 0`.
  """
  @spec reset(t(), timeout()) :: :ok | {:error, term()}
  def reset(%__MODULE__{} = usb, timeout \\ @default_timeout) do
    write_control(usb, @sio_request_reset, @sio_reset_sio, timeout)
  end

  @doc "Purges the chip's RX FIFO."
  @spec purge_rx(t(), timeout()) :: :ok | {:error, term()}
  def purge_rx(%__MODULE__{} = usb, timeout \\ @default_timeout) do
    write_control(usb, @sio_request_reset, @sio_reset_purge_rx, timeout)
  end

  @doc "Purges the chip's TX FIFO."
  @spec purge_tx(t(), timeout()) :: :ok | {:error, term()}
  def purge_tx(%__MODULE__{} = usb, timeout \\ @default_timeout) do
    write_control(usb, @sio_request_reset, @sio_reset_purge_tx, timeout)
  end

  @doc """
  Sets the chip's USB latency timer to `milliseconds` (1..255).

  Lower values give snappier reads at the cost of more USB traffic; MPSSE
  applications typically use 1-16&nbsp;ms. The chip default is 16&nbsp;ms.
  """
  @spec set_latency_timer(t(), 1..255, timeout()) :: :ok | {:error, term()}
  def set_latency_timer(%__MODULE__{} = usb, milliseconds, timeout \\ @default_timeout)
      when milliseconds in 1..255 do
    write_control(usb, @sio_request_set_latency_timer, milliseconds, timeout)
  end

  @doc "Disables the FTDI event/error characters (we don't use them in MPSSE)."
  @spec disable_special_characters(t(), timeout()) :: :ok | {:error, term()}
  def disable_special_characters(%__MODULE__{} = usb, timeout \\ @default_timeout) do
    with :ok <- write_control(usb, @sio_request_set_event_char, 0x0000, timeout) do
      write_control(usb, @sio_request_set_error_char, 0x0000, timeout)
    end
  end

  @doc """
  Puts the chip into MPSSE mode. After this, `write/2` to the bulk OUT
  endpoint is interpreted as a stream of MPSSE commands.
  """
  @spec enter_mpsse_mode(t(), timeout()) :: :ok | {:error, term()}
  def enter_mpsse_mode(%__MODULE__{} = usb, timeout \\ @default_timeout) do
    set_bitmode(usb, @bitmode_mpsse, 0x00, timeout)
  end

  @doc """
  Resets bitmode to its default (UART). Useful to drop out of MPSSE before
  releasing the device.
  """
  @spec exit_bitmode(t(), timeout()) :: :ok | {:error, term()}
  def exit_bitmode(%__MODULE__{} = usb, timeout \\ @default_timeout) do
    set_bitmode(usb, @bitmode_reset, 0x00, timeout)
  end

  @doc """
  Sets the bitmode (high byte) and pin direction mask (low byte) on the
  low byte port (ADBUS).

  The direction byte sets each pin to output (1) or input (0). In MPSSE
  mode the MPSSE engine overrides this for SCK/MOSI/MISO/CS, but the
  initial value matters for any GPIOs.
  """
  @spec set_bitmode(t(), 0..255, 0..255, timeout()) :: :ok | {:error, term()}
  def set_bitmode(%__MODULE__{} = usb, mode, direction, timeout \\ @default_timeout) do
    value = Bitwise.bor(Bitwise.bsl(mode, 8), direction)
    write_control(usb, @sio_request_set_bitmode, value, timeout)
  end

  @doc """
  Sends raw MPSSE bytes to the chip over the bulk OUT endpoint.
  """
  @spec write(t(), iodata(), timeout()) :: :ok | {:error, term()}
  def write(%__MODULE__{} = usb, data, timeout \\ @default_timeout) do
    bin = IO.iodata_to_binary(data)

    case :usb.write_bulk(usb.handle, @bulk_out_endpoint, bin, timeout) do
      {:ok, n} when n == byte_size(bin) -> :ok
      {:ok, n} -> {:error, {:short_write, n, byte_size(bin)}}
      {:error, :timeout, n} -> {:error, {:timeout, n}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads exactly `length` bytes of MPSSE payload from the chip.

  Each USB packet from FT232H is prefixed by 2 modem-status bytes; this
  function strips them before returning the result, so `length` refers to
  *real* payload bytes.
  """
  @spec read(t(), non_neg_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
  def read(usb, length, timeout \\ @default_timeout)

  def read(%__MODULE__{}, 0, _timeout), do: {:ok, <<>>}

  def read(%__MODULE__{} = usb, length, timeout) do
    deadline = monotonic_ms() + timeout
    read_loop(usb, length, deadline, [], 0)
  end

  defp read_loop(_usb, length, _deadline, acc, acc_size) when acc_size >= length do
    payload = acc |> Enum.reverse() |> IO.iodata_to_binary()
    {:ok, binary_part(payload, 0, length)}
  end

  defp read_loop(usb, length, deadline, acc, acc_size) do
    remaining = deadline - monotonic_ms()

    if remaining <= 0 do
      {:error, {:short_read, acc_size, length}}
    else
      case :usb.read_bulk(usb.handle, @bulk_in_endpoint, usb.max_packet_size, remaining) do
        {:ok, raw} ->
          payload = strip_status(raw, usb.max_packet_size)
          read_loop(usb, length, deadline, [payload | acc], acc_size + byte_size(payload))

        {:error, :timeout, _partial} ->
          {:error, {:short_read, acc_size, length}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc """
  Strips the 2-byte modem-status prefix from every USB packet in `data`.

  `packet_size` is the bulk endpoint's max packet size (typically 512 for
  high-speed). Exposed because it's a pure function and the easiest piece of
  this module to unit-test.
  """
  @spec strip_status(binary(), pos_integer()) :: binary()
  def strip_status(data, packet_size) when is_binary(data) and packet_size > @modem_status_size do
    payload_size = packet_size - @modem_status_size
    do_strip(data, payload_size, [])
  end

  defp do_strip(<<>>, _payload, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp do_strip(<<_status::binary-size(@modem_status_size)>>, _payload, acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp do_strip(<<_status::binary-size(@modem_status_size), rest::binary>>, payload, acc)
       when byte_size(rest) <= payload do
    [rest | acc] |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp do_strip(<<_status::binary-size(@modem_status_size), data::binary>>, payload, acc) do
    <<chunk::binary-size(payload), rest::binary>> = data
    do_strip(rest, payload, [chunk | acc])
  end

  defp write_control(%__MODULE__{} = usb, request, value, timeout) do
    case :usb.write_control(
           usb.handle,
           @request_type_out,
           request,
           value,
           @interface_number + 1,
           <<>>,
           timeout
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ft232h?(device) do
    case :usb.get_device_descriptor(device) do
      {:ok, %{vendor_id: @ftdi_vendor_id, product_id: @ft232h_product_id}} -> true
      _ -> false
    end
  end

  defp describe(device) do
    {:ok, bus} = :usb.get_bus_number(device)
    {:ok, address} = :usb.get_device_address(device)
    port_numbers = unwrap(:usb.get_port_numbers(device), [])
    speed = unwrap(:usb.get_device_speed(device), :unknown)

    %Descriptor{
      device: device,
      bus: bus,
      address: address,
      port_numbers: port_numbers,
      speed: speed
    }
  end

  defp unwrap({:ok, value}, _default), do: value
  defp unwrap(_, default), do: default

  defp maybe_detach_kernel_driver(handle) do
    case :usb.detach_kernel_driver(handle, @interface_number) do
      :ok ->
        {:ok, true}

      {:error, :not_found} ->
        {:ok, false}

      {:error, :not_supported} ->
        {:ok, false}

      {:error, reason} ->
        {:error, {:detach_kernel_driver, reason}}
    end
  end

  defp claim_interface(handle, detached?) do
    case :usb.claim_interface(handle, @interface_number) do
      :ok ->
        :ok

      {:error, reason} ->
        if detached?, do: _ = :usb.attach_kernel_driver(handle, @interface_number)
        _ = :usb.close_device(handle)
        {:error, {:claim_interface, reason}}
    end
  end

  defp packet_size_for_speed(:high), do: @high_speed_packet_size
  defp packet_size_for_speed(:super), do: @high_speed_packet_size
  defp packet_size_for_speed(:super_plus), do: @high_speed_packet_size
  defp packet_size_for_speed(_other), do: @full_speed_packet_size

  defp log_close_error(:ok, _), do: :ok

  defp log_close_error({:error, reason}, op) do
    Logger.debug(fn -> "CircuitsFT232H.USB.close/#{op} returned #{inspect(reason)}" end)
    :ok
  end
end
