defmodule VerifiedTranslations.PluralTest do
  use ExUnit.Case, async: true

  alias VerifiedTranslations.Plural

  doctest Plural

  test "categories" do
    assert Plural.categories("fi") == ["one", "other"]
    assert Plural.categories("ja") == ["other"]
    assert Plural.categories("ru") == ["one", "few", "many", "other"]
    assert Plural.categories("xx") == []
  end

  test "languages" do
    assert Plural.language("fi_FI") == "fi"
    assert Plural.language("pt-PT") == "pt-PT"
    assert Plural.language("pt_BR") == "pt"
    assert Plural.language("xx") == nil
  end

  test "integers" do
    assert Enum.map([0, 1, 2, 5], &Plural.category("en", &1)) == ~w(other one other other)

    assert Enum.map([1, 2, 5, 11, 21, 22, 25, 111], &Plural.category("ru", &1)) ==
             ~w(one few many many one few many many)

    assert Enum.map([0, 1, 2, 3, 11, 100], &Plural.category("ar", &1)) ==
             ~w(zero one two few many other)

    assert Enum.map([0, 1, 2], &Plural.category("fr", &1)) == ~w(one one other)
    # CLDR: "1 000 000 de fichiers"
    assert Plural.category("fr", 1_000_000) == "many"
    assert Plural.category("ja", 1) == "other"
    assert Plural.category("en", -1) == "one"
  end

  test "decimals" do
    # en: one needs v = 0, a float 1.0 has a visible fraction digit
    assert Plural.category("en", 1.0) == "other"
    assert Plural.category("en", "1") == "one"
    assert Plural.category("en", "1.0") == "other"
    assert Plural.category("en", 1.5) == "other"
    # ru: decimals are other
    assert Plural.category("ru", 1.5) == "other"
    # fr: i = 0,1
    assert Plural.category("fr", 1.5) == "one"
  end
end

defmodule VerifiedTranslations.PluralConformanceTest do
  use ExUnit.Case, async: true

  alias VerifiedTranslations.Plural

  # every sample value CLDR lists for every language and category
  test "matches CLDR's own samples" do
    rules =
      "priv/cldr/plurals.json"
      |> File.read!()
      |> JSON.decode!()
      |> get_in(["supplemental", "plurals-type-cardinal"])

    failures =
      for {lang, categories} <- rules,
          {"pluralRule-count-" <> category, rule} <- categories,
          sample <- samples(rule),
          Plural.category(lang, sample) != category,
          do: {lang, sample, category, Plural.category(lang, sample)}

    assert failures == []
  end

  defp samples(rule) do
    ~r/@(?:integer|decimal)([^@]*)/
    |> Regex.scan(rule, capture: :all_but_first)
    |> Enum.flat_map(fn [list] -> String.split(list, ",") end)
    |> Enum.map(&String.trim/1)
    # compact exponents (1c3) need the c/e operands, which counts never carry
    |> Enum.reject(&(&1 in ["", "…"] or &1 =~ ~r/[ce]/))
    |> Enum.flat_map(&String.split(&1, "~"))
  end
end
