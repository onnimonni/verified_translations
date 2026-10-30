defmodule VerifiedTranslations.Message do
  @moduledoc """
  One translation file: `<path>/<domain>/<slug>-<hash>.json` holding the
  source text (`"msgid"`) and one key per locale.

  The file name is derived from the source text, so finding a message never
  requires an index and two branches adding different messages never touch
  the same file.
  """

  @doc """
  Path of the JSON file for `msgid`.

  ## Options

    * `:context` - Gettext-style message context (`msgctxt`)
    * `:plural` - `true` for `~t"..."N`, or the source forms map of `tn/2`
  """
  @spec path(Path.t(), String.t(), String.t(), keyword()) :: Path.t()
  def path(root, domain, msgid, opts \\ []) do
    Path.join([root, domain, file_name(identity(msgid, opts), msgid)])
  end

  @doc "Plural source forms in CLDR order, as `path/4` expects for `tn/2` messages."
  @spec sorted_forms(%{String.t() => String.t()}) :: [{String.t(), String.t()}]
  def sorted_forms(forms) do
    order = ~w(zero one two few many other)
    Enum.sort_by(forms, fn {category, _} -> Enum.find_index(order, &(&1 == category)) || 99 end)
  end

  # what the hash covers: messages differing in context or plural forms get
  # their own files, plain messages keep hashing just the msgid
  defp identity(msgid, opts) do
    base =
      case opts[:context] do
        nil -> msgid
        context -> context <> <<4>> <> msgid
      end

    base =
      case opts[:plural] do
        nil -> base
        false -> base
        true -> base <> <<0>> <> "N"
        forms -> base <> <<0>> <> Enum.map_join(forms, <<0>>, fn {k, v} -> "#{k}=#{v}" end)
      end

    if opts[:ordinal], do: base <> <<0>> <> "ordinal", else: base
  end

  # 128-bit digest: collisions are not a practical concern
  @hash_chars 32
  # keeps file names far below the common 255 byte limit
  @slug_bytes 64

  @doc "File name for `msgid`: readable slug plus a content hash of `identity`."
  @spec file_name(String.t(), String.t()) :: String.t()
  def file_name(identity, msgid \\ nil) do
    msgid = msgid || identity

    hash =
      :crypto.hash(:sha256, identity)
      |> Base.encode16(case: :lower)
      |> binary_part(0, @hash_chars)

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
  def encode(msgid, translations, opts \\ []) do
    header =
      [
        opts[:plural] && {"kind", if(opts[:ordinal], do: "ordinal", else: "plural")},
        opts[:context] && {"msgctxt", opts[:context]},
        {"msgid", msgid}
      ]
      |> Enum.reject(&(&1 in [nil, false]))

    lines =
      Enum.map(header ++ Enum.sort(translations), fn {key, value} ->
        "  #{JSON.encode!(key)}: #{encode_value(value)}"
      end)

    "{\n" <> Enum.join(lines, ",\n") <> "\n}\n"
  end

  @categories ~w(zero one two few many other)

  # plural forms in CLDR order, one per line
  defp encode_value(forms) when is_map(forms) do
    lines =
      forms
      |> Enum.sort_by(fn {category, _} ->
        Enum.find_index(@categories, &(&1 == category)) || 99
      end)
      |> Enum.map(fn {category, text} ->
        "    #{JSON.encode!(category)}: #{JSON.encode!(text)}"
      end)

    "{\n" <> Enum.join(lines, ",\n") <> "\n  }"
  end

  defp encode_value(value), do: JSON.encode!(value)

  @doc "Placeholder names (`%{name}`) used in `text`."
  @spec bindings(String.t()) :: [String.t()]
  def bindings(text) do
    ~r/%\{([^{}\s]+)\}/u
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  Merges `translations` into the file for `msgid`, creating it if missing.
  Raises if the existing file is invalid or belongs to another msgid.
  """
  @spec update!(Path.t(), String.t(), %{String.t() => String.t()}) :: :ok
  def update!(path, msgid, translations) do
    existing =
      case read(path) do
        {:ok, %{"msgid" => ^msgid} = data, _} -> data
        {:ok, _, _} -> raise ArgumentError, "#{path}: msgid does not match #{inspect(msgid)}"
        {:error, :enoent} -> %{}
        {:error, reason} -> raise ArgumentError, "#{path}: #{reason}"
      end

    opts = [
      plural: existing["kind"] in ["plural", "ordinal"],
      ordinal: existing["kind"] == "ordinal",
      context: existing["msgctxt"]
    ]

    merged = existing |> Map.drop(["msgid", "msgctxt", "kind"]) |> Map.merge(translations)

    File.mkdir_p!(Path.dirname(path))
    tmp = tmp_path(path)
    File.write!(tmp, encode(msgid, merged, opts))
    File.rename!(tmp, path)
  end

  # unique across VMs (parallel `mix` runs in several worktrees or agents)
  defp tmp_path(path), do: "#{path}.#{:os.getpid()}.#{System.unique_integer([:positive])}.tmp"

  @doc """
  Atomically creates `path` with `content` unless it exists. Returns true if
  written. Parallel compilers never see a partially written file.
  """
  @spec create(Path.t(), String.t()) :: boolean()
  def create(path, content) do
    tmp = tmp_path(path)

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
