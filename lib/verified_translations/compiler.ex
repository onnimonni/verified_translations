defmodule VerifiedTranslations.Compiler do
  @moduledoc false

  alias VerifiedTranslations.{Message, Plural, PO}

  # Placeholder names follow Elixir variable names, including unicode and ?/!
  @binding_regex ~r/%\{([^{}\s]+)\}/u

  @defaults [
    locales: ["en"],
    source_locale: "en",
    path: "priv/translations",
    gettext_path: "priv/gettext",
    domain: "default",
    context: nil,
    modifiers: [],
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

    # gettext_sigils compatible: `backend:` also brings in the Gettext macros
    use_gettext =
      if Keyword.keyword?(opts) && opts[:backend] do
        quote do: use(Gettext, backend: unquote(opts[:backend]))
      end

    # gettext/ngettext/... become verified JSON lookups (opt out: gettext: false)
    override_gettext =
      if first? and not (Keyword.keyword?(opts) and opts[:gettext] == false) do
        # imports are lexically scoped, so decide here rather than in an `if`
        hide_gettext =
          if Code.ensure_loaded?(Gettext.Macros) do
            quote do
              import Gettext.Macros,
                except: unquote(VerifiedTranslations.GettextMacros.overridden())
            end
          end

        quote do
          unquote(hide_gettext)
          import VerifiedTranslations.GettextMacros
        end
      end

    quote do
      unquote(use_gettext)
      unquote(override_gettext)

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
            import VerifiedTranslations, only: [sigil_t: 2, tn: 2]
            @before_compile VerifiedTranslations
          end
        end
      )
    end
  end

  @doc false
  # Accepts our flat options and gettext_sigils' `backend:` + `sigils: [domain:,
  # context:, modifiers:]`.
  def merge_opts(previous, opts) do
    opts =
      Enum.flat_map(opts, fn
        {:backend, backend} -> [gettext_backend: backend]
        {:sigils, sigils} -> sigils
        {:gettext, _} -> []
        {:domain, :default} -> [domain: "default"]
        other -> [other]
      end)

    Enum.reduce(opts, previous || [], fn {key, value}, acc -> Keyword.put(acc, key, value) end)
  end

  defp module_config(env) do
    opts =
      Module.get_attribute(env.module, :__verified_translations_opts__) ||
        compile_error!(env, "~t requires `use VerifiedTranslations` in the module body")

    compile_config(opts, env)
  end

  ## ~t and tn

  def sigil(parts, modifier_chars, env) do
    config = module_config(env)
    {plural?, modifiers} = modifiers(modifier_chars, config, env)
    {msgid, bindings} = parse_parts(parts, env)

    {{msgid, bindings}, {domain, context}} =
      apply_modifiers(modifiers, {msgid, bindings}, {config.domain, config.context}, env)

    if plural? and not Keyword.has_key?(bindings, :count) do
      compile_error!(env, ~s|plural message requires a "count" binding, but none was found|)
    end

    message = %{
      msgid: msgid,
      domain: domain,
      context: context,
      plural: plural?,
      source_forms: nil,
      bindings: bindings
    }

    message |> compile(config, env) |> postprocess(modifiers)
  end

  def plural(count, forms, env) do
    config = module_config(env)

    unless Keyword.keyword?(forms) and forms != [] do
      compile_error!(
        env,
        "tn/2 expects literal plural forms, e.g. tn(count, one: \"...\", other: \"...\")"
      )
    end

    # tn(n, ordinal: true, one: "%{count}st", two: "%{count}nd", ...)
    {ordinal?, forms} = Keyword.pop(forms, :ordinal, false)
    type = if ordinal? == true, do: :ordinal, else: :cardinal

    {source_forms, bindings} =
      Enum.reduce(forms, {%{}, []}, fn {category, text}, {forms, bindings} ->
        parts =
          case text do
            text when is_binary(text) -> [text]
            {:<<>>, _, parts} -> parts
            _ -> compile_error!(env, "tn/2 forms must be string literals")
          end

        {msgid, form_bindings} = parse_parts(parts, env, ["count"])

        {Map.put(forms, Atom.to_string(category), msgid),
         merge_bindings(bindings ++ form_bindings, env)}
      end)

    if Keyword.has_key?(bindings, :count) do
      compile_error!(env, "tn/2 binds %{count} to its first argument; don't interpolate a count")
    end

    source_lang = Plural.language(config.source_locale)
    expected = Plural.categories(source_lang || "", type)

    if Enum.sort(Map.keys(source_forms)) != Enum.sort(expected) do
      compile_error!(
        env,
        "tn/2 needs exactly the #{inspect(config.source_locale)} #{if type == :ordinal, do: "ordinal", else: "plural"} categories " <>
          "#{inspect(expected)}, got #{inspect(Map.keys(source_forms))}"
      )
    end

    message = %{
      msgid: source_forms["other"],
      domain: config.domain,
      context: config.context,
      plural: true,
      type: type,
      source_forms: source_forms,
      bindings: bindings ++ [count: count]
    }

    compile(message, config, env)
  end

  @doc false
  # gettext/ngettext/... overrides (VerifiedTranslations.GettextMacros): same
  # msgid and binding names as written, verified and read from JSON
  def gettext(domain, context, msgid, msgid_plural, count, bindings, env) do
    config = module_config(env)
    msgid = literal!(msgid, "msgid", env)
    msgid_plural = msgid_plural && literal!(msgid_plural, "msgid_plural", env)
    context = context && literal!(context, "context", env)

    domain =
      case domain do
        :default -> config.domain
        domain -> literal!(domain, "domain", env)
      end

    plural? = msgid_plural != nil
    texts = Enum.reject([msgid, msgid_plural], &is_nil/1)

    keys =
      texts
      |> Enum.flat_map(&bindings_in/1)
      |> Enum.uniq()
      |> Kernel.--(if plural?, do: ["count"], else: [])

    {bindings, prelude} = gettext_bindings(bindings, keys, env)
    bindings = if plural?, do: Keyword.put(bindings, :count, count), else: bindings

    source_forms =
      if plural? do
        lang = Plural.language(config.source_locale) || "en"

        Map.new(Plural.categories(lang), fn
          "one" -> {"one", msgid}
          category -> {category, msgid_plural}
        end)
      end

    message = %{
      msgid: msgid_plural || msgid,
      domain: domain,
      context: context,
      plural: plural?,
      source_forms: source_forms,
      bindings: bindings
    }

    code = compile(message, config, env)
    if prelude, do: {:__block__, [], [prelude, code]}, else: code
  end

  # literal keyword lists are used as is; other expressions are evaluated once
  # and each placeholder fetched from the result
  defp gettext_bindings(ast, keys, env) do
    if is_list(ast) and Keyword.keyword?(ast) do
      given = Enum.map(ast, fn {key, _} -> Atom.to_string(key) end)

      case keys -- given do
        [] ->
          {ast, nil}

        [key | _] ->
          compile_error!(
            env,
            "binding %{#{key}} is missing, given: #{inspect(Keyword.keys(ast))}"
          )
      end
    else
      var = Macro.unique_var(:bindings, __MODULE__)

      bindings =
        for key <- keys do
          key = String.to_atom(key)
          {key, quote(do: VerifiedTranslations.fetch_binding!(unquote(var), unquote(key)))}
        end

      {bindings, quote(do: unquote(var) = unquote(ast))}
    end
  end

  defp literal!(ast, what, env) do
    case expand_literal(ast, env) do
      text when is_binary(text) ->
        text

      _ ->
        compile_error!(
          env,
          "#{what} must be a compile-time string, got: #{Macro.to_string(ast)}. " <>
            "Use Gettext.gettext/3 and friends for dynamic messages"
        )
    end
  end

  defp expand_literal(text, _env) when is_binary(text), do: text

  defp expand_literal({:<>, _, [left, right]}, env) do
    with left when is_binary(left) <- expand_literal(left, env),
         right when is_binary(right) <- expand_literal(right, env),
         do: left <> right
  end

  defp expand_literal({:<<>>, _, parts}, env) do
    parts = Enum.map(parts, &expand_literal(&1, env))
    if Enum.all?(parts, &is_binary/1), do: Enum.join(parts), else: :error
  end

  defp expand_literal({:@, _, [{name, _, ctx}]}, env) when is_atom(name) and is_atom(ctx),
    do: Module.get_attribute(env.module, name)

  defp expand_literal(_ast, _env), do: :error

  defp compile(message, config, env) do
    identity =
      if message.source_forms,
        do: Message.sorted_forms(message.source_forms),
        else: message.plural

    path =
      config.path
      |> Message.path(message.domain, message.msgid, file_opts(message, identity))
      |> Path.expand()

    names = Enum.map(message.bindings, fn {name, _} -> Atom.to_string(name) end)

    {translations, fingerprint} =
      case load(path, message, names, config) do
        {:ok, translations, fingerprint} ->
          {translations, fingerprint}

        {:error, problem, fingerprint} ->
          if extracting?() do
            # forces a recompile after extraction so the checks run for real
            {%{}, :extracted}
          else
            text = message.msgid

            label =
              if message.context,
                do: "#{inspect(text)} (context #{inspect(message.context)})",
                else: inspect(text)

            error = "#{label}: #{problem}\n    #{Path.relative_to_cwd(path)}"
            Module.put_attribute(env.module, :__verified_translations_errors__, {env, error})
            {%{}, fingerprint}
          end
      end

    Module.put_attribute(env.module, :__verified_translations_checks__, {path, fingerprint})
    expand(message, translations, config, env)
  end

  # Message.path/encode options; ordinals are a kind of their own
  defp file_opts(message, plural) do
    [context: message.context, plural: plural, ordinal: type(message) == :ordinal]
  end

  defp type(message), do: Map.get(message, :type, :cardinal)

  defp kind(%{plural: false}), do: nil
  defp kind(message), do: if(type(message) == :ordinal, do: "ordinal", else: "plural")

  ## Loading and validating the JSON file

  defp load(path, message, names, config) do
    required = config.locales -- [config.source_locale]
    opts = file_opts(message, message.plural)

    case Message.read(path) do
      {:error, :enoent} ->
        case legacy_translations(message, required, config) do
          legacy when legacy == %{} ->
            created? =
              (config.create_missing or extracting?()) and
                Message.create(
                  path,
                  Message.encode(message.msgid, stub(required, message, config), opts)
                )

            hint =
              if created?,
                do: "created translation file, translate",
                else: "missing translation file for"

            {:error, "#{hint} #{Enum.join(required, ", ")}", :missing}

          legacy when not is_nil(legacy) ->
            if extracting?() do
              translations = Map.merge(stub(required, message, config), legacy)
              Message.create(path, Message.encode(message.msgid, translations, opts))
              {:error, "imported from Gettext", :missing}
            else
              {:error,
               "translations for #{Enum.join(Enum.sort(Map.keys(legacy)), ", ")} are still in " <>
                 "Gettext PO files under #{config.gettext_path}. Move them to JSON with:\n\n" <>
                 "        mix verified_translations.extract\n", :missing}
            end
        end

      {:error, reason} ->
        {:error, reason, :invalid}

      {:ok, data, content} ->
        data =
          if extracting?(),
            do: add_missing_locales(path, message, data, required, config),
            else: data

        case validate(data, message, names, required, config) do
          [] ->
            {:ok, Map.drop(data, ["msgid", "msgctxt", "kind"]), :erlang.md5(content)}

          problems ->
            {:error, Enum.join(problems, "; "), :erlang.md5(content)}
        end
    end
  end

  # translations still in Gettext PO files: ngettext's msgid is the singular form
  defp legacy_translations(message, required, config) do
    msgid =
      case message.source_forms do
        nil -> message.msgid
        forms -> forms["one"] || message.msgid
      end

    kind = if message.plural, do: :plural, else: :singular

    # gettext has no ordinals
    if type(message) == :ordinal,
      do: %{},
      else:
        PO.lookup(config.gettext_path, required, {message.domain, message.context, msgid}, kind)
  end

  defp stub(required, message, _config) do
    Map.new(required, fn locale ->
      if message.plural,
        do: {locale, Map.new(plural_categories(locale, type(message)), &{&1, ""})},
        else: {locale, ""}
    end)
  end

  defp plural_categories(locale, type) do
    case Plural.language(locale) do
      nil -> []
      lang -> Plural.categories(lang, type)
    end
  end

  # extract adds empty keys for locales configured after the file was created
  defp add_missing_locales(path, message, data, required, config) do
    case Enum.reject(required, &Map.has_key?(data, &1)) do
      [] ->
        data

      missing ->
        data = Map.merge(data, stub(missing, message, config))
        translations = Map.drop(data, ["msgid", "msgctxt", "kind"])
        opts = file_opts(message, message.plural)
        File.write!(path, Message.encode(message.msgid, translations, opts))
        data
    end
  end

  defp validate(data, message, names, required, config) do
    known = ["msgid", "msgctxt", "kind" | config.locales]

    identity =
      case Map.fetch(data, "msgid") do
        {:ok, msgid} when msgid == message.msgid -> []
        {:ok, other} -> ["msgid in file is #{inspect(other)}"]
        :error -> ["msgid is missing"]
      end ++
        if(Map.get(data, "msgctxt") != message.context,
          do: ["msgctxt in file is #{inspect(Map.get(data, "msgctxt"))}"],
          else: []
        ) ++
        case Map.get(data, "kind") do
          kind ->
            if kind == kind(message),
              do: [],
              else: ["kind in file is #{inspect(kind)}, expected #{inspect(kind(message))}"]
        end

    values =
      Enum.flat_map(data, fn
        {key, _} when key in ["msgid", "msgctxt", "kind"] ->
          []

        {locale, value} ->
          cond do
            locale not in known ->
              ["unknown locale #{inspect(locale)}"]

            message.plural ->
              validate_forms(locale, value, names, locale != config.source_locale, type(message))

            not is_binary(value) ->
              ["#{locale} must be a string"]

            true ->
              unknown_bindings(locale, value, names)
          end
      end)

    untranslated =
      for locale <- required,
          untranslated?(Map.get(data, locale)),
          do: "#{locale} is not translated"

    identity ++ values ++ untranslated
  end

  defp untranslated?(nil), do: true
  defp untranslated?(""), do: true

  defp untranslated?(forms) when is_map(forms),
    do: Enum.all?(forms, fn {_, text} -> text == "" end)

  defp untranslated?(_), do: false

  defp validate_forms(locale, forms, names, required?, type) do
    case Plural.language(locale) do
      nil ->
        ["no CLDR plural rules for locale #{inspect(locale)}"]

      lang when is_map(forms) ->
        expected = Plural.categories(lang, type)
        given = Map.keys(forms)

        cond do
          untranslated?(forms) and required? ->
            []

          Enum.sort(given) != Enum.sort(expected) ->
            [
              "#{locale} needs plural forms #{inspect(expected)}, got #{inspect(Enum.sort(given))}"
            ]

          true ->
            Enum.flat_map(forms, fn
              {category, text} when is_binary(text) and text != "" ->
                unknown_bindings("#{locale}.#{category}", text, names)

              {category, _} ->
                ["#{locale}.#{category} is not translated"]
            end)
        end

      _ ->
        ["#{locale} must be an object of plural forms"]
    end
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

  ## Code generation

  # Inlines the translations as a literal tuple (one slot per configured
  # locale, plus a last one for unknown locales) indexed by the position
  # put_locale/1 stored. Literals cost almost nothing to compile.
  defp expand(message, translations, config, env) do
    index =
      message.bindings
      |> Enum.with_index()
      |> Map.new(fn {{name, _}, i} -> {Atom.to_string(name), i} end)

    values = {:{}, [], Enum.map(message.bindings, fn {_, expr} -> expr end)}
    backend = config.gettext_backend
    global_locales = Application.compile_env(env, :verified_translations, :locales, ["en"])
    {default, templates} = templates(message, translations, index, config)

    renderer =
      if message.plural,
        do: {:render_plural, [index["count"], type(message)]},
        else: {:render, []}

    cond do
      not message.plural and templates == %{} and message.bindings == [] ->
        default

      config.locales == global_locales ->
        slots =
          List.to_tuple(Enum.map(global_locales, &Map.get(templates, &1, default)) ++ [default])

        {fun, extra} = renderer

        quote do
          VerifiedTranslations.unquote(fun)(
            elem(
              unquote(Macro.escape(slots)),
              VerifiedTranslations.locale_index(unquote(backend))
            ),
            unquote(values),
            unquote_splicing(extra)
          )
        end

      # a module overriding `locales:` cannot use the global slot order
      true ->
        {fun, extra} = renderer

        quote do
          VerifiedTranslations.unquote(fun)(
            Map.get(
              unquote(Macro.escape(templates)),
              VerifiedTranslations.get_locale(unquote(backend)),
              unquote(Macro.escape(default))
            ),
            unquote(values),
            unquote_splicing(extra)
          )
        end
    end
  end

  # {default, %{locale => template}}; plural templates are {lang, %{category => template}}
  defp templates(%{plural: false} = message, translations, index, config) do
    source = Map.get(translations, config.source_locale, "")
    default = template(if(source == "", do: message.msgid, else: source), index)

    templates =
      for {locale, text} <- translations,
          locale != config.source_locale and text != "",
          into: %{},
          do: {locale, template(text, index)}

    {default, templates}
  end

  defp templates(%{plural: true} = message, translations, index, config) do
    source_lang = Plural.language(config.source_locale) || "en"

    source_forms =
      case Map.get(translations, config.source_locale) do
        forms when is_map(forms) and forms != %{} ->
          forms

        _ ->
          message.source_forms ||
            Map.new(Plural.categories(source_lang, type(message)), &{&1, message.msgid})
      end

    default = {source_lang, Map.new(source_forms, fn {c, text} -> {c, template(text, index)} end)}

    templates =
      for {locale, forms} <- translations,
          locale != config.source_locale and is_map(forms) and not untranslated?(forms),
          into: %{} do
        lang = Plural.language(locale)
        {locale, {lang, Map.new(forms, fn {c, text} -> {c, template(text, index)} end)}}
      end

    {default, templates}
  end

  # "Hei %{name}!" -> ["Hei ", 0, "!"] (binding indexes); text without
  # bindings stays a binary
  defp template(text, index) do
    parts =
      @binding_regex
      |> Regex.split(text, include_captures: true, trim: true)
      |> Enum.map(fn part ->
        case Regex.run(~r/^%\{([^{}\s]+)\}$/u, part, capture: :all_but_first) do
          [name] -> Map.fetch!(index, name)
          nil -> part
        end
      end)

    case parts do
      [] -> ""
      [literal] when is_binary(literal) -> literal
      parts -> parts
    end
  end

  ## Modifiers (gettext_sigils compatible)

  # {plural?, [{:keyword, opts} | {:module, module, opts}]}
  defp modifiers(chars, config, env) do
    map = Map.new(config.modifiers)

    Enum.reduce(chars, {false, []}, fn
      ?N, {_plural?, mods} ->
        {true, mods}

      char, {plural?, mods} ->
        key = List.to_atom([char])

        modifier =
          case Map.fetch(map, key) do
            {:ok, opts} when is_list(opts) ->
              {:keyword, opts}

            {:ok, {module, opts}} when is_atom(module) ->
              init_modifier(module, opts, env)

            {:ok, module} when is_atom(module) ->
              init_modifier(module, [], env)

            :error ->
              compile_error!(
                env,
                "unknown ~t modifier #{inspect(<<char>>)}; define it under :modifiers"
              )
          end

        {plural?, mods ++ [modifier]}
    end)
  end

  defp init_modifier(module, opts, env) do
    Code.ensure_compiled!(module)

    if function_exported?(module, :pluralize, 2) do
      compile_error!(
        env,
        "custom pluralization modifiers are not supported, use the N modifier or tn/2"
      )
    end

    case call(module, :init, [opts], {:ok, opts}) do
      {:ok, opts} -> {:module, module, opts}
      {:error, reason} -> compile_error!(env, "#{inspect(module)}.init/1: #{reason(reason)}")
    end
  end

  defp apply_modifiers(modifiers, input, defaults, env) do
    domain_context =
      Enum.reduce(modifiers, defaults, fn
        {:keyword, opts}, {domain, context} ->
          domain =
            case Keyword.get(opts, :domain, domain) do
              :default -> "default"
              domain -> domain
            end

          {domain, Keyword.get(opts, :context, context)}

        {:module, module, opts}, domain_context ->
          case call(module, :domain_context, [input, opts, domain_context], {:ok, domain_context}) do
            {:ok, {:default, context}} -> {"default", context}
            {:ok, domain_context} -> domain_context
            {:error, reason} -> compile_error!(env, "#{inspect(module)}: #{reason(reason)}")
          end
      end)

    input =
      Enum.reduce(modifiers, input, fn
        {:module, module, opts}, input ->
          case call(module, :preprocess, [input, opts], {:ok, input}) do
            {:ok, input} -> input
            {:error, reason} -> compile_error!(env, "#{inspect(module)}: #{reason(reason)}")
          end

        _, input ->
          input
      end)

    {input, domain_context}
  end

  defp postprocess(code, modifiers) do
    case for(
           {:module, module, opts} <- modifiers,
           function_exported?(module, :postprocess, 2),
           do: {module, opts}
         ) do
      [] ->
        code

      post ->
        quote do: VerifiedTranslations.postprocess!(unquote(Macro.escape(post)), unquote(code))
    end
  end

  defp call(module, fun, args, default) do
    if function_exported?(module, fun, length(args)), do: apply(module, fun, args), else: default
  end

  defp reason(%{__exception__: true} = exception), do: Exception.message(exception)
  defp reason(reason), do: to_string(reason)

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

  ## Parsing the sigil (gettext_sigils compatible keys)

  @fallback_key "var"

  @doc """
  Turns `~t` parts into a msgid and keyword bindings, deriving binding keys
  like gettext_sigils: `name`, `@name` -> `name`; `user.name`, `@user.name`
  -> `user_name`; `count(x)` -> `count`; `String.upcase(x)` ->
  `string_upcase`; operators and other expressions -> `var`;
  `key = expr` names the binding explicitly. Keys are downcased.

  `literal` lists placeholders allowed as literal `%{...}` text (tn/2's count).
  """
  def parse_parts(parts, env, literal \\ []) do
    {msgid_parts, bindings} =
      Enum.map_reduce(parts, [], fn
        part, acc when is_binary(part) ->
          text = Macro.unescape_string(part)

          case bindings_in(text) -- literal do
            [] ->
              {text, acc}

            [name | _] ->
              compile_error!(
                env,
                "~t text contains literal %{#{name}}; interpolate a variable instead"
              )
          end

        {:"::", _, [expr, {:binary, _, _}]}, acc ->
          {key, value} = expr |> unwrap_to_string() |> binding(env)
          {"%{#{key}}", acc ++ [{String.to_atom(key), value}]}
      end)

    {IO.iodata_to_binary(msgid_parts), merge_bindings(bindings, env, msgid_parts)}
  end

  # one binding per key; the same key for different expressions is ambiguous
  defp merge_bindings(bindings, env, msgid_parts \\ nil) do
    {unique, ambiguous} =
      Enum.reduce(bindings, {[], []}, fn {key, expr}, {unique, ambiguous} ->
        case List.keyfind(unique, key, 0) do
          nil ->
            {unique ++ [{key, expr}], ambiguous}

          {^key, existing} ->
            if strip_meta(existing) == strip_meta(expr),
              do: {unique, ambiguous},
              else: {unique, Enum.uniq(ambiguous ++ [key])}
        end
      end)

    if ambiguous != [] do
      msgid = if msgid_parts, do: IO.iodata_to_binary(msgid_parts), else: ""

      compile_error!(
        env,
        "ambiguous interpolation keys #{Enum.join(ambiguous, ", ")} in #{inspect(msgid)}; " <>
          "use the \"=\" operator to name them, e.g. ~t\"\#{key = <binding>}\""
      )
    end

    unique
  end

  defp strip_meta(ast),
    do:
      Macro.prewalk(ast, fn
        {form, _, args} -> {form, [], args}
        other -> other
      end)

  defp unwrap_to_string({{:., _, [Kernel, :to_string]}, _, [inner]}), do: inner
  defp unwrap_to_string(expr), do: expr

  defp binding({:=, _, [{key, _, ctx}, value]}, _env) when is_atom(key) and is_atom(ctx),
    do: {key |> Atom.to_string() |> String.downcase(), value}

  defp binding({:=, _, [lhs, _]}, env),
    do: compile_error!(env, "explicit key must be a variable, got: #{Macro.to_string(lhs)}")

  defp binding(expr, _env), do: {expr |> key() |> normalize(), expr}

  defp key({:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx), do: name
  defp key({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: name

  defp key({name, _, args}) when is_atom(name) and is_list(args),
    do: if(Macro.operator?(name, length(args)), do: @fallback_key, else: name)

  defp key({{:., _, [{:assigns, _, _}, field]}, _, []}) when is_atom(field), do: field

  defp key({{:., _, [{:__aliases__, _, modules}, fun]}, _, _}) when is_atom(fun),
    do: [modules, fun]

  defp key({{:., _, [receiver, field]}, _, []}) when is_atom(field), do: [key(receiver), field]
  defp key(_expr), do: @fallback_key

  defp normalize(parts) when is_list(parts), do: Enum.map_join(parts, "_", &normalize/1)
  defp normalize(key) when is_atom(key), do: key |> Atom.to_string() |> normalize()
  defp normalize(key) when is_binary(key), do: String.downcase(key)

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
