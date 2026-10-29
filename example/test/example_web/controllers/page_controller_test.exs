defmodule ExampleWeb.PageControllerTest do
  use ExampleWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
    assert html_response(conn, 200) =~ "Welcome, Onni!"
  end

  test "GET / in finnish", %{conn: conn} do
    Gettext.put_locale(ExampleWeb.Gettext, "fi")
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Mielenrauhaa prototyypistä tuotantoon."
    assert html_response(conn, 200) =~ "Tervetuloa, Onni!"
  end
end
