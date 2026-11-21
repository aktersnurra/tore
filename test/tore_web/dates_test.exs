defmodule ToreWeb.DatesTest do
  use ExUnit.Case, async: true

  alias ToreWeb.Dates

  test "a duration reads in minutes under an hour, else in hours and minutes" do
    assert Dates.duration(20) == "20 min"
    assert Dates.duration(300) == "5 h"
    assert Dates.duration(95) == "1 h 35 min"
  end
end
