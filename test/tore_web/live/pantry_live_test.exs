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

  test "tapping a thing's amount says what's left of it; nothing left is gone", %{conn: conn} do
    pasta = kept("Spaghetti", "dry_goods", %{quantity: Decimal.new(1), unit: "kg"})
    row = ~s([data-item="#{pasta.id}"])

    {:ok, view, _html} = live(conn, ~p"/pantry")
    assert view |> element(row <> ~s( [data-role="left"])) |> render() =~ "1 kg"

    view |> element(row <> ~s( [data-role="left"])) |> render_click()
    view |> form("#left-#{pasta.id}", %{left: "400 g"}) |> render_submit()

    assert view |> element(row <> ~s( [data-role="left"])) |> render() =~ "400 g"
    [left] = Pantry.list_inventory(home_scope())
    assert {Decimal.to_string(left.quantity, :normal), left.unit} == {"400", "g"}

    view |> element(row <> ~s( [data-role="left"])) |> render_click()
    view |> form("#left-#{pasta.id}", %{left: "0"}) |> render_submit()
    assert has_element?(view, ~s([data-group="gone"] ) <> row)
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

  test "the menu has Hemma under the household, with how much is at home", %{conn: conn} do
    kept("Mjölk", "dairy")
    {:ok, view, _html} = live(conn, ~p"/plan")
    bar = find_live_child(view, "tab-bar-live")

    render_hook(bar, "open_menu", %{})

    assert bar |> element(~s([data-role="menu-pantry"][href="/pantry"])) |> render() =~
             ~r/Hemma.*1/s
  end
end
