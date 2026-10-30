if Code.ensure_loaded?(Plug.Conn) do
  defmodule VerifiedTranslations.Plug do
    @moduledoc """
    Sets the locale from `?locale=fi`, falling back to the session.

        plug VerifiedTranslations.Plug

    A locale from the query string is stored in the session (when fetched)
    so LiveViews mounted later can pick it up with
    `VerifiedTranslations.LiveView`.

    ## Options

      * `:param` - query parameter name, default `"locale"`
      * `:session_key` - session key, default `"locale"`
    """

    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts) do
      %{
        param: Keyword.get(opts, :param, "locale"),
        session_key: Keyword.get(opts, :session_key, "locale")
      }
    end

    @impl Plug
    def call(conn, %{param: param, session_key: key}) do
      conn = fetch_query_params(conn)
      known = VerifiedTranslations.known_locales()
      session? = Map.has_key?(conn.private, :plug_session)

      query = conn.query_params[param]
      session = if session?, do: get_session(conn, key)

      cond do
        query in known ->
          VerifiedTranslations.put_locale(query)
          if session?, do: put_session(conn, key, query), else: conn

        session in known ->
          VerifiedTranslations.put_locale(session)
          conn

        true ->
          conn
      end
    end
  end
end
