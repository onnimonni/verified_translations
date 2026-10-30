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
  @index_key {__MODULE__, :index}
  @gettext? Code.ensure_loaded?(Gettext)

  @doc false
  defmacro __using__(opts), do: Compiler.using(opts, __CALLER__)

  @doc ~S"""
  Translates the text to the current locale, verified at compile time.

  Interpolated variables become bindings named after their access path:
  `#{name}` and `#{@name}` are `%{name}`, `#{@user.name}` is `%{user_name}`.
  """
  defmacro sigil_t(text, modifiers)

  defmacro sigil_t(text, modifiers) when is_binary(text) do
    Compiler.sigil([text], modifiers, __CALLER__)
  end

  defmacro sigil_t({:<<>>, _meta, parts}, modifiers) do
    Compiler.sigil(parts, modifiers, __CALLER__)
  end

  @doc ~S"""
  Translates a plural message, choosing the CLDR plural category of `count`
  for the current locale.

      tn(length(files), one: "%{count} file", other: "%{count} files")
      tn(@n, one: "#{@user.name} has one item", other: "#{@user.name} has %{count} items")

  The forms must be exactly the source locale's CLDR categories (`one` and
  `other` for English). `%{count}` is the first argument; other values are
  interpolated like in `~t`. The message file holds one object of forms per
  locale, verified to have exactly that locale's categories:

      {"kind": "plural", "msgid": "%{count} files",
       "fi": {"one": "%{count} tiedosto", "other": "%{count} tiedostoa"}}

  `~t"#{count} file(s)"N` (gettext_sigils compatible) is the same with one
  source text for every category.

  Ordinals use CLDR's ordinal categories and are stored as `"kind": "ordinal"`:

      tn(place, ordinal: true, one: "%{count}st", two: "%{count}nd", few: "%{count}rd", other: "%{count}th")
  """
  defmacro tn(count, forms), do: Compiler.plural(count, forms, __CALLER__)

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
    Process.put(@index_key, index_of(locale))
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
    saved =
      Map.new([@locale_key, @index_key, Gettext | gettext_backend()], &{&1, Process.get(&1)})

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

  @doc false
  # Runtime of ~t (see Compiler.expand/5): picks the slot or template and fills
  # in binding values. Templates are binaries or lists of binaries and binding
  # indexes.
  def render(text, _values) when is_binary(text), do: text
  def render(parts, values), do: parts |> fill(values) |> IO.iodata_to_binary()

  @doc false
  # plural runtime: {cldr_language, %{category => template}}
  def render_plural({lang, forms}, values, count_index, type \\ :cardinal) do
    category = VerifiedTranslations.Plural.category(lang, elem(values, count_index), type)
    render(Map.get(forms, category) || Map.fetch!(forms, "other"), values)
  end

  @doc false
  # bindings of gettext/2 calls with non-literal bindings
  def fetch_binding!(bindings, key) when is_map(bindings) or is_list(bindings) do
    case Access.fetch(bindings, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing binding %{#{key}} in #{inspect(bindings)}"
    end
  end

  @doc false
  # gettext_sigils compatible postprocess modifiers, applied in order
  def postprocess!(modifiers, string) do
    Enum.reduce(modifiers, string, fn {module, opts}, string ->
      case module.postprocess(string, opts) do
        {:ok, string} -> string
        {:error, %{__exception__: true} = e} -> raise ArgumentError, Exception.message(e)
        {:error, reason} -> raise ArgumentError, "#{inspect(module)}: #{reason}"
      end
    end)
  end

  defp fill([], _values), do: []

  defp fill([index | rest], values) when is_integer(index),
    do: [string(elem(values, index)) | fill(rest, values)]

  defp fill([text | rest], values), do: [text | fill(rest, values)]

  defp string(value) when is_binary(value), do: value
  defp string(value), do: String.Chars.to_string(value)

  @doc false
  # Position of the current locale in `known_locales/0`; unknown locales get
  # the last slot, which holds the source text.
  @spec locale_index(module() | nil) :: non_neg_integer()
  def locale_index(gettext_backend \\ nil) do
    case Process.get(@index_key) do
      nil -> index_of(get_locale(gettext_backend))
      index -> index
    end
  end

  defp index_of(locale) do
    locales = known_locales()
    Enum.find_index(locales, &(&1 == locale)) || length(locales)
  end

  @doc "Configured locales, including the source locale."
  @spec known_locales() :: [String.t()]
  def known_locales, do: Compiler.config().locales
end
