defmodule Mix.Tasks.VerifiedTranslations.Missing do
  @shortdoc "Lists messages that lack a translation"
  @moduledoc """
  Lists translation files with empty or missing locales, without compiling.

      mix verified_translations.missing          # human readable, exit 1 if any
      mix verified_translations.missing --json   # for scripts and AI agents

  The JSON output can be edited and fed back to
  `mix verified_translations.put --from FILE`:

      [{"msgid": "Hello %{name}", "domain": "default", "missing": ["sv"], "fi": "Hei %{name}", "sv": ""}]

  Run `mix verified_translations.extract` first to create files for new `~t`
  messages.
  """

  use Mix.Task

  alias VerifiedTranslations.{Compiler, Message}

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("loadconfig")
    {opts, _} = OptionParser.parse!(argv, strict: [json: :boolean])
    config = Compiler.config()
    required = config.locales -- [config.source_locale]

    missing =
      for path <- Path.wildcard(Path.join(config.path, "*/*.json")) |> Enum.sort(),
          {:ok, data, _} <- [Message.read(path)],
          locales = Enum.filter(required, &(Map.get(data, &1, "") == "")),
          locales != [] do
        data
        |> Map.merge(Map.new(required, &{&1, Map.get(data, &1, "")}))
        |> Map.merge(%{
          "domain" => path |> Path.dirname() |> Path.basename(),
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
end
