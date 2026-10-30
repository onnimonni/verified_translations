defmodule VerifiedTranslations.Plural.Parser do
  @moduledoc false

  # Compiles CLDR plural rule conditions (UTS #35, "Language Plural Rules")
  # into quoted Elixir booleans over the operands n, i, v, w, f, t, c, e:
  #
  #   condition     = and_condition ('or' and_condition)*
  #   and_condition = relation ('and' relation)*
  #   relation      = expr ('=' | '!=') range_list
  #   expr          = operand (('mod' | '%') value)?
  #   range_list    = (value | value'..'value) (',' range_list)*
  #
  # Samples after `@integer` / `@decimal` are ignored.

  @operands ~w(n i v w f t c e)

  @doc "Quoted condition for `rule`, using `vars` (operand name => quoted var)."
  def compile(rule, vars) do
    rule
    |> String.split("@", parts: 2)
    |> hd()
    |> String.trim()
    |> case do
      "" -> true
      condition -> condition |> tokenize() |> parse_or(vars)
    end
  end

  defp tokenize(condition) do
    ~r/\.\.|!=|=|%|,|[a-z]+|\d+/
    |> Regex.scan(condition)
    |> List.flatten()
  end

  defp parse_or(tokens, vars) do
    tokens
    |> split_on("or")
    |> Enum.map(fn and_tokens ->
      and_tokens
      |> split_on("and")
      |> Enum.map(&relation(&1, vars))
      |> Enum.reduce(&quote(do: unquote(&2) and unquote(&1)))
    end)
    |> Enum.reduce(&quote(do: unquote(&2) or unquote(&1)))
  end

  defp split_on(tokens, word) do
    tokens
    |> Enum.chunk_by(&(&1 == word))
    |> Enum.reject(&(&1 == [word]))
  end

  defp relation(tokens, vars) do
    {expr_tokens, [op | ranges]} = Enum.split_while(tokens, &(&1 not in ["=", "!="]))
    {expr, operand} = expr(expr_tokens, vars)

    membership =
      ranges
      |> Enum.chunk_by(&(&1 == ","))
      |> Enum.reject(&(&1 == [","]))
      |> Enum.map(&range_check(&1, expr, operand))
      |> Enum.reduce(&quote(do: unquote(&2) or unquote(&1)))

    if op == "=", do: membership, else: quote(do: not unquote(membership))
  end

  defp expr([operand], vars) when operand in @operands, do: {Map.fetch!(vars, operand), operand}

  defp expr([operand, mod, value], vars) when operand in @operands and mod in ["%", "mod"] do
    var = Map.fetch!(vars, operand)
    divisor = String.to_integer(value)
    # n may be a decimal; the other operands are integers
    {quote(do: VerifiedTranslations.Plural.mod(unquote(var), unquote(divisor))), operand}
  end

  defp range_check([value], expr, _operand) do
    quote(do: unquote(expr) == unquote(String.to_integer(value)))
  end

  defp range_check([from, "..", to], expr, _operand) do
    {from, to} = {String.to_integer(from), String.to_integer(to)}

    # a decimal n is only in a range when it is a whole number
    quote do
      VerifiedTranslations.Plural.whole?(unquote(expr)) and unquote(expr) >= unquote(from) and
        unquote(expr) <= unquote(to)
    end
  end
end
