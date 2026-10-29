defmodule Mix.Tasks.VerifiedTranslations.ImportPo do
  @shortdoc "Imports translations from Gettext PO files"
  @moduledoc """
  Imports translated messages from Gettext PO files into
  `priv/translations/<domain>/*.json`.

      mix verified_translations.import_po [PRIV_GETTEXT_DIR]

  Only messages with at least one translation in a configured locale are
  imported. Existing JSON files are kept; only their empty locales are filled.
  Plural and context (`msgctxt`) messages are skipped. Requires `:expo`
  (a dependency of Gettext).
  """

  use Mix.Task

  alias VerifiedTranslations.{Compiler, Message}

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("loadconfig")

    unless Code.ensure_loaded?(Expo.PO) do
      Mix.raise("verified_translations.import_po requires the :expo dependency")
    end

    dir = List.first(argv, "priv/gettext")
    config = Compiler.config([])

    messages =
      for path <- Path.wildcard(Path.join(dir, "*/LC_MESSAGES/*.po")),
          [domain_file, "LC_MESSAGES", locale | _] = path |> Path.split() |> Enum.reverse(),
          locale in config.locales,
          %Expo.Message.Singular{msgctxt: nil, obsolete: false} = message <-
            Expo.PO.parse_file!(path).messages,
          not Expo.Message.has_flag?(message, "fuzzy"),
          msgstr = IO.iodata_to_binary(message.msgstr),
          msgstr != "" do
        {{Path.rootname(domain_file), IO.iodata_to_binary(message.msgid)}, {locale, msgstr}}
      end
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    written =
      Enum.count(messages, fn {{domain, msgid}, translations} ->
        path = Message.path(config.path, domain, msgid)
        required = Map.new(config.locales -- [config.source_locale], &{&1, ""})

        existing =
          case Message.read(path) do
            {:ok, data, _} -> Map.delete(data, "msgid")
            {:error, _} -> %{}
          end

        merged =
          required
          |> Map.merge(Map.new(translations))
          |> Map.merge(existing, fn _locale, imported, current ->
            if current == "", do: imported, else: current
          end)

        if merged != existing do
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, Message.encode(msgid, merged))
          true
        end
      end)

    Mix.shell().info("Imported #{written} message(s) from #{dir} into #{config.path}")
  end
end
