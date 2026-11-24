defmodule Tore.PdfFixtures do
  @moduledoc "A small PDF of blank pages, written by hand so tests need no PDF writer."

  @spec pdf(pos_integer()) :: binary()
  def pdf(pages \\ 1) do
    kids = Enum.map_join(1..pages, " ", &"#{&1 + 2} 0 R")

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [#{kids}] /Count #{pages} >>"
      ] ++
        for(_ <- 1..pages, do: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] >>")

    {body, offsets} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, n}, {body, offsets} ->
        {body <> "#{n} 0 obj\n#{object}\nendobj\n", [byte_size(body) | offsets]}
      end)

    xref =
      offsets
      |> Enum.reverse()
      |> Enum.map_join(&(String.pad_leading("#{&1}", 10, "0") <> " 00000 n \n"))

    count = length(objects) + 1

    body <>
      "xref\n0 #{count}\n0000000000 65535 f \n" <>
      xref <>
      "trailer\n<< /Size #{count} /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
