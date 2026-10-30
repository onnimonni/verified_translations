defmodule ExampleWeb.PageControllerTest do
  use ExampleWeb.ConnCase

  test "GET /", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "Peace of mind from prototype to production"
    assert html =~ "Welcome, Onni!"
  end

  test "GET /?locale=fi", %{conn: conn} do
    html = conn |> get(~p"/?locale=fi") |> html_response(200)
    assert html =~ "Mielenrauhaa prototyypistä tuotantoon."
    assert html =~ "Tervetuloa, Onni!"
    assert html =~ "Yritetään yhdistää uudelleen"
    # Gettext follows the same locale
    assert Gettext.get_locale(ExampleWeb.Gettext) == "fi"
  end

  test "locale is remembered in the session", %{conn: conn} do
    conn = get(conn, ~p"/?locale=sv")
    html = conn |> recycle() |> get(~p"/") |> html_response(200)
    assert html =~ "Välkommen, Onni!"
  end
end
