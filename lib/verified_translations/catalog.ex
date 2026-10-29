defmodule VerifiedTranslations.Catalog do
  @moduledoc false

  # Parsed PO files of a Gettext backend, cached per compiler VM and
  # invalidated when any PO file changes.

  alias Expo.Message

  @type entry :: %{msgstr: String.t(), fuzzy?: boolean()}
  @type t :: %{{locale :: String.t(), domain :: String.t()} => %{String.t() => entry}}

  @spec fetch(module()) :: t()
  def fetch(backend) do
    files = backend.__gettext__(:priv) |> Path.join("*/LC_MESSAGES/*.po") |> Path.wildcard()
    fingerprint = Enum.map(files, &{&1, File.stat!(&1).mtime, File.stat!(&1).size})
    key = {__MODULE__, backend}

    case :persistent_term.get(key, nil) do
      {^fingerprint, catalog} ->
        catalog

      _ ->
        catalog = Map.new(files, &parse/1)
        :persistent_term.put(key, {fingerprint, catalog})
        catalog
    end
  end

  defp parse(path) do
    [domain_file, "LC_MESSAGES", locale | _] = path |> Path.split() |> Enum.reverse()

    entries =
      for %Message.Singular{msgctxt: nil, obsolete: false} = message <-
            Expo.PO.parse_file!(path).messages,
          into: %{} do
        {IO.iodata_to_binary(message.msgid),
         %{
           msgstr: IO.iodata_to_binary(message.msgstr),
           fuzzy?: Message.has_flag?(message, "fuzzy")
         }}
      end

    {{locale, Path.rootname(domain_file)}, entries}
  end
end
