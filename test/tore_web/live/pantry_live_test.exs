defmodule ToreWeb.PantryLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Tore.Pantry

  setup %{conn: conn} do
    user = user_fixture(name: "Gustaf")
    %{conn: Plug.Test.init_test_session(conn, %{user_id: user.id})}
  end

  defp kept(name, category, attrs \\ %{}) do
    {:ok, item, :added, nil} =
      Pantry.upsert_belief(
        home_scope(),
        Map.merge(%{catalogue_name: name, category: category, provenance: "manual"}, attrs)
      )

    item
  end

  test "an amount of whole packs reads as packs, and an opened one as packs and the rest", %{
    conn: conn
  } do
    kept("kycklingfilé", "meat", %{
      quantity: Decimal.new(1640),
      unit: "g",
      pack_size: Decimal.new(820)
    })

    kept("bacon", "deli", %{quantity: Decimal.new(440), unit: "g", pack_size: Decimal.new(140)})
    kept("grädde", "dairy", %{quantity: Decimal.new(2), unit: "dl", pack_size: Decimal.new(5)})

    {:ok, view, _html} = live(conn, ~p"/pantry")

    assert view |> element("[data-role=left]", "2 × 820 g") |> has_element?()
    assert view |> element("[data-role=left]", "3 förp + 20 g") |> has_element?()
    # Less than a pack is just what's left.
    assert view |> element("[data-role=left]", "2 dl") |> has_element?()
  end

  test "an empty pantry says how things get here", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/pantry")

    assert html =~ "Hemma"
    assert html =~ "Inget här än"
  end

  test "things are grouped by where they're kept, with what goes off soon", %{conn: conn} do
    today = Tore.Clock.today()
    milk = kept("Mjölk", "dairy")
    {:ok, _} = Pantry.set_expiry(home_scope(), milk.id, Date.add(today, 1))
    kept("Gul lök", "produce")
    kept("Laxfilé", "frozen")
    rice = kept("Ris", "dry_goods")

    {:ok, _} =
      rice
      |> Ecto.Changeset.change(expires_at: today, expires_source: "estimate")
      |> Tore.Repo.update()

    {:ok, view, html} = live(conn, ~p"/pantry")

    assert html =~ "4 saker · 2 går ut snart"
    assert view |> element(~s([data-group="fridge"])) |> render() =~ "Går ut i morgon"
    assert has_element?(view, ~s([data-group="produce"]), "gul lök")
    assert has_element?(view, ~s([data-group="freezer"]), "laxfilé")
    # A guessed date is said as a guess.
    assert view |> element(~s([data-group="cupboard"])) |> render() =~ "Håller nog till idag"
  end

  test "an unsure thing asks; Slut moves it to Gone, and Finns there brings it back, sure", %{
    conn: conn
  } do
    butter = kept("Smör", "dairy")
    {:ok, _} = butter |> Ecto.Changeset.change(belief: "uncertain") |> Tore.Repo.update()
    row = ~s([data-item="#{butter.id}"])

    {:ok, view, _html} = live(conn, ~p"/pantry")
    assert view |> element(row <> ~s( [data-role="ask"])) |> render() =~ "Finns kvar?"

    view |> element(row <> ~s( [data-role="ask"])) |> render_click()
    view |> element(row <> ~s( [data-role="gone"])) |> render_click()
    assert has_element?(view, ~s([data-group="gone"] ) <> row)
    assert Pantry.at_home(home_scope(), ["smör"]).missing == ["smör"]

    # Gone, the row offers Finns straight away.
    view |> element(row <> ~s( [data-role="still-there"])) |> render_click()
    assert has_element?(view, ~s([data-group="fridge"] ) <> row)
    refute has_element?(view, row <> ~s( [data-role="ask"]))
  end

  describe "a row's sheet" do
    defp open_sheet(view, item),
      do: view |> element(~s([data-item="#{item.id}"] [data-role="open"])) |> render_click()

    defp quantity_of(item) do
      Tore.Repo.get!(Tore.Pantry.PantryItem, item.id, Tore.Scope.repo_opts(home_scope())).quantity
    end

    test "tapping a row opens it; what's left is said there, and nothing left is gone", %{
      conn: conn
    } do
      pasta = kept("Spaghetti", "dry_goods", %{quantity: Decimal.new(1), unit: "kg"})
      row = ~s([data-item="#{pasta.id}"])

      {:ok, view, _html} = live(conn, ~p"/pantry")
      assert view |> element(row) |> render() =~ "1 kg"

      open_sheet(view, pasta)
      assert view |> element("#pantry-item") |> render() =~ "spaghetti"
      view |> form("#item-left", %{left: "400 g"}) |> render_submit()

      assert view |> element(row) |> render() =~ "400 g"
      [left] = Pantry.list_inventory(home_scope())
      assert {Decimal.to_string(left.quantity, :normal), left.unit} == {"400", "g"}

      view |> form("#item-left", %{left: "0"}) |> render_submit()
      assert has_element?(view, ~s([data-group="gone"] ) <> row)
    end

    test "− and + take away and add one pack", %{conn: conn} do
      chicken =
        kept("kycklingfilé", "meat", %{
          quantity: Decimal.new(1640),
          unit: "g",
          pack_size: Decimal.new(820)
        })

      {:ok, view, _html} = live(conn, ~p"/pantry")
      open_sheet(view, chicken)

      view |> element(~s(#pantry-item [data-role="more"])) |> render_click()
      assert Decimal.equal?(quantity_of(chicken), 2460)
      assert view |> element("#pantry-item") |> render() =~ "3 × 820 g"

      view |> element(~s(#pantry-item [data-role="less"])) |> render_click()
      view |> element(~s(#pantry-item [data-role="less"])) |> render_click()
      assert Decimal.equal?(quantity_of(chicken), 820)
    end

    test "the best-before date is set there, as the household's", %{conn: conn} do
      milk = kept("mjölk", "dairy", %{quantity: Decimal.new(1), unit: "l"})

      {:ok, view, _html} = live(conn, ~p"/pantry")
      open_sheet(view, milk)
      view |> form("#item-expiry", %{expires_at: "2026-12-01"}) |> render_change()

      [item] = Pantry.list_inventory(home_scope())
      assert {item.expires_at, item.expires_source} == {~D[2026-12-01], "manual"}
    end

    test "Slut, from the sheet or a swipe, moves it to Gone with Ångra, which brings it back", %{
      conn: conn
    } do
      butter = kept("Smör", "dairy")
      row = ~s([data-item="#{butter.id}"])

      {:ok, view, _html} = live(conn, ~p"/pantry")
      open_sheet(view, butter)
      view |> element(~s(#pantry-item [data-role="sheet-gone"])) |> render_click()

      assert has_element?(view, ~s([data-group="gone"] ) <> row)
      refute has_element?(view, "#pantry-item")
      assert view |> element("#undo-bar") |> render() =~ "smör är slut"

      view |> element("#undo-bar button", "Ångra") |> render_click()
      assert has_element?(view, ~s([data-group="fridge"] ) <> row)
      refute has_element?(view, "#undo-bar")

      # A swipe pushes the same.
      view |> element(row) |> render_hook("gone", %{"id" => to_string(butter.id)})
      assert has_element?(view, ~s([data-group="gone"] ) <> row)
      assert has_element?(view, "#undo-bar")
    end

    test "Ta bort takes it out, and Ångra puts it back as it was", %{conn: conn} do
      chicken =
        kept("kycklingfilé", "meat", %{
          quantity: Decimal.new(1640),
          unit: "g",
          pack_size: Decimal.new(820)
        })

      row = ~s([data-item="#{chicken.id}"])

      {:ok, view, _html} = live(conn, ~p"/pantry")
      open_sheet(view, chicken)
      view |> element(~s(#pantry-item [data-role="remove"])) |> render_click()

      refute has_element?(view, row)
      assert Pantry.list_inventory(home_scope()) == []
      assert view |> element("#undo-bar") |> render() =~ "kycklingfilé togs bort"

      view |> element("#undo-bar button", "Ångra") |> render_click()
      assert view |> element(row) |> render() =~ "2 × 820 g"
    end
  end

  test "a line typed in is put away, with its amount", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pantry")

    view |> form("#put-away", %{name: "2 l mjölk"}) |> render_submit()

    assert view |> element("[data-item]") |> render() =~ "mjölk"
    assert view |> element("[data-item]") |> render() =~ "2 l"
  end

  test "each row has its picture: Jev's pick, or its category's until Jev has picked", %{
    conn: conn
  } do
    milk = kept("Mjölk", "dairy")
    butter = kept("Smör", "dairy")

    Tore.Repo.get!(
      Tore.Recipes.Ingredient,
      butter.ingredient_id,
      Tore.Scope.repo_opts(home_scope())
    )
    |> Ecto.Changeset.change(icon: "butter")
    |> Tore.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/pantry")

    assert has_element?(
             view,
             ~s([data-item="#{milk.id}"] img[src="/images/food/milk.svg"])
           )

    assert has_element?(
             view,
             ~s([data-item="#{butter.id}"] img[src="/images/food/butter.svg"])
           )

    refute has_element?(view, "#photo-picker")
  end

  test "a row moves where it belongs once Tore learns its section, without a reload", %{
    conn: conn
  } do
    cheddar = kept("Cheddar", nil)
    {:ok, view, _html} = live(conn, ~p"/pantry")
    assert has_element?(view, ~s([data-group="cupboard"] [data-item="#{cheddar.id}"]))

    :filled =
      Tore.Pantry.Learn.learn(home_scope(), %{
        name: "Cheddar",
        same_as: nil,
        section: "dairy",
        shelf_life_days: nil
      })

    assert has_element?(view, ~s([data-group="fridge"] [data-item="#{cheddar.id}"]))
  end

  test "the menu has Hemma under the household, with how much is at home", %{conn: conn} do
    kept("Mjölk", "dairy")
    {:ok, view, _html} = live(conn, ~p"/plan")
    bar = find_live_child(view, "tab-bar-live")

    render_hook(bar, "open_menu", %{})

    assert bar |> element(~s([data-role="menu-pantry"][href="/pantry"])) |> render() =~
             ~r/Hemma.*1/s
  end
end
