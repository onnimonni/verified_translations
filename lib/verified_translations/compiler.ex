defmodule VerifiedTranslations.Compiler do
  @moduledoc false

  alias VerifiedTranslations.Message

  @binding_regex ~r/%\{(\w+)\}/

  @defaults [
    locales: ["en"],
    source_locale: "en",
    path: "priv/translations",
    domain: "default",
    create_missing: true
  ]

  @doc "Effective config: `use` options over application env over defaults."
  def config(opts) do
    @defaults
    |> Keyword.merge(Application.get_all_env(:verified_translations))
    |> Keyword.merge(opts)
    |> Keyword.take(Keyword.keys(@defaults))
    |> Map.new()
  end

  ## ~t expansion

  def sigil(parts, modifiers, env) do
    if modifiers != [], do: compile_error!(env, "~t does not support modifiers")

    opts =
      Module.get_attribute(env.module, :__verified_translations_opts__) ||
        compile_error!(env, "~t requires `use VerifiedTranslations`")

    config = config(opts)
    {msgid, bindings} = parse_parts(parts, env)
    path = Message.path(config.path, config.domain, msgid)
    names = Keyword.keys(bindings)

    case bindings_in(msgid) -- Enum.map(names, &Atom.to_string/1) do
      [] ->
        :ok

      literal ->
        compile_error!(
          env,
          "~t text contains literal %{#{hd(literal)}}; interpolate a variable instead"
        )
    end

    extracting? = System.get_env("VERIFIED_TRANSLATIONS_EXTRACT") == "1"

    {translations, fingerprint} =
      case load(path, msgid, names, config) do
        {:ok, translations, fingerprint} ->
          {translations, fingerprint}

        {:error, _problem, _fingerprint} when extracting? ->
          # recompile after extraction so the checks run for real
          {%{}, :extracted}

        {:error, problem, fingerprint} ->
          message = "#{inspect(msgid)}: #{problem}\n    #{Path.relative_to_cwd(path)}"
          Module.put_attribute(env.module, :__verified_translations_errors__, {env, message})
          {%{}, fingerprint}
      end

    Module.put_attribute(env.module, :__verified_translations_checks__, {path, fingerprint})
    expand(msgid, bindings, translations, config)
  end

  defp load(path, msgid, names, config) do
    required = config.locales -- [config.source_locale]

    case Message.read(path) do
      {:error, :enoent} ->
        created? =
          config.create_missing and
            Message.create(path, Message.encode(msgid, Map.new(required, &{&1, ""})))

        hint =
          if created?,
            do: "created translation file, translate",
            else: "missing translation file for"

        {:error, "#{hint} #{Enum.join(required, ", ")}", :missing}

      {:error, reason} ->
        {:error, reason, :invalid}

      {:ok, data, content} ->
        fingerprint = :erlang.md5(content)

        case validate(data, msgid, names, required, config) do
          [] -> {:ok, Map.delete(data, "msgid"), fingerprint}
          problems -> {:error, Enum.join(problems, "; "), fingerprint}
        end
    end
  end

  defp validate(data, msgid, names, required, config) do
    allowed = Enum.map(names, &Atom.to_string/1)
    known = ["msgid" | config.locales]

    Enum.flat_map(data, fn
      {"msgid", ^msgid} ->
        []

      {"msgid", other} ->
        ["msgid in file is #{inspect(other)}"]

      {key, value} ->
        cond do
          key not in known -> ["unknown locale #{inspect(key)}"]
          not is_binary(value) -> ["#{key} must be a string"]
          true -> unknown_bindings(key, value, allowed)
        end
    end) ++
      for locale <- required, Map.get(data, locale, "") == "", do: "#{locale} is not translated"
  end

  defp unknown_bindings(locale, text, allowed) do
    case bindings_in(text) -- allowed do
      [] -> []
      unknown -> ["#{locale} uses unknown #{Enum.map_join(unknown, ", ", &"%{#{&1}}")}"]
    end
  end

  defp bindings_in(text) do
    @binding_regex |> Regex.scan(text, capture: :all_but_first) |> List.flatten() |> Enum.uniq()
  end

  # Inlines all translations: a `case` on the process locale, falling back
  # to the source text. Bindings are evaluated once.
  defp expand(msgid, bindings, translations, config) do
    vars =
      Map.new(bindings, fn {name, _} -> {Atom.to_string(name), Macro.var(name, __MODULE__)} end)

    assigns = for {name, expr} <- bindings, do: {:=, [], [Macro.var(name, __MODULE__), expr]}
    source = Map.get(translations, config.source_locale, "")
    default = render(if(source == "", do: msgid, else: source), vars)

    clauses =
      for {locale, text} <- Enum.sort(translations),
          locale != config.source_locale and text != "" do
        {:->, [], [[locale], render(text, vars)]}
      end

    body =
      case clauses do
        [] ->
          default

        _ ->
          {:case, [],
           [
             quote(do: VerifiedTranslations.get_locale()),
             [do: clauses ++ [{:->, [], [[{:_, [], nil}], default]}]]
           ]}
      end

    {:__block__, [], assigns ++ [body]}
  end

  defp render(text, vars) do
    segments =
      @binding_regex
      |> Regex.split(text, include_captures: true, trim: true)
      |> Enum.map(fn part ->
        case Regex.run(~r/^%\{(\w+)\}$/, part, capture: :all_but_first) do
          [name] -> quote(do: String.Chars.to_string(unquote(Map.fetch!(vars, name))) :: binary)
          nil -> part
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

    opts = Module.get_attribute(env.module, :__verified_translations_opts__)
    checks = env.module |> Module.get_attribute(:__verified_translations_checks__) |> Enum.uniq()

    quote do
      @doc false
      def __verified_translations__, do: unquote(Enum.map(checks, &elem(&1, 0)))

      # Mix asks every module whether it is stale: only modules whose own
      # translation files (or config) changed get recompiled.
      @doc false
      def __mix_recompile__? do
        VerifiedTranslations.Compiler.stale?(
          unquote(Macro.escape(opts)),
          unquote(Macro.escape(config(opts))),
          unquote(Macro.escape(checks))
        )
      end
    end
  end

  @doc false
  def stale?(opts, config, checks) do
    config(opts) != config or
      Enum.any?(checks, fn {path, fingerprint} -> file_fingerprint(path) != fingerprint end)
  end

  defp file_fingerprint(path) do
    case File.read(path) do
      {:ok, content} -> :erlang.md5(content)
      {:error, _} -> :missing
    end
  end

  ## Parsing the sigil

  @doc "Turns `~t` parts into a msgid and keyword bindings."
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
end
