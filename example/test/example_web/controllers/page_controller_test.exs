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
  end

  test "GET /?locale=sv", %{conn: conn} do
    html = conn |> get(~p"/?locale=sv") |> html_response(200)
    assert html =~ "Välkommen, Onni!"
  end
end
