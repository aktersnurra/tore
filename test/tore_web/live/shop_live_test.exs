defmodule ToreWeb.ShopLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox
  import Tore.FakePi

  setup :verify_on_exit!
  setup :set_mox_from_context

  setup do
    user = user_fixture(name: "Gustaf")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: flunk("Timed out waiting for condition")

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  test "sections follow a walk through the store: fruit and veg first, frozen last", %{
    conn: conn
  } do
    week = Tore.Streams.monday(Tore.Clock.today())
    list = Tore.Streams.shop_list(home_scope(), week)

    items =
      for {name, section} <- [
            {"Glass", "frozen"},
            {"Mjölk", "dairy"},
            {"Limpa", "bread"},
            {"Äpple", "produce"}
          ] do
        %{
          "id" => Ecto.UUID.generate(),
          "name" => name,
          "quantity" => nil,
          "unit" => nil,
          "section" => section,
          "checked" => false,
          "basic" => false
        }
      end

    {:ok, _} =
      Tore.Shop.append(home_scope(), list, %Tore.Shop.Commands.BuildList{
        week_start: week,
        items: items
      })

    {:ok, _view, html} = live(conn, ~p"/shop")

    positions =
      for label <- ["Frukt &amp; grönt", "Bröd", "Mejeri &amp; ägg", "Fryst"],
          do: :binary.match(html, label)

    assert Enum.all?(positions, &(&1 != :nomatch))
    assert positions == Enum.sort(positions)
  end

  test "the page says what's left, sections are tags that fold, and the basket starts folded", %{
    conn: conn
  } do
    week = Tore.Streams.monday(Tore.Clock.today())
    list = Tore.Streams.shop_list(home_scope(), week)

    items =
      for {name, checked} <- [{"Äpple", false}, {"Päron", false}, {"Mjölk", true}] do
        %{
          "id" => Ecto.UUID.generate(),
          "name" => name,
          "quantity" => nil,
          "unit" => nil,
          "section" => if(name == "Mjölk", do: "dairy", else: "produce"),
          "checked" => checked,
          "basic" => false
        }
      end

    {:ok, _} =
      Tore.Shop.append(home_scope(), list, %Tore.Shop.Commands.BuildList{
        week_start: week,
        items: items
      })

    {:ok, view, html} = live(conn, ~p"/shop")

    assert html =~ "2 kvar · vecka #{Tore.Streams.week_number(week)}"

    assert view |> element(~s([aria-controls="items-produce"])) |> render() =~
             ~r/tag-green.*Frukt &amp; grönt.*2/s

    assert has_element?(view, ~s([aria-controls="items-basket"][aria-expanded="false"]))
    assert has_element?(view, ~s(ul#items-basket.hidden))
    assert has_element?(view, ~s[ul#items-produce:not(.hidden)])
  end

  describe "adding" do
    test "the add form has a submit button, so Enter adds, and it clears after each item", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/shop")

      # A form of several text fields with no submit button never submits on Enter.
      assert has_element?(view, ~s(#add-item button[type="submit"]))

      view |> form("#add-item", %{name: "feta"}) |> render_submit()
      assert_push_event(view, "reset_form", %{id: "add-item"})
      assert has_element?(view, ~s([data-item-name="feta"]))
    end
  end

  describe "one add field" do
    test "reads the amount and unit typed before the name", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/shop")

      view |> form("#add-item", %{name: "2 l mjölk"}) |> render_submit()

      assert eventually(fn -> has_element?(view, ~s([data-item-name="mjölk"])) end)
      assert view |> element(~s([data-item-name="mjölk"])) |> render() =~ ~r/>\s*2 l\s*</
    end
  end

  describe "the week's dinners" do
    setup do
      {:ok, tacos} =
        Tore.Recipes.create(
          home_scope(),
          %{title: "Tacos", ingredients: [%{name: "tortilla", quantity: 8, unit: "st"}]}
        )

      today = Tore.Clock.today()
      plan = Tore.Streams.plan(home_scope(), Tore.Streams.monday(today))

      {:ok, _} =
        Tore.Planning.assign_recipe(home_scope(), plan, Tore.Streams.slot_key(today), tacos.id, 4)

      :ok
    end

    test "an empty list offers to make itself from them, and does", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/shop")

      view |> element(~s([data-role="make-list"])) |> render_click()

      assert eventually(fn -> has_element?(view, ~s([data-item-name="tortilla"])) end)
      refute has_element?(view, ~s([data-role="make-list"]))
    end

    test "an item says which dinner it's for", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/shop")
      view |> form("#add-item", %{name: "tortilla"}) |> render_submit()

      assert view |> element(~s([data-role="for-dinner"])) |> render() =~ "till kvällens tacos"
    end
  end

  describe "grocery item object sheet" do
    setup :fake_pi

    test "long-pressing a grocery row opens an item sheet whose words go to pi about the item",
         %{conn: conn, user: user, pi_log: log} do
      System.put_env("FAKE_PI_REPLY", "Bytte till Apetina.")

      {:ok, view, _} = live(conn, ~p"/shop")

      view
      |> form(~s(form[phx-submit="add_item"]), %{name: "feta"})
      |> render_submit()

      item_id = item_id_from_render(view)

      view
      |> element(~s([phx-hook="LongPress"][data-item-name="feta"]))
      |> render_hook("open_item_sheet", %{"item_id" => item_id})

      assert render(view) =~ ~s(phx-submit="item_command")
      assert render(view) =~ "feta"

      view
      |> form(~s(form[phx-submit="item_command"]), %{command: "byt till Apetina 200 g"})
      |> render_submit()

      refute render(view) =~ ~s(phx-submit="item_command")
      assert eventually(fn -> has_element?(view, ~s([data-role="pi-reply"]), "Bytte") end)

      [header, %{"type" => "prompt", "message" => message}] = pi_records(log)
      assert header["session"] == Tore.Pi.screen_session(scope_fixture(user))
      assert message =~ ~s(From the Shop screen, about "feta")
      assert message =~ "byt till Apetina 200 g"
    end

    test "escape closes the item sheet without routing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/shop")

      view
      |> form(~s(form[phx-submit="add_item"]), %{name: "feta"})
      |> render_submit()

      item_id = item_id_from_render(view)

      view
      |> element(~s([phx-hook="LongPress"][data-item-name="feta"]))
      |> render_hook("open_item_sheet", %{"item_id" => item_id})

      assert render(view) =~ ~s(phx-submit="item_command")

      render_hook(view, "close_item_sheet", %{})

      refute render(view) =~ ~s(phx-submit="item_command")
    end
  end

  defp item_id_from_render(view) do
    [_, id] =
      Regex.run(~r/data-item-id="([^"]+)"/, render(view)) ||
        flunk("no grocery row with data-item-id rendered")

    id
  end
end
