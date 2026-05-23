defmodule CircuitsFT232H.MixProject do
  use Mix.Project

  @version "0.2.0"
  @description "Adafruit FT232H breakout board backend for `circuits_i2c` and `circuits_spi`, allowing host-side I2C and SPI development over USB."

  def project do
    [
      app: :circuits_ft232h,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      description: @description,
      package: package(),
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix]],
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {CircuitsFT232H.Application, []}
    ]
  end

  defp package do
    [
      maintainers: ["James Harton <james@harton.nz>"],
      licenses: ["Apache-2.0"],
      links: %{
        "Source" => "https://harton.dev/james/circuits_ft232h",
        "GitHub" => "https://github.com/jimsynz/circuits_ft232h",
        "FTDI FT232H Datasheet" => "https://ftdichip.com/wp-content/uploads/2020/07/DS_FT232H.pdf"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:circuits_gpio, "~> 2.1"},
      {:circuits_i2c, "~> 2.1"},
      {:circuits_spi, "~> 2.0"},
      {:igniter, "~> 0.8", optional: true},
      {:usb, "~> 0.2"},
      {:credo, "~> 1.7", only: ~w[dev test]a, runtime: false},
      {:dialyxir, "~> 1.4", only: ~w[dev test]a, runtime: false},
      {:doctor, "~> 0.22", only: ~w[dev test]a, runtime: false},
      {:ex_check, "~> 0.16", only: ~w[dev test]a, runtime: false},
      {:ex_doc, ">= 0.31.0", only: ~w[dev test]a, runtime: false},
      {:git_ops, "~> 2.6", only: ~w[dev test]a, runtime: false},
      {:mimic, "~> 2.0", only: ~w[dev test]a, runtime: false}
    ]
  end
end
