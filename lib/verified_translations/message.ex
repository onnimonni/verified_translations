defmodule VerifiedTranslations.Message do
  @moduledoc """
  One translation file: `<path>/<domain>/<slug>-<hash>.json` holding the
  source text (`"msgid"`) and one key per locale.

  The file name is derived from the source text, so finding a message never
  requires an index and two branches adding different messages never touch
  the same file.
  """

  @doc "Path of the JSON file for `msgid`."
  @spec path(Path.t(), String.t(), String.t()) :: Path.t()
  def path(root, domain, msgid), do: Path.join([root, domain, file_name(msgid)])

  # 128-bit digest: collisions are not a practical concern
  @hash_chars 32
  # keeps file names far below the common 255 byte limit
  @slug_bytes 64

  @doc "File name for `msgid`: readable slug plus a content hash."
  @spec file_name(String.t()) :: String.t()
  def file_name(msgid) do
    hash =
      :crypto.hash(:sha256, msgid) |> Base.encode16(case: :lower) |> binary_part(0, @hash_chars)

    slug =
      msgid
      |> String.normalize(:nfc)
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
      |> String.trim("-")
      |> truncate(@slug_bytes)
      |> String.trim("-")

    if slug == "", do: "#{hash}.json", else: "#{slug}-#{hash}.json"
  end

  # cut at a word boundary when possible, otherwise at a grapheme boundary
  defp truncate(slug, max) when byte_size(slug) <= max, do: slug

  defp truncate(slug, max) do
    words =
      slug
      |> String.split("-")
      |> Enum.reduce_while("", fn word, acc ->
        next = if acc == "", do: word, else: acc <> "-" <> word
        if byte_size(next) > max, do: {:halt, acc}, else: {:cont, next}
      end)

    if words != "" do
      words
    else
      slug
      |> String.graphemes()
      |> Enum.reduce_while("", fn g, acc ->
        if byte_size(acc <> g) > max, do: {:halt, acc}, else: {:cont, acc <> g}
      end)
    end
  end

  @doc "Reads a message file."
  @spec read(Path.t()) :: {:ok, map(), binary()} | {:error, :enoent | String.t()}
  def read(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{} = data} <- JSON.decode(content) do
      {:ok, data, content}
    else
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} when is_atom(reason) -> {:error, inspect(reason)}
      {:ok, _} -> {:error, "expected a JSON object"}
      {:error, reason} -> {:error, "invalid JSON: #{inspect(reason)}"}
    end
  end

  @doc """
  Encodes a message deterministically: `msgid` first, then locales sorted.
  """
  @spec encode(String.t(), %{String.t() => String.t()}) :: String.t()
  def encode(msgid, translations) do
    lines =
      [{"msgid", msgid} | Enum.sort(translations)]
      |> Enum.map(fn {key, value} -> "  #{JSON.encode!(key)}: #{JSON.encode!(value)}" end)

    "{\n" <> Enum.join(lines, ",\n") <> "\n}\n"
  end

  @doc """
  Atomically creates `path` with `content` unless it exists. Returns true if
  written. Parallel compilers never see a partially written file.
  """
  @spec create(Path.t(), String.t()) :: boolean()
  def create(path, content) do
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, content) do
      # a hard link fails if the target exists, unlike rename
      result = File.ln(tmp, path) == :ok
      File.rm(tmp)
      result
    else
      _ -> false
    end
  end
end
