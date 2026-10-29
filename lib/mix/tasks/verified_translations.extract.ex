defmodule Mix.Tasks.VerifiedTranslations.Extract do
  @shortdoc "Creates translation files for every ~t and lists untranslated ones"
  @moduledoc """
  Recompiles the project with verification disabled, so every `~t` creates
  its missing translation file in one go, then lists the files that still
  lack a locale.

      mix verified_translations.extract

  A normal `mix compile` afterwards verifies everything again.
  """

  use Mix.Task

  alias VerifiedTranslations.{Compiler, Message}

  @impl Mix.Task
  def run(_argv) do
    System.put_env("VERIFIED_TRANSLATIONS_EXTRACT", "1")

    try do
      Mix.Task.run("compile", ["--force"])
    after
      System.delete_env("VERIFIED_TRANSLATIONS_EXTRACT")
    end

    config = Compiler.config([])
    required = config.locales -- [config.source_locale]

    untranslated =
      for path <- Path.wildcard(Path.join(config.path, "**/*.json")),
          {:ok, data, _} <- [Message.read(path)],
          missing = Enum.filter(required, &(Map.get(data, &1, "") == "")),
          missing != [],
          do: "#{path}: #{Enum.join(missing, ", ")}"

    case untranslated do
      [] ->
        Mix.shell().info("All messages are translated")

      lines ->
        Mix.shell().info("#{length(lines)} untranslated file(s):\n" <> Enum.join(lines, "\n"))
    end
  end
end
