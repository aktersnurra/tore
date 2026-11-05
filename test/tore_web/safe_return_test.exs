defmodule ToreWeb.SafeReturnTest do
  use ExUnit.Case, async: true

  alias ToreWeb.SafeReturn

  test "rejects absolute URLs, falling back to default" do
    assert SafeReturn.path("https://evil.example") == "/"
  end

  test "rejects protocol-relative paths" do
    assert SafeReturn.path("//evil.example") == "/"
  end

  test "rejects backslash tricks" do
    assert SafeReturn.path("/\\evil.example") == "/"
  end

  test "rejects values that don't start with /" do
    assert SafeReturn.path("x") == "/"
  end

  test "rejects nil" do
    assert SafeReturn.path(nil) == "/"
  end

  test "accepts a same-origin absolute path" do
    assert SafeReturn.path("/plan") == "/plan"
  end

  test "honors a custom default" do
    assert SafeReturn.path(nil, "/plan") == "/plan"
    assert SafeReturn.path("//evil.example", "/plan") == "/plan"
  end
end
