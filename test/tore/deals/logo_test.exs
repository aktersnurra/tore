defmodule Tore.Deals.LogoTest do
  use ExUnit.Case, async: true

  alias Tore.Deals.Logo

  @page "https://www.ica.se/erbjudanden/ica-supermarket-danvikstull-1156002/"

  test "a page's largest touch icon is its logo" do
    html = """
    <html><head>
    <link rel="icon" type="image/png" href="https://assets.example/favicon-32x32.png" sizes="32x32">
    <link rel="apple-touch-icon" href="https://assets.example/touch-60.png" sizes="60x60">
    <link rel="apple-touch-icon" href="https://assets.example/touch-180.png" sizes="180x180">
    <link rel="apple-touch-icon" href="https://assets.example/touch-120.png" sizes="120x120">
    </head></html>
    """

    assert Logo.find(html, @page) == "https://assets.example/touch-180.png"
  end

  test "without a touch icon, the largest icon; a link relative to the page is made whole" do
    html = """
    <link rel="shortcut icon" href="/favicon.ico">
    <link rel="icon" href="/icons/64.png" sizes="64x64">
    """

    assert Logo.find(html, @page) == "https://www.ica.se/icons/64.png"
  end

  test "a page without one has none" do
    assert Logo.find(~s({"weeklyOffers":[]}), @page) == nil
  end
end
