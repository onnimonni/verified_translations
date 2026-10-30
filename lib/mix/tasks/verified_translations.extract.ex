defmodule Mix.Tasks.VerifiedTranslations.Extract do
  @shortdoc "Creates translation files for every ~t and lists untranslated ones"
  @moduledoc """
  Recompiles the project with verification disabled, so every `~t` creates
  its missing translation file in one go (and adds keys for newly configured
  locales), then lists the files that still lack a locale.

      mix verified_translations.extract

  Compilation is re-enabled afterwards, so `mix do verified_translations.extract
  + compile` verifies everything again.
  """

  use Mix.Task

  alias VerifiedTranslations.{Compiler, Message}

  @recursive true

  @impl Mix.Task
  def run(_argv) do
    # extracted modules are stale afterwards, so a later compile verifies them
    Compiler.without_verification(fn -> Mix.Task.run("compile", ["--force"]) end)

    config = Compiler.config()
    required = config.locales -- [config.source_locale]

    untranslated =
      for path <- Path.wildcard(Path.join(config.path, "**/*.json")) do
        case Message.read(path) do
          {:ok, data, _} ->
            case Enum.filter(required, &(Map.get(data, &1, "") == "")) do
              [] -> nil
              missing -> "#{path}: #{Enum.join(missing, ", ")}"
            end

          {:error, reason} ->
            "#{path}: #{inspect(reason)}"
        end
      end
      |> Enum.reject(&is_nil/1)

    case untranslated do
      [] ->
        Mix.shell().info("All messages are translated")

      lines ->
        Mix.shell().info("#{length(lines)} untranslated file(s):\n" <> Enum.join(lines, "\n"))
    end
  end
end
