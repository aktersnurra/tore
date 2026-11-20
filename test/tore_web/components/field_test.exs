defmodule ToreWeb.FieldTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  import Phoenix.Component

  # Every text field in the app (but the chat's box) is this one: blue while typing, green when
  # just saved, red with the reason under it when something's wrong.
  defp field(assigns), do: rendered_to_string(~H"<ToreWeb.CoreComponents.field {assigns} />")

  test "a field is its box, with the input inside it" do
    html = field(%{name: "name", value: "Foob", label: "Name"})
    [box] = html |> Floki.parse_fragment!() |> Floki.find(".field")
    assert [{"input", _, _}] = Floki.find(box, "input[name=name][value=Foob]")
    assert html =~ "Name"
    refute html =~ "field-error"
  end

  test "just saved, the box flashes green" do
    assert field(%{name: "name", saved: true}) =~ ~s(class="field saved-flash")
  end

  test "an error turns it red, says why under it, and points the input at it" do
    html = field(%{id: "url", name: "url", errors: ["That isn't a link."]})
    doc = Floki.parse_fragment!(html)

    assert [_] = Floki.find(doc, ".field.field-invalid")
    assert [_] = Floki.find(doc, ~s(input[aria-invalid="true"][aria-describedby="url-error"]))
    assert Floki.find(doc, "#url-error.field-error") |> Floki.text() =~ "That isn't a link."
  end

  test "a textarea is a field too" do
    html = field(%{name: "notes", type: "textarea", value: "Salt"})
    assert [_] = html |> Floki.parse_fragment!() |> Floki.find(".field textarea[name=notes]")
  end
end
