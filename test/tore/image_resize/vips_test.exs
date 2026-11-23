defmodule Tore.ImageResize.VipsTest do
  use ExUnit.Case, async: true

  alias Tore.ImageResize.Vips

  # A real resize, where vips is installed; skipped elsewhere. The picture is 8x4.
  @moduletag skip: System.find_executable("vipsthumbnail") == nil && "vipsthumbnail not installed"

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAIAAAA8r+mnAAAAEUlEQVR4nGM4kWKEFTFQTwIAnxwrwdfiqY8AAAAASUVORK5CYII="
       )

  test "shrinks to the width, as WebP, and never enlarges" do
    assert {:ok, <<"RIFF", _::binary-size(4), "WEBP", _::binary>> = small} =
             Vips.thumbnail(@png, 4)

    assert {:ok, <<"RIFF", _::binary-size(4), "WEBP", _::binary>> = same} =
             Vips.thumbnail(@png, 256)

    assert webp_width(small) == 4
    assert webp_width(same) == 8
  end

  @tag :capture_log
  test "an unreadable picture is an error" do
    assert {:error, {:vipsthumbnail, _}} = Vips.thumbnail("not an image", 256)
  end

  # Lossy WebP (VP8): the width is the low 14 bits of the frame header's first field.
  defp webp_width(
         <<"RIFF", _::32, "WEBPVP8 ", _::32, _::binary-size(6), w::16-little, _::binary>>
       ),
       do: Bitwise.band(w, 0x3FFF)
end
