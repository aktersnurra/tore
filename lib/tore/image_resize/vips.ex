defmodule Tore.ImageResize.Vips do
  @moduledoc """
  `Tore.ImageResize` through libvips' `vipsthumbnail` command (`pkg install vips` on FreeBSD,
  `apt install libvips-tools` or `brew install vips` elsewhere). A command, not a NIF, so the
  release builds the same everywhere; it runs once per picture and width, as the result is kept.

  The bytes may come from any recipe page, so only the formats a photo comes in are read
  (`Tore.ImageResize.format/1`), vips' loaders for other formats (SVG, PDF, ...) are blocked
  (`VIPS_BLOCK_UNTRUSTED`), and a run that takes longer than `@timeout_s` is killed.
  """

  @behaviour Tore.ImageResize

  require Logger

  @timeout_s 20

  @impl true
  def thumbnail(image, width) when is_binary(image) and is_integer(width) and width > 0 do
    with {:ok, format} <- photo_format(image),
         {:ok, exe} <- executable(),
         {:ok, dir} <- private_dir() do
      try do
        run(exe, dir, image, format, width)
      after
        File.rm_rf(dir)
      end
    end
  end

  defp run(exe, dir, image, format, width) do
    input = Path.join(dir, "in.#{format}")
    output = Path.join(dir, "out.webp")
    # `>`: only ever shrink. Strip drops EXIF and colour profiles the screen doesn't need.
    args = [input, "--size", "#{width}x>", "-o", output <> "[Q=78,strip]"]
    {cmd, args} = with_timeout(exe, args)

    with :ok <- File.write(input, image) do
      case System.cmd(cmd, args, stderr_to_stdout: true, env: [{"VIPS_BLOCK_UNTRUSTED", "1"}]) do
        {_, 0} ->
          File.read(output)

        {out, status} ->
          Logger.warning("vipsthumbnail failed (#{status}): #{String.trim(out)}")
          {:error, {:vipsthumbnail, status}}
      end
    end
  end

  defp photo_format(image) do
    case Tore.ImageResize.format(image) do
      nil -> {:error, :not_a_photo}
      format -> {:ok, format}
    end
  end

  defp executable do
    case System.find_executable("vipsthumbnail") do
      nil -> {:error, :no_vipsthumbnail}
      exe -> {:ok, exe}
    end
  end

  # timeout(1) kills vips itself, which a dying caller wouldn't. Without timeout(1), vips runs bare.
  defp with_timeout(exe, args) do
    case System.find_executable("timeout") do
      nil -> {exe, args}
      timeout -> {timeout, ["-s", "KILL", "#{@timeout_s}", exe | args]}
    end
  end

  # A new directory of its own (mkdir fails if the name exists), named so nobody can guess it.
  defp private_dir do
    name = "tore-thumb-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), name)

    with :ok <- File.mkdir(dir), :ok <- File.chmod(dir, 0o700), do: {:ok, dir}
  end
end
