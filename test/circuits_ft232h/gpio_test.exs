defmodule CircuitsFT232H.GPIOTest do
  use ExUnit.Case, async: true

  alias CircuitsFT232H.GPIO

  describe "label/1 and parse_label/1" do
    test "round-trips for every pin" do
      for pin <- 0..15 do
        assert {:ok, ^pin} = pin |> GPIO.label() |> GPIO.parse_label()
      end
    end

    test "labels match the silkscreen convention" do
      assert "AD0" = GPIO.label(0)
      assert "AD7" = GPIO.label(7)
      assert "AC0" = GPIO.label(8)
      assert "AC7" = GPIO.label(15)
    end

    test "rejects malformed labels" do
      assert {:error, :invalid_label} = GPIO.parse_label("D0")
      assert {:error, :invalid_label} = GPIO.parse_label("AD8")
      assert {:error, :invalid_label} = GPIO.parse_label("AB0")
      assert {:error, :invalid_label} = GPIO.parse_label("")
    end
  end

  describe "resolve/1 with controller-qualified specs" do
    test "{controller, line_offset}" do
      assert {:ok, %{controller: "ftdi-x", pin: 4, label: "AD4"}} =
               GPIO.resolve({"ftdi-x", 4})

      assert {:ok, %{controller: "ftdi-x", pin: 12, label: "AC4"}} =
               GPIO.resolve({"ftdi-x", 12})
    end

    test "{controller, label}" do
      assert {:ok, %{controller: "ftdi-x", pin: 5, label: "AD5"}} =
               GPIO.resolve({"ftdi-x", "AD5"})

      assert {:ok, %{controller: "ftdi-x", pin: 11, label: "AC3"}} =
               GPIO.resolve({"ftdi-x", "AC3"})
    end

    test "rejects out-of-range pin offsets" do
      assert {:error, :invalid_pin} = GPIO.resolve({"ftdi-x", 16})
      assert {:error, :invalid_pin} = GPIO.resolve({"ftdi-x", -1})
    end

    test "rejects invalid labels" do
      assert {:error, :invalid_label} = GPIO.resolve({"ftdi-x", "GPIO12"})
    end
  end

  describe "identifiers/1" do
    test "shapes the map to match Circuits.GPIO.identifiers()" do
      pin_ref = %{controller: "ftdi-3:9", pin: 4, label: "AD4"}

      assert %{
               location: {"ftdi-3:9", 4},
               controller: "ftdi-3:9",
               label: "AD4"
             } = GPIO.identifiers(pin_ref)
    end
  end
end
