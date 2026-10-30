defmodule VerifiedTranslations.Plural do
  @moduledoc """
  CLDR cardinal plural rules, compiled from the bundled
  `priv/cldr/plurals.json` (CLDR 49, Unicode License v3).

      iex> VerifiedTranslations.Plural.category("fi", 1)
      "one"
      iex> VerifiedTranslations.Plural.category("ru", 22)
      "few"
      iex> VerifiedTranslations.Plural.categories("ar")
      ["zero", "one", "two", "few", "many", "other"]

  Counts may be integers, floats, `Decimal`s or numeric strings ("1.50"
  keeps its two visible fraction digits, which matters in some languages).
  """

  alias VerifiedTranslations.Plural.Parser

  @external_resource path = Path.join([__DIR__, "..", "..", "priv", "cldr", "plurals.json"])

  @order ~w(zero one two few many other)

  rules =
    path
    |> File.read!()
    |> JSON.decode!()
    |> get_in(["supplemental", "plurals-type-cardinal"])
    |> Map.new(fn {lang, rules} ->
      categories =
        for category <- @order,
            rule = rules["pluralRule-count-#{category}"],
            do: {category, rule}

      {lang, categories}
    end)

  vars = Map.new(~w(n i v w f t c e), &{&1, Macro.var(String.to_atom(&1), __MODULE__)})

  @doc "CLDR plural categories of a CLDR language, in canonical order."
  @spec categories(String.t()) :: [String.t()]
  for {lang, categories} <- rules do
    def categories(unquote(lang)), do: unquote(Enum.map(categories, &elem(&1, 0)))
  end

  def categories(_lang), do: []

  @doc """
  The CLDR language whose rules apply to `locale` (`"pt_PT"` -> `"pt-PT"`,
  `"fi_FI"` -> `"fi"`), or `nil` when CLDR has no rules for it.
  """
  @spec language(String.t()) :: String.t() | nil
  def language(locale) do
    locale = String.replace(locale, "_", "-")
    [base | _] = String.split(locale, "-")
    Enum.find([locale, base], &(categories(&1) != []))
  end

  @doc "Plural category of `count` for a CLDR language (see `language/1`)."
  @spec category(String.t(), number() | String.t() | struct()) :: String.t()
  def category(lang, count) when is_integer(count) do
    n = abs(count)
    select(lang, n, n, 0, 0, 0, 0, 0, 0)
  end

  def category(lang, count) do
    {n, i, v, w, f, t} = operands(count)
    select(lang, n, i, v, w, f, t, 0, 0)
  end

  for {lang, categories} <- rules do
    clauses =
      for {category, rule} <- categories, category != "other" do
        {:->, [], [[Parser.compile(rule, vars)], category]}
      end

    args = Enum.map(~w(n i v w f t c e), &Map.fetch!(vars, &1))

    defp select(unquote(lang), unquote_splicing(args)) do
      _ = {unquote_splicing(args)}
      cond do: unquote(clauses ++ [{:->, [], [[true], "other"]}])
    end
  end

  defp select(_lang, _n, _i, _v, _w, _f, _t, _c, _e), do: "other"

  # operands from the decimal string representation
  defp operands(count) do
    string = count |> to_decimal_string() |> String.trim_leading("-")

    {int, frac} =
      case String.split(string, ".", parts: 2) do
        [int] -> {int, ""}
        [int, frac] -> {int, frac}
      end

    i = String.to_integer(int)
    trimmed = String.trim_trailing(frac, "0")
    f = if frac == "", do: 0, else: String.to_integer(frac)
    t = if trimmed == "", do: 0, else: String.to_integer(trimmed)
    n = if f == 0, do: i, else: String.to_float(int <> "." <> frac)
    {n, i, String.length(frac), String.length(trimmed), f, t}
  end

  defp to_decimal_string(count) when is_float(count), do: :erlang.float_to_binary(count, [:short])
  defp to_decimal_string(count) when is_binary(count), do: count
  defp to_decimal_string(count), do: to_string(count)

  @doc false
  def mod(n, divisor) when is_integer(n), do: rem(n, divisor)
  def mod(n, divisor), do: n - divisor * Float.floor(n / divisor)

  @doc false
  def whole?(n) when is_integer(n), do: true
  def whole?(n), do: n == Float.floor(n)
end
