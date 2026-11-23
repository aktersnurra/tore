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

  test "only a photo's formats are read" do
    svg = ~s(<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"/>)
    assert {:error, :not_a_photo} = Vips.thumbnail(svg, 256)
    assert {:error, :not_a_photo} = Vips.thumbnail("%PDF-1.4", 256)
    assert {:error, :not_a_photo} = Vips.thumbnail("not an image", 256)
  end

  @tag :capture_log
  test "a photo's header on bytes that aren't one is an error" do
    assert {:error, {:vipsthumbnail, _}} =
             Vips.thumbnail(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "garbage">>, 256)
  end

  test "leaves no files behind" do
    before = File.ls!(System.tmp_dir!()) |> Enum.filter(&String.starts_with?(&1, "tore-thumb-"))
    {:ok, _} = Vips.thumbnail(@png, 4)
    after_ = File.ls!(System.tmp_dir!()) |> Enum.filter(&String.starts_with?(&1, "tore-thumb-"))
    assert after_ == before
  end

  # Lossy WebP (VP8): the width is the low 14 bits of the frame header's first field.
  defp webp_width(
         <<"RIFF", _::32, "WEBPVP8 ", _::32, _::binary-size(6), w::16-little, _::binary>>
       ),
       do: Bitwise.band(w, 0x3FFF)
end
