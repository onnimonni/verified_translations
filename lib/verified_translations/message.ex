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

  @doc "File name for `msgid`: readable slug plus a short content hash."
  @spec file_name(String.t()) :: String.t()
  def file_name(msgid) do
    hash = :crypto.hash(:sha256, msgid) |> Base.encode16(case: :lower) |> binary_part(0, 8)

    slug =
      msgid
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
      |> String.trim("-")
      |> String.split("-")
      |> Enum.reduce_while("", fn word, acc ->
        next = if acc == "", do: word, else: acc <> "-" <> word
        if String.length(next) > 48, do: {:halt, acc}, else: {:cont, next}
      end)

    if slug == "", do: "#{hash}.json", else: "#{slug}-#{hash}.json"
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

  @doc "Writes `content` to `path` unless the file exists. Returns true if written."
  @spec create(Path.t(), String.t()) :: boolean()
  def create(path, content) do
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, content, [:exclusive]) do
      :ok -> true
      {:error, :eexist} -> false
    end
  end
end
