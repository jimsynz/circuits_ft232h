# Tests tagged `:hardware` require a real FT232H connected to USB with the
# udev rule installed. They are excluded by default; opt in with
# `mix test --include hardware`.
ExUnit.start(exclude: [:hardware])
