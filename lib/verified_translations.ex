defmodule VerifiedTranslations do
  @moduledoc ~S"""
  Compile-time verified Gettext translations.

  Like `Phoenix.VerifiedRoutes` does for paths, the `~t` sigil verifies at
  compile time that every message has a translation in every known locale.
  A missing, empty or fuzzy translation (or a translation that references an
  unknown `%{binding}`) fails compilation.

      use VerifiedTranslations, backend: MyAppWeb.Gettext

      ~t"Welcome back"
      ~t"Hello #{name}"       # msgid "Hello %{name}", bindings %{name: name}
      ~t"Hello #{@user.name}" # msgid "Hello %{name}"

  `use VerifiedTranslations` also calls `use Gettext, backend: ...`, so the
  regular Gettext macros (`gettext/1`, `ngettext/3`, ...) keep working.

  ## Options

    * `:backend` (required) - the Gettext backend module.
    * `:domain` - Gettext domain for `~t`. Defaults to the backend's default domain.
    * `:locales` - locales that must be translated. Defaults to all locales
      found in the backend's priv directory (`known_locales`).
    * `:source_locale` - locale whose msgstr may be empty because the msgid
      itself is the text. Defaults to the backend's default locale
      (usually `"en"`). Its PO entries are optional.
    * `:allow_fuzzy` - treat `#, fuzzy` entries as translated. Defaults to `false`.

  Verification is skipped while running `mix gettext.extract`, so you can
  always extract new messages:

      mix gettext.extract --merge
  """

  alias VerifiedTranslations.Verifier

  @doc false
  defmacro __using__(opts) do
    backend = Macro.expand(Keyword.fetch!(opts, :backend), __CALLER__)
    module = __CALLER__.module
    first_use? = not Module.has_attribute?(module, :__verified_translations__)

    Module.put_attribute(module, :__verified_translations__, %{
      backend: backend,
      domain: Keyword.get(opts, :domain, :default),
      locales: Keyword.get(opts, :locales),
      source_locale: Keyword.get(opts, :source_locale),
      allow_fuzzy: Keyword.get(opts, :allow_fuzzy, false)
    })

    if first_use? do
      Module.register_attribute(module, :__verified_translations_errors__, accumulate: true)
    end

    quote do
      use Gettext, backend: unquote(backend)
      # compile-time dependency: PO changes recompile the backend and thus callers
      require unquote(backend)
      import VerifiedTranslations, only: [sigil_t: 2]
      unquote(if first_use?, do: quote(do: @before_compile(VerifiedTranslations)))
    end
  end

  @doc ~S"""
  Translates the string using the configured Gettext backend, verifying at
  compile time that the translation exists in all locales.

  Interpolated variables become Gettext bindings named after the variable,
  assign or the last field of the accessed path.
  """
  defmacro sigil_t({:<<>>, _meta, parts}, modifiers) do
    env = __CALLER__

    if modifiers != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "~t does not support modifiers, got: #{modifiers}"
    end

    config =
      Module.get_attribute(env.module, :__verified_translations__) ||
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "~t requires `use VerifiedTranslations, backend: MyAppWeb.Gettext`"

    {msgid, bindings} = Verifier.parse_parts(parts, env)

    unless Gettext.Extractor.extracting?() do
      case Verifier.verify(config, msgid, Keyword.keys(bindings)) do
        :ok ->
          :ok

        {:error, message} ->
          Module.put_attribute(
            env.module,
            :__verified_translations_errors__,
            {env.file, env.line, message}
          )
      end
    end

    quote do
      Gettext.Macros.dgettext_with_backend(
        unquote(config.backend),
        unquote(config.domain),
        unquote(msgid),
        %{unquote_splicing(bindings)}
      )
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    errors =
      env.module |> Module.get_attribute(:__verified_translations_errors__) |> Enum.reverse()

    if errors != [] do
      [{file, line, _} | _] = errors

      details =
        Enum.map_join(errors, "\n\n", fn {file, line, message} ->
          "#{Path.relative_to_cwd(file)}:#{line}: #{message}"
        end)

      raise CompileError,
        file: file,
        line: line,
        description: """
        #{length(errors)} unverified translation(s) in #{inspect(env.module)}:

        #{details}

        Run `mix gettext.extract --merge` and translate the messages in priv/gettext.
        """
    end

    nil
  end
end
