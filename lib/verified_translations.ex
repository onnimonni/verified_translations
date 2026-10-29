defmodule VerifiedTranslations do
  @moduledoc ~S"""
  Compile-time verified translations for Phoenix.

  Like `Phoenix.VerifiedRoutes` does for paths, the `~t` sigil verifies at
  compile time that every message is translated to every configured locale,
  and fails compilation otherwise:

      use VerifiedTranslations

      ~t"Welcome back"
      ~t"Hello #{name}"       # source "Hello %{name}", binding name
      ~t"Hello #{@user.name}" # source "Hello %{name}"

  Each message lives in its own JSON file holding all locales, so parallel
  branches, worktrees and coding agents never conflict on translation files:

      // priv/translations/default/hello-name-1b2c3d4e.json
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

  @doc false
  defmacro __using__(opts) do
    module = __CALLER__.module

    unless Module.has_attribute?(module, :__verified_translations_opts__) do
      Module.register_attribute(module, :__verified_translations_errors__, accumulate: true)
      Module.register_attribute(module, :__verified_translations_checks__, accumulate: true)
      Module.put_attribute(module, :__verified_translations_opts__, opts)

      quote do
        import VerifiedTranslations, only: [sigil_t: 2]
        @before_compile VerifiedTranslations
      end
    end
  end

  @doc ~S"""
  Translates the text to the current locale, verified at compile time.

  Interpolated variables become bindings named after the variable, assign or
  the last field of the accessed path: `#{@user.name}` is `%{name}`.
  """
  defmacro sigil_t({:<<>>, _meta, parts}, modifiers) do
    Compiler.sigil(parts, modifiers, __CALLER__)
  end

  @doc false
  defmacro __before_compile__(env), do: Compiler.before_compile(env)

  @doc "Sets the locale of the current process."
  @spec put_locale(String.t()) :: :ok
  def put_locale(locale) when is_binary(locale) do
    Process.put(@locale_key, locale)
    :ok
  end

  @doc "Returns the locale of the current process, or `nil` when unset."
  @spec get_locale() :: String.t() | nil
  def get_locale, do: Process.get(@locale_key)

  @doc "Runs `fun` with `locale` as the current locale."
  @spec with_locale(String.t(), (-> result)) :: result when result: term()
  def with_locale(locale, fun) do
    previous = get_locale()
    put_locale(locale)

    try do
      fun.()
    after
      if previous, do: put_locale(previous), else: Process.delete(@locale_key)
    end
  end

  @doc "Configured locales, including the source locale."
  @spec locales() :: [String.t()]
  def locales, do: Compiler.config([]).locales
end
