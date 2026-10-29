defmodule ExampleWeb.PageController do
  use ExampleWeb, :controller

  def home(conn, _params) do
    render(conn, :home, name: "Onni")
  end
end
