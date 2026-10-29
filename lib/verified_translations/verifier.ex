defmodule VerifiedTranslations.Verifier do
  @moduledoc false

  alias VerifiedTranslations.Catalog

  @binding_regex ~r/%\{(\w+)\}/

  @doc """
  Turns the parts of a `~t` sigil into a Gettext msgid and keyword bindings.
  """
  def parse_parts(parts, env) do
    {msgid_parts, bindings} =
      Enum.map_reduce(parts, [], fn
        part, acc when is_binary(part) ->
          {part, acc}

        {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [expr]}, {:binary, _, _}]}, acc ->
          name = binding_name(expr, env)

          case Keyword.fetch(acc, name) do
            {:ok, existing} ->
              if Macro.to_string(existing) != Macro.to_string(expr) do
                compile_error!(env, "~t binding %{#{name}} is used for different expressions")
              end

              {"%{#{name}}", acc}

            :error ->
              {"%{#{name}}", acc ++ [{name, expr}]}
          end
      end)

    {IO.iodata_to_binary(msgid_parts), bindings}
  end

  # name
  defp binding_name({name, _, ctx}, _env) when is_atom(name) and is_atom(ctx), do: name
  # @name (outside HEEx)
  defp binding_name({:@, _, [{name, _, ctx}]}, _env) when is_atom(name) and is_atom(ctx), do: name
  # foo.name, @foo.name and HEEx-rewritten assigns.name
  defp binding_name({{:., _, [_, name]}, meta, []}, env) when is_atom(name) do
    if meta[:no_parens], do: name, else: unsupported_binding!(env)
  end

  defp binding_name(_expr, env), do: unsupported_binding!(env)

  defp unsupported_binding!(env) do
    compile_error!(
      env,
      "~t only interpolates variables, assigns or field access " <>
        "(e.g. \#{name}, \#{@name}, \#{user.name}); bind complex expressions to a variable first"
    )
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end

  @doc """
  Verifies `msgid` against the PO files of every required locale.
  """
  def verify(config, msgid, bindings) do
    %{priv: priv, domain: domain} = config
    catalog = Catalog.fetch(priv)
    source_locale = config.source_locale || Application.get_env(:gettext, :default_locale, "en")
    locales = config.locales || catalog |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    problems =
      locales
      |> Enum.sort()
      |> Enum.flat_map(fn locale ->
        case check(catalog, locale, domain, msgid, bindings, source_locale, config) do
          nil -> []
          problem -> ["  * #{locale}: #{problem} (#{po_path(priv, locale, domain)})"]
        end
      end)

    case problems do
      [] ->
        :ok

      problems ->
        {:error,
         "translation for #{inspect(msgid)} (domain #{inspect(domain)}) is not verified:\n" <>
           Enum.join(problems, "\n")}
    end
  end

  @doc """
  Called from `__mix_recompile__?/0` of modules using `~t`: true when any of
  the module's messages no longer verifies, so Mix recompiles it and reports.
  """
  def stale?(checks) do
    Enum.any?(checks, fn {config, msgid, bindings} -> verify(config, msgid, bindings) != :ok end)
  rescue
    _ -> true
  end

  defp check(catalog, locale, domain, msgid, bindings, source_locale, config) do
    case catalog |> Map.get({locale, domain}, %{}) |> Map.fetch(msgid) do
      # the msgid itself is the source text
      :error when locale == source_locale ->
        nil

      :error ->
        "missing msgid"

      {:ok, %{msgstr: ""}} when locale == source_locale ->
        nil

      {:ok, %{msgstr: ""}} ->
        "empty msgstr"

      {:ok, %{fuzzy?: true}} when locale != source_locale and not config.allow_fuzzy ->
        "fuzzy translation"

      {:ok, %{msgstr: msgstr}} ->
        case unknown_bindings(msgstr, bindings) do
          [] -> nil
          unknown -> "msgstr uses unknown binding(s) #{Enum.map_join(unknown, ", ", &"%{#{&1}}")}"
        end
    end
  end

  defp unknown_bindings(msgstr, bindings) do
    allowed = Enum.map(bindings, &Atom.to_string/1)

    @binding_regex
    |> Regex.scan(msgstr, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&(&1 in allowed))
  end

  defp po_path(priv, locale, domain),
    do: Path.join([priv, locale, "LC_MESSAGES", "#{domain}.po"])
end
