defmodule ExampleWeb.Plugs.Locale do
  @moduledoc "Sets the translation locale from `?locale=fi`."
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = Plug.Conn.fetch_query_params(conn)
    locale = conn.params["locale"]

    if locale in VerifiedTranslations.locales() do
      VerifiedTranslations.put_locale(locale)
    end

    conn
  end
end
