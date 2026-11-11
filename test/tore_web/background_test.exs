defmodule ToreWeb.BackgroundTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ToreWeb.Background

  test "the caller hears the work's result" do
    Background.run(fn -> {:ok, 3} end, &{:done, &1})
    assert_receive {:done, {:ok, 3}}
  end

  test "work that raises or exits still replies, as a crash" do
    log =
      capture_log(fn ->
        Background.run(fn -> raise "boom" end, &{:done, &1})
        assert_receive {:done, {:error, :crashed}}

        Background.run(fn -> exit(:gone) end, &{:done, &1})
        assert_receive {:done, {:error, :crashed}}
      end)

    assert log =~ "boom"
  end

  test "the work runs with the caller's locale" do
    Gettext.put_locale(ToreWeb.Gettext, "sv")
    Background.run(fn -> Gettext.get_locale(ToreWeb.Gettext) end, &{:locale, &1})
    assert_receive {:locale, "sv"}
  end
end
