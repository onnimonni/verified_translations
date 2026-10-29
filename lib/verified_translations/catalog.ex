defmodule VerifiedTranslations.Catalog do
  @moduledoc false

  # Parsed PO files of a Gettext priv directory, cached in :persistent_term for the
  # lifetime of the compiler VM and invalidated when any PO file changes.

  alias Expo.Message

  @type entry :: %{msgstr: String.t(), fuzzy?: boolean()}
  @type t :: %{{locale :: String.t(), domain :: String.t()} => %{String.t() => entry}}

  @spec fetch(Path.t()) :: t()
  def fetch(priv) do
    key = {__MODULE__, priv}
    fingerprint = fingerprint(priv)

    case :persistent_term.get(key, nil) do
      {^fingerprint, catalog} ->
        catalog

      _ ->
        # many modules expand ~t in parallel: parse each PO file set only once
        :global.trans({key, self()}, fn ->
          case :persistent_term.get(key, nil) do
            {^fingerprint, catalog} ->
              catalog

            _ ->
              catalog = parse_all(priv)
              :persistent_term.put(key, {fingerprint, catalog})
              catalog
          end
        end)
    end
  end

  defp po_files(priv), do: priv |> Path.join("*/LC_MESSAGES/*.po") |> Path.wildcard()

  @doc "Cheap change detection for the PO files in `priv` (path, mtime, size, inode)."
  def fingerprint(priv) do
    for path <- po_files(priv) do
      %File.Stat{mtime: mtime, size: size, inode: inode} = File.stat!(path, time: :posix)
      {path, mtime, size, inode}
    end
  end

  defp parse_all(priv) do
    priv
    |> po_files()
    |> Task.async_stream(&parse/1, timeout: :infinity)
    |> Map.new(fn {:ok, entry} -> entry end)
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
