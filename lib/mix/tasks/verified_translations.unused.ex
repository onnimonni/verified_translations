defmodule Mix.Tasks.VerifiedTranslations.Unused do
  @shortdoc "Lists (or deletes) translation files no ~t uses"
  @moduledoc """
  Compiles the project and lists translation files that no `~t` refers to.

      mix verified_translations.unused           # list, exit 1 if any (for CI)
      mix verified_translations.unused --delete  # delete them
  """

  use Mix.Task

  alias VerifiedTranslations.Compiler

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: [delete: :boolean])
    Mix.Task.run("compile")

    app = Mix.Project.config()[:app]
    Application.load(app)

    used =
      for module <- Application.spec(app, :modules) || [],
          Code.ensure_loaded?(module),
          function_exported?(module, :__verified_translations__, 0),
          path <- module.__verified_translations__(),
          into: MapSet.new(),
          do: Path.expand(path)

    unused =
      Compiler.config([]).path
      |> Path.join("**/*.json")
      |> Path.wildcard()
      |> Enum.reject(&MapSet.member?(used, Path.expand(&1)))

    cond do
      unused == [] ->
        Mix.shell().info("No unused translations")

      opts[:delete] ->
        Enum.each(unused, &File.rm!/1)
        Mix.shell().info("Deleted #{length(unused)} unused translation file(s)")

      true ->
        Enum.each(unused, &Mix.shell().info/1)
        Mix.raise("#{length(unused)} unused translation file(s), delete with --delete")
    end
  end
end
