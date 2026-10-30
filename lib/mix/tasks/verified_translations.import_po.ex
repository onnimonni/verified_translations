defmodule Mix.Tasks.VerifiedTranslations.ImportPo do
  @shortdoc "Imports translations from Gettext PO files"
  @moduledoc """
  Imports translated messages from Gettext PO files into
  `priv/translations/<domain>/*.json`.

      mix verified_translations.import_po [PRIV_GETTEXT_DIR] [--domain default]

  Only messages with at least one translation in a configured locale are
  imported, from the given domains (default: `default`; repeat `--domain`).
  Existing JSON files are kept and only their empty locales are filled; an
  unreadable existing file aborts the import. Fuzzy, plural and `msgctxt`
  messages are skipped. Requires `:expo` (a dependency of Gettext).
  """

  use Mix.Task

  alias VerifiedTranslations.{Compiler, Message}

  @compile {:no_warn_undefined, [Expo.PO, Expo.Message]}
  @recursive true

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("loadconfig")
    {opts, args} = OptionParser.parse!(argv, strict: [domain: :keep])

    unless Code.ensure_loaded?(Expo.PO) do
      Mix.raise("verified_translations.import_po requires the :expo dependency")
    end

    dir = List.first(args, "priv/gettext")
    domains = Keyword.get_values(opts, :domain) |> then(&if(&1 == [], do: ["default"], else: &1))
    config = Compiler.config()
    targets = config.locales -- [config.source_locale]

    messages =
      for path <- Path.wildcard(Path.join(dir, "*/LC_MESSAGES/*.po")),
          [domain_file, "LC_MESSAGES", locale | _] = path |> Path.split() |> Enum.reverse(),
          locale in targets,
          Path.rootname(domain_file) in domains,
          # matched as a map so this compiles without Expo
          %{__struct__: Expo.Message.Singular, msgctxt: nil, obsolete: false} = message <-
            Expo.PO.parse_file!(path).messages,
          not Expo.Message.has_flag?(message, "fuzzy"),
          msgstr = IO.iodata_to_binary(message.msgstr),
          msgstr != "" do
        {{Path.rootname(domain_file), IO.iodata_to_binary(message.msgid)}, {locale, msgstr}}
      end
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    written = Enum.count(messages, &import_message(&1, config, targets))
    Mix.shell().info("Imported #{written} message(s) from #{dir} into #{config.path}")
  end

  defp import_message({{domain, msgid}, translations}, config, targets) do
    path = Message.path(config.path, domain, msgid)

    existing =
      case Message.read(path) do
        {:ok, %{"msgid" => ^msgid} = data, _} -> Map.delete(data, "msgid")
        {:ok, _, _} -> Mix.raise("#{path}: msgid does not match #{inspect(msgid)}")
        {:error, :enoent} -> %{}
        {:error, reason} -> Mix.raise("#{path}: #{reason}, fix it before importing")
      end

    merged =
      targets
      |> Map.new(&{&1, ""})
      |> Map.merge(Map.new(translations))
      |> Map.merge(existing, fn _locale, imported, current ->
        if current == "", do: imported, else: current
      end)

    if merged != existing do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Message.encode(msgid, merged))
      true
    end
  end
end
