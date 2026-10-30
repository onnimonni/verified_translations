defmodule VerifiedTranslations.PO do
  @moduledoc false

  # Reads translations from Gettext PO files: for the compile-time check that
  # flags messages still translated only in PO files, for `extract`, which
  # imports them, and for `migrate`. Needs Expo (a Gettext dependency) only
  # when PO files exist.

  alias VerifiedTranslations.Plural

  @compile {:no_warn_undefined, [Expo.PO, Expo.Message, Expo.Messages, Expo.PluralForms]}

  @type key :: {domain :: String.t(), context :: String.t() | nil, msgid :: String.t()}
  @type entry :: {:singular, String.t()} | {:plural, [String.t()], struct() | nil}

  @doc """
  Translations of one message from the PO files under `dir`, for `locales`:
  `%{locale => text}` for singular messages, `%{locale => %{category => text}}`
  for plurals (gettext plural indexes mapped to CLDR categories).
  """
  @spec lookup(Path.t(), [String.t()], key(), :singular | :plural) :: %{String.t() => term()}
  def lookup(dir, locales, {domain, context, msgid}, kind) do
    catalog = catalog(dir)

    for locale <- locales,
        entry = Map.get(catalog, {locale, domain, context, msgid}),
        translation = convert(entry, kind, locale),
        translation not in [nil, ""],
        into: %{},
        do: {locale, translation}
  end

  @doc "Translations of the whole PO file content of one locale."
  def parse(content, locale) do
    po = Expo.PO.parse_string!(content)
    plural_forms = plural_forms(po, locale)

    for message <- po.messages,
        not message.obsolete,
        not Expo.Message.has_flag?(message, "fuzzy"),
        entry = entry(message, plural_forms),
        entry != nil,
        into: %{} do
      context = if message.msgctxt, do: IO.iodata_to_binary(message.msgctxt)
      {{context, IO.iodata_to_binary(message.msgid)}, entry}
    end
  end

  defp entry(%{__struct__: Expo.Message.Singular, msgstr: msgstr}, _plural_forms) do
    case IO.iodata_to_binary(msgstr) do
      "" -> nil
      text -> {:singular, text}
    end
  end

  defp entry(%{__struct__: Expo.Message.Plural, msgstr: msgstr}, plural_forms) do
    texts = msgstr |> Enum.sort() |> Enum.map(fn {_, text} -> IO.iodata_to_binary(text) end)
    if Enum.all?(texts, &(&1 == "")), do: nil, else: {:plural, texts, plural_forms}
  end

  defp plural_forms(po, locale) do
    with [header | _] <- Expo.Messages.get_header(po, "Plural-Forms"),
         {:ok, forms} <- Expo.PluralForms.parse(header) do
      forms
    else
      _ ->
        case Expo.PluralForms.Known.plural_form(locale) do
          {:ok, forms} -> forms
          _ -> nil
        end
    end
  end

  @doc """
  Maps gettext plural forms (`msgstr[0..n]`) to CLDR categories: each
  category takes the form gettext selects for a count in that category.
  """
  def convert({:singular, text}, :singular, _locale), do: text

  def convert({:plural, texts, plural_forms}, :plural, locale) do
    lang = Plural.language(locale)

    if lang && plural_forms do
      Map.new(Plural.categories(lang), fn category ->
        index =
          case Enum.find(0..1000, &(Plural.category(lang, &1) == category)) do
            # decimal-only categories (e.g. Russian "other"): gettext uses the last form
            nil -> length(texts) - 1
            n -> min(Expo.PluralForms.index(plural_forms, n), length(texts) - 1)
          end

        {category, Enum.at(texts, index)}
      end)
    end
  end

  def convert(_entry, _kind, _locale), do: nil

  # {locale, domain, context, msgid} => entry, cached per compiler VM and
  # invalidated when any PO file changes
  defp catalog(dir) do
    case Path.wildcard(Path.join(dir, "*/LC_MESSAGES/*.po")) do
      [] -> %{}
      files -> cached_catalog(dir, files)
    end
  end

  defp cached_catalog(dir, files) do
    key = {__MODULE__, Path.expand(dir)}

    fingerprint =
      for path <- files, do: {path, File.stat!(path, time: :posix).mtime, File.stat!(path).size}

    case :persistent_term.get(key, nil) do
      {^fingerprint, catalog} ->
        catalog

      _ ->
        catalog =
          for path <- files,
              [domain_file, "LC_MESSAGES", locale | _] = path |> Path.split() |> Enum.reverse(),
              {{context, msgid}, entry} <- parse(File.read!(path), locale),
              into: %{},
              do: {{locale, Path.rootname(domain_file), context, msgid}, entry}

        :persistent_term.put(key, {fingerprint, catalog})
        catalog
    end
  end
end
