defmodule VerifiedTranslations.LiveView do
  @moduledoc """
  `on_mount` hook setting the LiveView process locale from the `"locale"`
  param or session (see `VerifiedTranslations.Plug`):

      live_session :default, on_mount: VerifiedTranslations.LiveView do
        ...
      end

  ## Switching locale in a LiveView

  LiveView's change tracking does not re-render expressions without assigns,
  so `{~t"Settings"}` (like `{gettext("Settings")}`) is not re-sent after a
  locale change. Switch locale by navigating, which remounts and re-renders:

      {:noreply, push_navigate(socket, to: ~p"/settings?locale=fi")}
  """

  @doc false
  def on_mount(_name, params, session, socket) do
    known = VerifiedTranslations.known_locales()
    params = if is_map(params), do: params, else: %{}

    case Enum.find([params["locale"], session["locale"]], &(&1 in known)) do
      nil -> :ok
      locale -> VerifiedTranslations.put_locale(locale)
    end

    {:cont, socket}
  end
end
