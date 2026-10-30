defmodule Mix.Tasks.VerifiedTranslations.Missing do
  @shortdoc "Lists messages that lack a translation"
  @moduledoc """
  Lists translation files with empty or missing locales, without compiling.

      mix verified_translations.missing          # human readable, exit 1 if any
      mix verified_translations.missing --json   # for scripts and AI agents

  The JSON output can be filled in and fed back to
  `mix verified_translations.put --from FILE`. Plural messages list the
  locale's CLDR categories to fill:

      [{"msgid": "%{count} files", "kind": "plural", "path": "priv/...json",
        "domain": "default", "missing": ["fi"], "fi": {"one": "", "other": ""}}]

  Run `mix verified_translations.extract` first to create files for new
  `~t` messages.
  """

  use Mix.Task

  alias VerifiedTranslations.{Compiler, Message, Plural}

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("loadconfig")
    {opts, _} = OptionParser.parse!(argv, strict: [json: :boolean])
    config = Compiler.config()
    required = config.locales -- [config.source_locale]

    missing =
      for path <- config.path |> Path.join("*/*.json") |> Path.wildcard() |> Enum.sort(),
          {:ok, data, _} <- [Message.read(path)],
          locales = Enum.filter(required, &untranslated?(Map.get(data, &1), plural?(data))),
          locales != [] do
        type = if data["kind"] == "ordinal", do: :ordinal, else: :cardinal
        filled = Map.new(locales, &{&1, fill(Map.get(data, &1), &1, plural?(data), type)})

        data
        |> Map.merge(filled)
        |> Map.merge(%{
          "domain" => path |> Path.dirname() |> Path.basename(),
          "path" => path,
          "missing" => locales
        })
      end

    if opts[:json] do
      IO.puts(JSON.encode!(missing))
    else
      Enum.each(missing, fn m ->
        Mix.shell().info(
          "#{m["domain"]}: #{inspect(m["msgid"])} missing #{Enum.join(m["missing"], ", ")}"
        )
      end)

      if missing != [], do: Mix.raise("#{length(missing)} message(s) lack translations")
    end
  end

  defp plural?(data), do: data["kind"] in ["plural", "ordinal"]

  defp untranslated?(nil, _plural?), do: true
  defp untranslated?("", _plural?), do: true

  defp untranslated?(forms, true) when is_map(forms),
    do: forms == %{} or Enum.any?(forms, fn {_, text} -> text == "" end)

  defp untranslated?(_value, _plural?), do: false

  # plural locales list their CLDR categories, keeping forms already there
  defp fill(current, locale, true, type) do
    categories =
      case Plural.language(locale) do
        nil -> []
        lang -> Plural.categories(lang, type)
      end

    current = if is_map(current), do: current, else: %{}
    Map.new(categories, &{&1, Map.get(current, &1, "")})
  end

  defp fill(_current, _locale, false, _type), do: ""
end
