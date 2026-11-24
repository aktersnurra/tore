defmodule Tore.Pdf do
  @moduledoc """
  A PDF's pages as pictures, for pi: a model call takes pictures, and a receipt a shop mails is a
  PDF. Made by poppler's `pdftoppm` command (`pkg install poppler-utils` on FreeBSD,
  `apt install poppler-utils`, `brew install poppler`), like `Tore.ImageResize.Vips` a command and
  not a NIF. Only the first `@max_pages` pages are read, and a run longer than `@timeout_s` is
  killed.
  """

  require Logger

  @max_pages 5
  # An A4 page about 1240 px wide: a receipt's small print is read, and five pages stay small.
  @dpi 150
  @timeout_s 20

  @spec pdf?(binary()) :: boolean()
  def pdf?(<<"%PDF-", _::binary>>), do: true
  def pdf?(_bytes), do: false

  @doc "The first pages of `pdf` as `{\"image/jpeg\", bytes}`, in order."
  @spec pages(binary()) ::
          {:ok, [{String.t(), binary()}, ...]} | {:error, :no_pdftoppm | :not_a_pdf | term()}
  def pages(pdf) when is_binary(pdf) do
    with true <- pdf?(pdf) || {:error, :not_a_pdf},
         {:ok, exe} <- executable(),
         {:ok, dir} <- private_dir() do
      try do
        run(exe, dir, pdf)
      after
        File.rm_rf(dir)
      end
    end
  end

  defp run(exe, dir, pdf) do
    input = Path.join(dir, "in.pdf")

    args = [
      "-jpeg",
      "-r",
      "#{@dpi}",
      "-f",
      "1",
      "-l",
      "#{@max_pages}",
      input,
      Path.join(dir, "p")
    ]

    {cmd, args} = with_timeout(exe, args)

    with :ok <- File.write(input, pdf) do
      case System.cmd(cmd, args, stderr_to_stdout: true) do
        {_, 0} ->
          # p-1.jpg, or p-01.jpg in a longer document: in page order either way.
          case dir |> Path.join("p-*.jpg") |> Path.wildcard() |> Enum.sort() do
            [] -> {:error, :no_pages}
            files -> {:ok, Enum.map(files, &{"image/jpeg", File.read!(&1)})}
          end

        {out, status} ->
          Logger.warning("pdftoppm failed (#{status}): #{String.trim(out)}")
          {:error, {:pdftoppm, status}}
      end
    end
  end

  defp executable do
    case System.find_executable("pdftoppm") do
      nil -> {:error, :no_pdftoppm}
      exe -> {:ok, exe}
    end
  end

  # timeout(1) kills pdftoppm itself, which a dying caller wouldn't.
  defp with_timeout(exe, args) do
    case System.find_executable("timeout") do
      nil -> {exe, args}
      timeout -> {timeout, ["-s", "KILL", "#{@timeout_s}", exe | args]}
    end
  end

  # A new directory of its own (mkdir fails if the name exists), named so nobody can guess it.
  defp private_dir do
    name = "tore-pdf-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), name)

    with :ok <- File.mkdir(dir), :ok <- File.chmod(dir, 0o700), do: {:ok, dir}
  end
end
