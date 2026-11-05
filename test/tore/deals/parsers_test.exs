defmodule Tore.Deals.ParsersTest do
  use ExUnit.Case, async: true

  alias Tore.Deals.Parsers
  alias Tore.Deals.Parsers.ICA

  @store "https://www.ica.se/erbjudanden/ica-supermarket-danvikstull-1156002/"

  describe "for_url/1" do
    test "picks ICA for its hosts" do
      assert {:ok, ICA} = Parsers.for_url(@store)
      assert {:ok, ICA} = Parsers.for_url("https://ica.se/erbjudanden/ica-maxi-1/")
    end

    test "refuses links it must not fetch" do
      for url <- [
            "http://www.ica.se/erbjudanden/ica-maxi-1/",
            "https://www.coop.se/butiker/x/",
            "https://www.ica.se.evil.example/erbjudanden/ica-maxi-1/",
            "https://www.ica.se@evil.example/erbjudanden/ica-maxi-1/",
            "https://www.ica.se:8443/erbjudanden/ica-maxi-1/",
            "http://localhost:3900/",
            "file:///etc/passwd",
            "not a link",
            ""
          ] do
        assert {:error, :unsupported_store} = Parsers.for_url(url), "expected refusal: #{url}"
      end
    end
  end

  describe "ICA.store_name/1" do
    test "reads the store's name from its link" do
      assert {:ok, "ICA Supermarket Danvikstull"} = ICA.store_name(URI.parse(@store))

      assert {:ok, "ICA Maxi Stormarknad Nacka"} =
               ICA.store_name(
                 URI.parse("https://www.ica.se/erbjudanden/ica-maxi-stormarknad-nacka-42")
               )
    end

    test "refuses ICA pages that aren't a store's offers" do
      for path <- [
            "https://www.ica.se/",
            "https://www.ica.se/recept/",
            "https://www.ica.se/erbjudanden/"
          ] do
        assert {:error, :unsupported_store} = ICA.store_name(URI.parse(path))
      end
    end
  end
end
