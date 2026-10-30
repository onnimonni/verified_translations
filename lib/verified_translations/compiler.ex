defmodule VerifiedTranslations.Compiler do
  @moduledoc false

  alias VerifiedTranslations.Message

  # Placeholder names follow Elixir variable names, including unicode and ?/!
  @binding_regex ~r/%\{([^{}\s]+)\}/u

  @defaults [
    locales: ["en"],
    source_locale: "en",
    path: "priv/translations",
    domain: "default",
    create_missing: true,
    gettext_backend: nil
  ]

  @keys Keyword.keys(@defaults)

  @extract_env "VERIFIED_TRANSLATIONS_EXTRACT"

  @doc "Runtime config: application env over defaults."
  def config(opts \\ []) do
    @defaults
    |> Keyword.merge(Application.get_all_env(:verified_translations))
    |> Keyword.merge(opts)
    |> Keyword.take(@keys)
    |> Map.new()
  end

  # Compile-time config: tracked with compile_env so Mix recompiles callers
  # when it changes and releases verify it was not changed at runtime.
  defp compile_config(opts, env) do
    for key <- @keys, into: %{} do
      default = Application.compile_env(env, :verified_translations, key, @defaults[key])
      {key, Keyword.get(opts, key, default)}
    end
  end

  @doc false
  def extracting?, do: System.get_env(@extract_env) == "1"

  @doc false
  def extract_env, do: @extract_env

  ## use VerifiedTranslations

  # Options are stored by module body code (not at expansion time) so they can
  # use ~w(...), @attributes and other expressions. `def` bodies, where ~t
  # expands, are expanded after the preceding body code has run.
  def using(opts, env) do
    module = env.module
    first? = not Module.has_attribute?(module, :__verified_translations_opts__)

    if first? do
      Module.register_attribute(module, :__verified_translations_errors__, accumulate: true)
      Module.register_attribute(module, :__verified_translations_checks__, accumulate: true)
    end

    quote do
      # a later `use VerifiedTranslations, domain: "admin"` overrides the web module's
      @__verified_translations_opts__ VerifiedTranslations.Compiler.merge_opts(
                                        Module.get_attribute(
                                          __MODULE__,
                                          :__verified_translations_opts__
                                        ),
                                        unquote(opts)
                                      )

      unquote(
        if first? do
          quote do
            import VerifiedTranslations, only: [sigil_t: 2]
            @before_compile VerifiedTranslations
          end
        end
      )
    end
  end

  @doc false
  def merge_opts(previous, opts) do
    Enum.reduce(opts, previous || [], fn {key, value}, acc -> Keyword.put(acc, key, value) end)
  end

  ## ~t expansion

  def sigil(parts, modifiers, env) do
    if modifiers != [], do: compile_error!(env, "~t does not support modifiers")

    opts =
      Module.get_attribute(env.module, :__verified_translations_opts__) ||
        compile_error!(env, "~t requires `use VerifiedTranslations` in the module body")

    config = compile_config(opts, env)

    {msgid, bindings} = parse_parts(parts, env)
    path = config.path |> Message.path(config.domain, msgid) |> Path.expand()
    names = Enum.map(bindings, fn {name, _} -> Atom.to_string(name) end)

    {translations, fingerprint} =
      case load(path, msgid, names, config) do
        {:ok, translations, fingerprint} ->
          {translations, fingerprint}

        {:error, problem, fingerprint} ->
          if extracting?() do
            # forces a recompile after extraction so the checks run for real
            {%{}, :extracted}
          else
            message = "#{inspect(msgid)}: #{problem}\n    #{Path.relative_to_cwd(path)}"
            Module.put_attribute(env.module, :__verified_translations_errors__, {env, message})
            {%{}, fingerprint}
          end
      end

    Module.put_attribute(env.module, :__verified_translations_checks__, {path, fingerprint})
    expand(msgid, bindings, translations, config)
  end

  defp load(path, msgid, names, config) do
    required = config.locales -- [config.source_locale]

    case Message.read(path) do
      {:error, :enoent} ->
        created? =
          (config.create_missing or extracting?()) and
            Message.create(path, Message.encode(msgid, Map.new(required, &{&1, ""})))

        hint =
          if created?,
            do: "created translation file, translate",
            else: "missing translation file for"

        {:error, "#{hint} #{Enum.join(required, ", ")}", :missing}

      {:error, reason} ->
        {:error, reason, :invalid}

      {:ok, data, content} ->
        data =
          if extracting?(), do: add_missing_locales(path, msgid, data, required), else: data

        case validate(data, msgid, names, required, config) do
          [] -> {:ok, Map.delete(data, "msgid"), :erlang.md5(content)}
          problems -> {:error, Enum.join(problems, "; "), :erlang.md5(content)}
        end
    end
  end

  # extract adds empty keys for locales configured after the file was created
  defp add_missing_locales(path, msgid, data, required) do
    case Enum.reject(required, &Map.has_key?(data, &1)) do
      [] ->
        data

      missing ->
        data = Map.merge(data, Map.new(missing, &{&1, ""}))
        File.write!(path, Message.encode(msgid, Map.delete(data, "msgid")))
        data
    end
  end

  defp validate(data, msgid, names, required, config) do
    known = ["msgid" | config.locales]

    identity =
      case Map.fetch(data, "msgid") do
        {:ok, ^msgid} -> []
        {:ok, other} -> ["msgid in file is #{inspect(other)}"]
        :error -> ["msgid is missing"]
      end

    values =
      Enum.flat_map(data, fn
        {"msgid", _} ->
          []

        {key, value} ->
          cond do
            key not in known -> ["unknown locale #{inspect(key)}"]
            not is_binary(value) -> ["#{key} must be a string"]
            true -> unknown_bindings(key, value, names)
          end
      end)

    untranslated =
      for locale <- required, Map.get(data, locale, "") == "", do: "#{locale} is not translated"

    identity ++ values ++ untranslated
  end

  defp unknown_bindings(locale, text, names) do
    case bindings_in(text) -- names do
      [] -> []
      unknown -> ["#{locale} uses unknown #{Enum.map_join(unknown, ", ", &"%{#{&1}}")}"]
    end
  end

  defp bindings_in(text) do
    @binding_regex |> Regex.scan(text, capture: :all_but_first) |> List.flatten() |> Enum.uniq()
  end

  # Inlines all translations: a `case` on the process locale, falling back
  # to the source text. Bindings are evaluated once, into unique variables.
  defp expand(msgid, bindings, translations, config) do
    vars =
      Map.new(bindings, fn {name, _} ->
        {Atom.to_string(name), Macro.unique_var(name, __MODULE__)}
      end)

    assigns =
      for {name, expr} <- bindings do
        {:=, [generated: true], [Map.fetch!(vars, Atom.to_string(name)), expr]}
      end

    source = Map.get(translations, config.source_locale, "")
    default = render(if(source == "", do: msgid, else: source), vars)

    clauses =
      for {locale, text} <- Enum.sort(translations),
          locale != config.source_locale and text != "" do
        {:->, [generated: true], [[locale], render(text, vars)]}
      end

    body =
      case clauses do
        [] ->
          default

        _ ->
          fallback = {:->, [generated: true], [[{:_, [], nil}], default]}
          locale = quote(do: VerifiedTranslations.get_locale(unquote(config.gettext_backend)))
          {:case, [generated: true], [locale, [do: clauses ++ [fallback]]]}
      end

    # variables no branch uses (e.g. omitted by a source override) are still evaluated
    used = for {_, var} <- vars, do: quote(do: _ = unquote(var))
    {:__block__, [], assigns ++ used ++ [body]}
  end

  defp render(text, vars) do
    segments =
      @binding_regex
      |> Regex.split(text, include_captures: true, trim: true)
      |> Enum.map(fn part ->
        case Regex.run(~r/^%\{([^{}\s]+)\}$/u, part, capture: :all_but_first) do
          [name] ->
            quote(do: String.Chars.to_string(unquote(Map.fetch!(vars, name))) :: binary)

          nil ->
            part
        end
      end)

    case segments do
      [] -> ""
      [literal] when is_binary(literal) -> literal
      _ -> {:<<>>, [], segments}
    end
  end

  ## Module callbacks

  def before_compile(env) do
    errors =
      env.module |> Module.get_attribute(:__verified_translations_errors__) |> Enum.reverse()

    if errors != [] do
      [{first, _} | _] = errors

      details =
        Enum.map_join(errors, "\n", fn {env, message} ->
          "  #{Path.relative_to_cwd(env.file)}:#{env.line}: #{message}"
        end)

      raise CompileError,
        file: first.file,
        line: first.line,
        description: """
        #{length(errors)} untranslated message(s) in #{inspect(env.module)}:
        #{details}
        """
    end

    checks =
      env.module |> Module.get_attribute(:__verified_translations_checks__) |> Enum.uniq()

    quote do
      @doc false
      def __verified_translations__, do: unquote(Enum.map(checks, &elem(&1, 0)))

      # Mix asks every module whether it is stale: only modules whose own
      # translation files changed get recompiled (config is tracked by compile_env).
      @doc false
      def __mix_recompile__? do
        VerifiedTranslations.Compiler.stale?(unquote(Macro.escape(checks)))
      end
    end
  end

  @doc false
  def stale?(checks) do
    Enum.any?(checks, fn {path, fingerprint} -> file_fingerprint(path) != fingerprint end)
  end

  defp file_fingerprint(path) do
    case File.read(path) do
      {:ok, content} -> :erlang.md5(content)
      {:error, _} -> :missing
    end
  end

  ## Parsing the sigil

  @doc """
  Turns `~t` parts into a msgid and keyword bindings. Bindings are named
  after the full access path: `name`, `@name` -> `name`; `@user.name`,
  `user.name` -> `user_name`.
  """
  def parse_parts(parts, env) do
    {msgid_parts, bindings} =
      Enum.map_reduce(parts, [], fn
        part, acc when is_binary(part) ->
          text = Macro.unescape_string(part)

          case bindings_in(text) do
            [] ->
              {text, acc}

            [name | _] ->
              compile_error!(
                env,
                "~t text contains literal %{#{name}}; interpolate a variable instead"
              )
          end

        {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [expr]}, {:binary, _, _}]}, acc ->
          name = env |> binding_path(expr) |> Enum.join("_") |> String.to_atom()

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
  defp binding_path(_env, {name, _, ctx}) when is_atom(name) and is_atom(ctx), do: [name]

  # @name (outside HEEx)
  defp binding_path(_env, {:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx),
    do: [name]

  # HEEx rewrites @name to assigns.name
  defp binding_path(env, {{:., _, [{:assigns, _, ctx}, name]}, meta, []})
       when is_atom(ctx) and is_atom(name) do
    if meta[:no_parens], do: [name], else: unsupported_binding!(env)
  end

  # foo.name, @foo.name: only plain field access on a variable or assign
  defp binding_path(env, {{:., _, [left, name]}, meta, []}) when is_atom(name) do
    if meta[:no_parens], do: binding_path(env, left) ++ [name], else: unsupported_binding!(env)
  end

  defp binding_path(env, _expr), do: unsupported_binding!(env)

  defp unsupported_binding!(env) do
    compile_error!(
      env,
      "~t only interpolates variables, assigns or field access " <>
        "(e.g. \#{name}, \#{@name}, \#{@user.name}); bind other expressions to a variable first"
    )
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
