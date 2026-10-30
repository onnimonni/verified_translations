defmodule Mix.Tasks.VerifiedTranslations.Review do
  @shortdoc "Lists machine translations that a human hasn't reviewed"
  @moduledoc """
  Lists machine translations a human hasn't reviewed (`"origin"` with
  `"by": "machine"`), with the model that made them, and marks them reviewed.

      mix verified_translations.review                    # list, exit 1 if any (for CI)
      mix verified_translations.review --json             # for scripts
      mix verified_translations.review --locale fi        # only Finnish
      mix verified_translations.review --approve --locale fi "Hello %{name}"

  `--approve` adds `"reviewed": true` to the listed translations' origin,
  optionally limited to `--locale` and to the msgids given as arguments. The
  model stays recorded. Approving is for people who checked the
  translations; AI agents must not approve their own translations.

  Set `config :verified_translations, machine_translations: :error` (or
  `:warn`) to make compilation fail on (or warn about) unreviewed machine
  translations, for example in CI or production builds.
  """

  use Mix.Task

  alias VerifiedTranslations.{Compiler, Message}

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("loadconfig")

    {opts, msgids} =
      OptionParser.parse!(argv, strict: [json: :boolean, approve: :boolean, locale: :keep])

    locales = Keyword.get_values(opts, :locale)
    config = Compiler.config()

    pending =
      for path <- config.path |> Path.join("*/*.json") |> Path.wildcard() |> Enum.sort(),
          {:ok, data, _} <- [Message.read(path)],
          msgids == [] or data["msgid"] in msgids,
          {locale, %{"by" => "machine"} = origin} <- Enum.sort(Map.get(data, "origin", %{})),
          origin["reviewed"] != true,
          locales == [] or locale in locales do
        %{
          "path" => path,
          "msgid" => data["msgid"],
          "locale" => locale,
          "text" => data[locale],
          "model" => origin["model"]
        }
      end

    cond do
      opts[:approve] ->
        approve(pending)

      opts[:json] ->
        IO.puts(JSON.encode!(pending))

      pending == [] ->
        Mix.shell().info("No unreviewed machine translations")

      true ->
        Enum.each(pending, fn p ->
          model = if p["model"], do: " (#{p["model"]})", else: ""

          Mix.shell().info(
            "#{p["locale"]}: #{inspect(p["msgid"])} -> #{inspect(p["text"])}#{model}"
          )
        end)

        Mix.raise("#{length(pending)} unreviewed machine translation(s)")
    end
  end

  defp approve(pending) do
    pending
    |> Enum.group_by(& &1["path"])
    |> Enum.each(fn {path, entries} ->
      {:ok, data, _} = Message.read(path)

      # keeps by/model, so it stays visible which model produced it
      origin =
        Enum.reduce(entries, data["origin"], fn entry, origin ->
          Map.update!(origin, entry["locale"], &Map.put(&1, "reviewed", true))
        end)

      translations = data |> Map.drop(["msgid", "msgctxt", "kind"]) |> Map.put("origin", origin)

      opts = [
        plural: data["kind"] in ["plural", "ordinal"],
        ordinal: data["kind"] == "ordinal",
        context: data["msgctxt"]
      ]

      File.write!(path, Message.encode(data["msgid"], translations, opts))
    end)

    Mix.shell().info("Marked #{length(pending)} translation(s) as reviewed")
  end
end
