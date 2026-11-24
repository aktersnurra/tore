defmodule Tore.PdfTest do
  use ExUnit.Case, async: true

  alias Tore.Pdf

  @moduletag skip: System.find_executable("pdftoppm") == nil && "pdftoppm not installed"

  test "a PDF's pages come back as JPEGs, in order" do
    assert {:ok, [{"image/jpeg", first}, {"image/jpeg", second}]} =
             Pdf.pages(Tore.PdfFixtures.pdf(2))

    assert <<0xFF, 0xD8, _::binary>> = first
    assert <<0xFF, 0xD8, _::binary>> = second
  end

  test "only the first pages of a long one are read" do
    assert {:ok, pages} = Pdf.pages(Tore.PdfFixtures.pdf(12))
    assert length(pages) == 5
  end

  test "something that isn't a PDF is refused without being run" do
    assert Pdf.pages("jpegbytes") == {:error, :not_a_pdf}
  end

  test "a broken PDF is an error" do
    assert {:error, _reason} = Pdf.pages("%PDF-1.4\nnothing here")
  end
end
