defmodule VerifiedTranslations do
  @moduledoc ~S"""
  Compile-time verified translations for Phoenix.

  Like `Phoenix.VerifiedRoutes` does for paths, the `~t` sigil verifies at
  compile time that every message is translated to every configured locale,
  and fails compilation otherwise:

      use VerifiedTranslations

      ~t"Welcome back"
      ~t"Hello #{name}"       # source "Hello %{name}", binding name
      ~t"Hello #{@user.name}" # source "Hello %{user_name}"

  Each message lives in its own JSON file holding all locales, so parallel
  branches, worktrees and coding agents never conflict on translation files:

      // priv/translations/default/hello-name-<128-bit hash>.json
      {
        "msgid": "Hello %{name}",
        "fi": "Hei %{name}",
        "sv": "Hej %{name}"
      }

  Translations are inlined into the calling module at compile time, so there
  is no runtime lookup table and no Gettext backend to recompile. Editing a
  JSON file recompiles only the modules that use that message.

  ## Configuration

      config :verified_translations,
        locales: ["en", "fi", "sv"],
        source_locale: "en",            # language of the text in ~t
        path: "priv/translations",      # relative to the project root
        create_missing: true            # write stub files for new messages

  `use VerifiedTranslations` accepts the same keys (plus `:domain`, default
  `"default"`) to override the config per module.

  ## Locale

  The current locale is per process, like Gettext's:

      VerifiedTranslations.put_locale("fi")
      VerifiedTranslations.with_locale("sv", fn -> ~t"Hello #{name}" end)

  Unknown or unset locales render the source text.
  """

  alias VerifiedTranslations.Compiler

  @locale_key {__MODULE__, :locale}
  @gettext? Code.ensure_loaded?(Gettext)

  @doc false
  defmacro __using__(opts), do: Compiler.using(opts, __CALLER__)

  @doc ~S"""
  Translates the text to the current locale, verified at compile time.

  Interpolated variables become bindings named after their access path:
  `#{name}` and `#{@name}` are `%{name}`, `#{@user.name}` is `%{user_name}`.
  """
  defmacro sigil_t({:<<>>, _meta, parts}, modifiers) do
    Compiler.sigil(parts, modifiers, __CALLER__)
  end

  @doc false
  defmacro __before_compile__(env), do: Compiler.before_compile(env)

  @doc """
  Sets the locale of the current process.

  When Gettext is available, also sets Gettext's global locale (and the
  configured `:gettext_backend`'s locale) so `gettext`/`ngettext` calls stay
  in the same language.
  """
  @spec put_locale(String.t()) :: :ok
  def put_locale(locale) when is_binary(locale) do
    Process.put(@locale_key, locale)
    put_gettext_locale(locale)
    :ok
  end

  @doc """
  Returns the locale of the current process.

  Falls back to Gettext's locale (of `gettext_backend` if given) when
  `put_locale/1` was not called, so apps that already set the Gettext locale
  keep working. Returns `nil` without Gettext.
  """
  @spec get_locale(module() | nil) :: String.t() | nil
  def get_locale(gettext_backend \\ nil) do
    case Process.get(@locale_key) do
      nil -> gettext_locale(gettext_backend)
      locale -> locale
    end
  end

  if @gettext? do
    @compile {:no_warn_undefined, Gettext}

    defp put_gettext_locale(locale) do
      Gettext.put_locale(locale)

      if backend = Application.get_env(:verified_translations, :gettext_backend),
        do: Gettext.put_locale(backend, locale)
    end

    defp gettext_locale(nil), do: Gettext.get_locale()
    defp gettext_locale(backend), do: Gettext.get_locale(backend)
  else
    defp put_gettext_locale(_locale), do: :ok
    defp gettext_locale(_backend), do: nil
  end

  @doc "Runs `fun` with `locale` as the current locale, restoring the previous one."
  @spec with_locale(String.t(), (-> result)) :: result when result: term()
  def with_locale(locale, fun) do
    saved = Map.new([@locale_key, Gettext | gettext_backend()], &{&1, Process.get(&1)})
    put_locale(locale)

    try do
      fun.()
    after
      Enum.each(saved, fn
        {key, nil} -> Process.delete(key)
        {key, value} -> Process.put(key, value)
      end)
    end
  end

  defp gettext_backend do
    List.wrap(Application.get_env(:verified_translations, :gettext_backend))
  end

  @doc "Configured locales, including the source locale."
  @spec known_locales() :: [String.t()]
  def known_locales, do: Compiler.config().locales
end
