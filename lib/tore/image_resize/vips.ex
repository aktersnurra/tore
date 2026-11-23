defmodule Tore.ImageResize.Vips do
  @moduledoc """
  `Tore.ImageResize` through libvips' `vipsthumbnail` command (`pkg install vips` on FreeBSD,
  `apt install libvips-tools` or `brew install vips` elsewhere). A command, not a NIF, so the
  release builds the same everywhere; it runs once per picture and width, as the result is kept.
  """

  @behaviour Tore.ImageResize

  require Logger

  @impl true
  def thumbnail(image, width) when is_binary(image) and is_integer(width) and width > 0 do
    case System.find_executable("vipsthumbnail") do
      nil ->
        {:error, :no_vipsthumbnail}

      exe ->
        dir = Path.join(System.tmp_dir!(), "tore-thumb-#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        input = Path.join(dir, "in")
        output = Path.join(dir, "out.webp")

        try do
          File.write!(input, image)

          # `>`: only ever shrink. Strip drops EXIF and colour profiles the screen doesn't need.
          args = [input, "--size", "#{width}x>", "-o", output <> "[Q=78,strip]"]

          case System.cmd(exe, args, stderr_to_stdout: true) do
            {_, 0} ->
              File.read(output)

            {out, status} ->
              Logger.warning("vipsthumbnail failed (#{status}): #{String.trim(out)}")
              {:error, {:vipsthumbnail, status}}
          end
        after
          File.rm_rf(dir)
        end
    end
  end
end
