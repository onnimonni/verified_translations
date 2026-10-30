defmodule Mix.Tasks.VerifiedTranslations.Migrate.Docs do
  @moduledoc false

  def short_doc, do: "Migrates gettext calls and PO translations to ~t"

  def example, do: "mix verified_translations.migrate --locales en,fi,sv"

  def long_doc do
    """
    #{short_doc()}

    Rewrites `gettext/1,2` (and `dgettext/2,3` with the `"default"` domain)
    in Elixir code, `~H` templates and `.heex` files into `~t`, moves their
    translations from `priv/gettext/*/LC_MESSAGES/default.po` into
    `priv/translations/default/*.json` and removes the migrated messages
    from the PO and POT files.

        gettext("Hello %{name}", name: @user.name)
        # becomes
        ~t"Hello \#{@user.name}"
        # msgid "Hello %{user_name}", placeholders in translations renamed to match

    `ngettext/3,4` becomes `tn/2` with its PO plural forms mapped to CLDR
    categories:

        ngettext("1 file", "%{count} files", length(files))
        # becomes
        tn(length(files), one: "1 file", other: "%{count} files")

    Bindings that are not a variable, assign or field keep their Gettext name:
    `gettext("Hi %{name}", name: String.upcase(u))` becomes
    `~t"Hi \#{name = String.upcase(u)}"`.

    Projects using `gettext_sigils` get `use GettextSigils` replaced and the
    dependency removed. Their `~t` sigils produce the same msgids, so
    `mix verified_translations.extract` imports the existing translations.

    Domains and contexts become `~t` modifiers (`dgettext("errors", "x")` ->
    `~t"x"e`), defined in the `use VerifiedTranslations` that gives the module
    `~t`; plural ones become `tn(n, domain: "errors", ...)`.

    Calls that cannot be expressed are left alone and listed: dynamic msgids,
    and domains or contexts without a `use VerifiedTranslations` to define a
    modifier in.

    Only modules that can use `~t` are rewritten (`use VerifiedTranslations`
    or `use MyAppWeb, ...`). Run with `--dry-run` to review the diff.

    ## Example

    ```sh
    #{example()}
    ```

    ## Options

    * `--locales` - comma separated locales, source locale first. Defaults to
      `en` plus the locale directories in `priv/gettext`.
    * `--gettext` - Gettext priv directory, default `priv/gettext`
    * `--path` - translations directory, default `priv/translations`
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.VerifiedTranslations.Migrate do
    @shortdoc Mix.Tasks.VerifiedTranslations.Migrate.Docs.short_doc()
    @moduledoc Mix.Tasks.VerifiedTranslations.Migrate.Docs.long_doc()

    use Igniter.Mix.Task

    alias Sourceror.Zipper
    alias VerifiedTranslations.{Message, PO}

    @compile {:no_warn_undefined, [Expo.PO, Expo.Message, Expo.Messages]}

    # Gettext's own placeholder syntax
    @placeholder ~r/%\{(\w+)\}/

    # Igniter compiles the project before running the task. Gettext calls are
    # verified once `use VerifiedTranslations` is in place, and migrating is
    # exactly when translations are still missing, so compile like `extract`.
    @impl Mix.Task
    def run(argv) do
      VerifiedTranslations.Compiler.without_verification(fn -> super(argv) end)
    end

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :verified_translations,
        example: Mix.Tasks.VerifiedTranslations.Migrate.Docs.example(),
        schema: [locales: :csv, gettext: :string, path: :string],
        defaults: [locales: [], gettext: "priv/gettext", path: "priv/translations"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options
      web = inspect(Igniter.Libs.Phoenix.web_module(igniter))

      igniter =
        igniter
        |> Igniter.include_glob("lib/**/*.{ex,heex}")
        |> Igniter.include_glob(Path.join(opts[:gettext], "**/*.{po,pot}"))

      {igniter, sigils?} = replace_gettext_sigils(igniter)
      {igniter, conversions, skipped} = rewrite_sources(igniter, web)
      locales = locales(igniter, opts)

      igniter
      |> write_translations(conversions, locales, opts)
      |> prune_po_files(conversions, opts)
      |> report(conversions, skipped)
      |> import_existing_sigils(sigils?)
    end

    ## gettext_sigils

    # `use GettextSigils, backend: B, sigils: [...]` takes the same options
    @use_gettext_sigils ~r/\buse GettextSigils\b/

    defp replace_gettext_sigils(igniter) do
      matcher = GlobEx.compile!(Path.expand("{lib,test}/**/*.{ex,exs}"))

      igniter =
        Igniter.include_glob(igniter, "{lib,test}/**/*.{ex,exs}")

      sources =
        igniter.rewrite
        |> Rewrite.sources()
        |> Enum.filter(&GlobEx.match?(matcher, Path.expand(&1.path)))
        |> Enum.filter(&(Rewrite.Source.get(&1, :content) =~ @use_gettext_sigils))

      igniter =
        Enum.reduce(sources, igniter, fn source, igniter ->
          Igniter.update_file(igniter, source.path, fn source ->
            content = Rewrite.Source.get(source, :content)

            Rewrite.Source.update(
              source,
              :content,
              Regex.replace(@use_gettext_sigils, content, "use VerifiedTranslations")
            )
          end)
        end)

      sigils? = sources != [] or Igniter.Project.Deps.has_dep?(igniter, :gettext_sigils)

      igniter =
        if Igniter.Project.Deps.has_dep?(igniter, :gettext_sigils),
          do: Igniter.Project.Deps.remove_dep(igniter, :gettext_sigils),
          else: igniter

      {igniter, sigils?}
    end

    # existing ~t sigils keep their msgids (same interpolation rules), so
    # their PO translations import as they are once the project compiles
    defp import_existing_sigils(igniter, false), do: igniter

    defp import_existing_sigils(igniter, true) do
      igniter
      |> Igniter.add_task("verified_translations.extract")
      |> Igniter.add_notice("""
      Replaced gettext_sigils with verified_translations. Existing ~t sigils keep
      their msgids; `mix verified_translations.extract` (scheduled now) imports
      their translations from the PO files into priv/translations.
      """)
    end

    ## Rewriting code and templates

    defp rewrite_sources(igniter, web) do
      matcher = GlobEx.compile!(Path.expand("lib/**/*.{ex,heex}"))
      web_path = Igniter.Project.Module.proper_location(igniter, Module.concat([web]))

      sources =
        igniter.rewrite
        |> Rewrite.sources()
        |> Enum.filter(&GlobEx.match?(matcher, Path.expand(&1.path)))
        |> Enum.reject(&(Rewrite.Source.get(&1, :content) =~ "use Gettext.Backend"))
        |> Enum.filter(&sigil_available?(&1.path, Rewrite.Source.get(&1, :content), web))

      contents =
        Map.new(Rewrite.sources(igniter.rewrite), &{&1.path, Rewrite.Source.get(&1, :content)})

      # per file: [{patch, conversion}], skipped, and the file defining its ~t modifiers
      files =
        for source <- sources do
          content = contents[source.path]
          {patches, conversions, skipped} = rewrite(source.path, content)
          provider = modifier_provider(source.path, content, web_path, contents)

          {pairs, unprovided} =
            patches
            |> Enum.zip(conversions)
            |> Enum.split_with(fn {_, conversion} -> conversion.modifier == nil or provider end)

          skipped =
            skipped ++
              for {_, c} <- unprovided,
                  do: {c.location, "no `use VerifiedTranslations` to add a ~t modifier to"}

          %{
            path: source.path,
            content: content,
            pairs: pairs,
            skipped: skipped,
            provider: provider
          }
        end

      needed = for f <- files, {_, c} <- f.pairs, c.modifier, uniq: true, do: c.modifier

      providers =
        for f <- files,
            f.provider,
            Enum.any?(f.pairs, &elem(&1, 1).modifier),
            uniq: true,
            do: f.provider

      letters = allocate_modifiers(needed, Enum.map(providers, &contents[&1]))

      igniter =
        Enum.reduce(files, igniter, fn %{path: path, content: content, pairs: pairs}, igniter ->
          if pairs == [] do
            igniter
          else
            updated =
              content
              |> Sourceror.patch_string(Enum.map(pairs, &elem(&1, 0)))
              |> fill_markers(letters)

            Igniter.update_file(igniter, path, &Rewrite.Source.update(&1, :content, updated))
          end
        end)

      igniter =
        Enum.reduce(providers, igniter, fn path, igniter ->
          Igniter.update_file(igniter, path, fn source ->
            content = Rewrite.Source.get(source, :content)
            Rewrite.Source.update(source, :content, define_modifiers(content, letters))
          end)
        end)

      conversions = for f <- files, {_, c} <- f.pairs, do: c
      skipped = Enum.flat_map(files, & &1.skipped)
      {igniter, conversions, skipped}
    end

    ## ~t modifiers for domains and contexts

    # where the module's ~t modifiers are defined: its own `use VerifiedTranslations`
    # or the web module's
    defp modifier_provider(path, content, web_path, contents) do
      cond do
        content =~ ~r/^\s*use VerifiedTranslations\b/m -> path
        web_path && (contents[web_path] || "") =~ ~r/^\s*use VerifiedTranslations\b/m -> web_path
        true -> nil
      end
    end

    @domain_modifier ~r/\b([a-z]): \[domain: "([^"]+)"\]/
    @context_modifier ~r/\b([a-z]): \[context: "([^"]+)"\]/
    @any_modifier ~r/\b([a-z]): \[/

    # %{{:domain, "errors"} => "e", {:context, "menu"} => "m"}: existing
    # definitions are reused, new ones get a free letter (the name's first if free)
    defp allocate_modifiers(needed, provider_contents) do
      text = Enum.join(provider_contents, "\n")

      existing =
        Map.merge(
          for(
            [_, letter, domain] <- Regex.scan(@domain_modifier, text),
            into: %{},
            do: {{:domain, domain}, letter}
          ),
          for(
            [_, letter, context] <- Regex.scan(@context_modifier, text),
            into: %{},
            do: {{:context, context}, letter}
          )
        )

      used = @any_modifier |> Regex.scan(text) |> Enum.map(&List.last/1) |> MapSet.new()

      wanted =
        needed
        |> Enum.flat_map(fn {domain, context} ->
          [domain && {:domain, domain}, context && {:context, context}]
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {letters, _used} =
        Enum.reduce(wanted, {existing, used}, fn key, {letters, used} ->
          if Map.has_key?(letters, key) do
            {letters, used}
          else
            {_, name} = key

            candidates =
              (String.graphemes(String.downcase(name)) ++ Enum.map(?a..?z, &<<&1>>))
              |> Enum.filter(&(&1 =~ ~r/^[a-z]$/))

            letter = Enum.find(candidates, &(not MapSet.member?(used, &1)))
            {Map.put(letters, key, letter), MapSet.put(used, letter)}
          end
        end)

      letters
    end

    defp fill_markers(content, letters) do
      Regex.replace(~r/\x01([^\x01\x02]*)\x02([^\x01]*)\x01/, content, fn _, domain, context ->
        if(domain == "", do: "", else: letters[{:domain, domain}]) <>
          if context == "", do: "", else: letters[{:context, context}]
      end)
    end

    # adds missing modifier definitions to every `use VerifiedTranslations`
    defp define_modifiers(content, letters) do
      ~r/^[ \t]*use VerifiedTranslations\b/m
      |> Regex.scan(content, return: :index)
      |> Enum.reverse()
      |> Enum.reduce(content, fn [{start, _}], content ->
        {statement, rest_start} = statement(content, start)
        before = binary_part(content, 0, start)
        rest = binary_part(content, rest_start, byte_size(content) - rest_start)

        missing =
          letters
          |> Enum.reject(fn {{_, name}, letter} ->
            statement =~ ~r/\b#{letter}: \[(domain|context): "#{Regex.escape(name)}"\]/
          end)
          |> Enum.sort_by(fn {_, letter} -> letter end)
          |> Enum.map_join(", ", fn {{kind, name}, letter} ->
            "#{letter}: [#{kind}: #{inspect(name)}]"
          end)

        before <> add_to_statement(statement, missing) <> rest
      end)
    end

    defp add_to_statement(statement, ""), do: statement

    defp add_to_statement(statement, definitions) do
      cond do
        statement =~ "modifiers: [" ->
          String.replace(statement, "modifiers: [", "modifiers: [#{definitions}, ", global: false)

        statement =~ "sigils: [" ->
          String.replace(statement, "sigils: [", "sigils: [modifiers: [#{definitions}], ",
            global: false
          )

        true ->
          String.trim_trailing(statement) <> ", sigils: [modifiers: [#{definitions}]]"
      end
    end

    # the `use ...` statement starting at `start`: up to the first newline at
    # bracket depth 0, outside strings
    defp statement(content, start) do
      stop = scan_statement(content, start, 0, false)
      {binary_part(content, start, stop - start), stop}
    end

    defp scan_statement(content, pos, _depth, _string?) when pos >= byte_size(content), do: pos

    defp scan_statement(content, pos, depth, string?) do
      case binary_part(content, pos, 1) do
        "\\" when string? ->
          scan_statement(content, pos + 2, depth, true)

        "\"" ->
          scan_statement(content, pos + 1, depth, not string?)

        c when c in ["[", "("] and not string? ->
          scan_statement(content, pos + 1, depth + 1, false)

        c when c in ["]", ")"] and not string? ->
          scan_statement(content, pos + 1, depth - 1, false)

        "\n" when depth == 0 and not string? ->
          pos

        _ ->
          scan_statement(content, pos + 1, depth, string?)
      end
    end

    # .heex files are compiled into a module using the web module
    defp sigil_available?(path, content, web) do
      Path.extname(path) == ".heex" or content =~ ~r/^\s*use VerifiedTranslations\b/m or
        content =~ "use #{web},"
    end

    @doc false
    # Returns Sourceror patches, conversions and skipped calls for one file.
    def rewrite(path, content) do
      if Path.extname(path) == ".heex" do
        heex_patches(path, content, {1, 1, 0})
      else
        ast = Sourceror.parse_string!(content)
        {code, conversions, skipped} = code_patches(path, ast)

        {heex, heex_conversions, heex_skipped} =
          ast
          |> heex_sigils()
          |> Enum.map(fn {text, start} -> heex_patches(path, text, start) end)
          |> Enum.reduce({[], [], []}, fn {p, c, s}, {ps, cs, ss} ->
            {ps ++ p, cs ++ c, ss ++ s}
          end)

        {code ++ heex, conversions ++ heex_conversions, skipped ++ heex_skipped}
      end
    end

    # gettext calls in Elixir code
    defp code_patches(path, ast) do
      {_, acc} =
        ast
        |> Zipper.zip()
        |> Zipper.traverse({[], [], []}, fn zipper, {patches, conversions, skipped} = acc ->
          node = Zipper.node(zipper)

          with {name, meta, args} when is_atom(name) and is_list(args) <- node,
               true <- gettext_call?(name, length(args)),
               false <- definition_head?(zipper) do
            line = meta[:line]

            case convert(name, args) do
              {:ok, sigil, conversion} ->
                patch = %{range: Sourceror.get_range(node), change: sigil}
                conversion = Map.put(conversion, :location, "#{path}:#{line}")
                {zipper, {[patch | patches], [conversion | conversions], skipped}}

              {:skip, reason} ->
                {zipper, {patches, conversions, [{"#{path}:#{line}", reason} | skipped]}}
            end
          else
            _ -> {zipper, acc}
          end
        end)

      {patches, conversions, skipped} = acc
      {Enum.reverse(patches), Enum.reverse(conversions), Enum.reverse(skipped)}
    end

    @gettext_calls [:gettext, :dgettext, :pgettext, :dpgettext, :ngettext, :dngettext, :pngettext]

    defp gettext_call?(name, arity), do: name in @gettext_calls and arity >= 1

    defp definition_head?(zipper) do
      case Zipper.up(zipper) do
        %Zipper{node: {kind, _, _}} when kind in [:def, :defp, :defmacro, :defmacrop, :when] ->
          true

        _ ->
          false
      end
    end

    # ~H"""...""" contents with the position of their first character
    defp heex_sigils(ast) do
      {_, sigils} =
        Macro.prewalk(ast, [], fn
          {:sigil_H, meta, [{:<<>>, string_meta, [text]}, _]} = node, acc when is_binary(text) ->
            {node, [{text, sigil_content_start(meta, string_meta)} | acc]}

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(sigils)
    end

    # {line, column, indentation} of the template's first character. Heredoc
    # content starts on the next line and has its indentation stripped.
    defp sigil_content_start(meta, string_meta) do
      if meta[:delimiter] in [~s("""), "'''"] do
        indentation = string_meta[:indentation] || 0
        {meta[:line] + 1, indentation + 1, indentation}
      else
        {meta[:line], meta[:column] + 3, 0}
      end
    end

    # `{gettext(...)}` expressions in HEEx; `start` is the {line, column,
    # indentation} of the template's first character in the file
    defp heex_patches(path, text, start) do
      ~r/\{\s*(gettext|dgettext|pgettext|ngettext|dngettext)\(/
      |> Regex.scan(text, return: :index)
      |> Enum.reduce({[], [], []}, fn [{brace, _}, {call_start, _}],
                                      {patches, conversions, skipped} ->
        with {:ok, call_end} <- matching_paren(text, call_start),
             true <- closes_expression?(text, call_end),
             {:ok, {name, _, args}} when is_atom(name) and is_list(args) <-
               Sourceror.parse_string(binary_part(text, call_start, call_end - call_start)) do
          line = position(text, call_start, start)[:line]

          case convert(name, args) do
            {:ok, sigil, conversion} ->
              range = %{
                start: position(text, call_start, start),
                end: position(text, call_end, start)
              }

              conversion = Map.put(conversion, :location, "#{path}:#{line}")
              {[%{range: range, change: sigil} | patches], [conversion | conversions], skipped}

            {:skip, reason} ->
              {patches, conversions, [{"#{path}:#{line}", reason} | skipped]}
          end
        else
          _ ->
            line = position(text, brace, start)[:line]

            {patches, conversions,
             [{"#{path}:#{line}", "could not parse the expression"} | skipped]}
        end
      end)
      |> then(fn {p, c, s} -> {Enum.reverse(p), Enum.reverse(c), Enum.reverse(s)} end)
    end

    # index just after the `)` closing the call starting at `from`
    defp matching_paren(text, from) do
      text
      |> binary_part(from, byte_size(text) - from)
      |> scan_parens(from, 0, false)
    end

    defp scan_parens(<<>>, _pos, _depth, _string?), do: :error

    defp scan_parens(<<"\\", _::utf8, rest::binary>>, pos, depth, true),
      do: scan_parens(rest, pos + 2, depth, true)

    defp scan_parens(<<"\"", rest::binary>>, pos, depth, string?),
      do: scan_parens(rest, pos + 1, depth, not string?)

    defp scan_parens(<<"(", rest::binary>>, pos, depth, false),
      do: scan_parens(rest, pos + 1, depth + 1, false)

    defp scan_parens(<<")", _::binary>>, pos, 1, false), do: {:ok, pos + 1}

    defp scan_parens(<<")", rest::binary>>, pos, depth, false),
      do: scan_parens(rest, pos + 1, depth - 1, false)

    defp scan_parens(<<char::utf8, rest::binary>>, pos, depth, string?),
      do: scan_parens(rest, pos + byte_size(<<char::utf8>>), depth, string?)

    defp closes_expression?(text, index) do
      text
      |> binary_part(index, byte_size(text) - index)
      |> String.trim_leading()
      |> String.starts_with?("}")
    end

    # [line: l, column: c] in the file of byte `index` in a template starting at `start`
    defp position(text, index, {line, column, indentation}) do
      lines = text |> binary_part(0, index) |> String.split("\n")

      case lines do
        [single] ->
          [line: line, column: column + String.length(single)]

        _ ->
          [
            line: line + length(lines) - 1,
            column: indentation + String.length(List.last(lines)) + 1
          ]
      end
    end

    ## Converting one call

    @doc false
    def convert(name, args) do
      args = Enum.map(args, &unwrap/1)

      case {name, args} do
        {:gettext, [msgid | rest]} ->
          to_sigil(msgid, bindings(rest), nil, nil)

        {:dgettext, [domain, msgid | rest]} when is_binary(domain) ->
          to_sigil(msgid, bindings(rest), domain, nil)

        {:pgettext, [context, msgid | rest]} when is_binary(context) ->
          to_sigil(msgid, bindings(rest), nil, context)

        {:dpgettext, [domain, context, msgid | rest]}
        when is_binary(domain) and is_binary(context) ->
          to_sigil(msgid, bindings(rest), domain, context)

        {:ngettext, [one, other, count | rest]} ->
          to_plural(one, other, count, bindings(rest), nil, nil)

        {:dngettext, [domain, one, other, count | rest]} when is_binary(domain) ->
          to_plural(one, other, count, bindings(rest), domain, nil)

        {:pngettext, [context, one, other, count | rest]} when is_binary(context) ->
          to_plural(one, other, count, bindings(rest), nil, context)

        {:dpngettext, [domain, context, one, other, count | rest]}
        when is_binary(domain) and is_binary(context) ->
          to_plural(one, other, count, bindings(rest), domain, context)

        _ ->
          {:skip, "dynamic arguments"}
      end
    end

    defp bindings([]), do: []
    defp bindings([bindings]) when is_list(bindings), do: bindings
    defp bindings(_), do: :dynamic

    defp unwrap({:__block__, _, [literal]}) when is_binary(literal) or is_list(literal),
      do: literal

    defp unwrap(other), do: other

    defp domain_of(nil), do: "default"
    defp domain_of(domain), do: domain

    # ~t takes its domain and context from modifiers: dgettext("errors", "x")
    # becomes ~t"x" + a placeholder replaced by the allocated letter(s) later
    defp to_sigil(msgid, bindings, domain, context) when is_binary(msgid) and is_list(bindings) do
      domain = if domain == "default", do: nil, else: domain

      with {:ok, text, renames} <- interpolate(msgid, bindings, []) do
        modifier = if domain || context, do: {domain, context}

        {:ok, ~s|~t"#{text}"| <> marker(modifier),
         %{
           kind: :singular,
           msgid: msgid,
           new_msgid: rename(msgid, renames),
           renames: renames,
           domain: domain_of(domain),
           context: context,
           modifier: modifier
         }}
      end
    end

    defp to_sigil(_msgid, _bindings, _domain, _context), do: {:skip, "dynamic arguments"}

    @marker_open <<1>>
    defp marker(nil), do: ""

    defp marker({domain, context}),
      do: @marker_open <> "#{domain}" <> <<2>> <> "#{context}" <> @marker_open

    # ngettext(one, other, n) -> tn(n, one: ..., other: ...); %{count} stays literal
    defp to_plural(one, other, count, bindings, domain, context)
         when is_binary(one) and is_binary(other) and is_list(bindings) do
      domain = if domain == "default", do: nil, else: domain

      with {:ok, one_text, renames} <- interpolate(one, bindings, ["count"]),
           {:ok, other_text, other_renames} <- interpolate(other, bindings, ["count"]) do
        renames = Map.merge(renames, other_renames)
        forms = %{"one" => rename(one, renames), "other" => rename(other, renames)}

        options =
          [domain && ~s|domain: #{inspect(domain)}|, context && ~s|context: #{inspect(context)}|]
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join(&(&1 <> ", "))

        code =
          ~s|tn(#{Sourceror.to_string(count)}, #{options}one: "#{one_text}", other: "#{other_text}")|

        {:ok, code,
         %{
           kind: :plural,
           msgid: one,
           new_msgid: forms["other"],
           forms: forms,
           renames: renames,
           domain: domain_of(domain),
           context: context,
           modifier: nil
         }}
      end
    end

    defp to_plural(_one, _other, _count, _bindings, _domain, _context),
      do: {:skip, "dynamic arguments"}

    # Turns a gettext msgid into ~t text. Variables, assigns and fields get the
    # name ~t derives (%{name} with name: @user.name -> #{@user.name}, renamed
    # to %{user_name}); other expressions keep their key explicitly
    # (#{name = String.upcase(x)}) so the msgid stays the same.
    defp interpolate(msgid, bindings, literal) do
      bindings =
        Map.new(bindings, fn {key, expr} -> {key |> unwrap_key() |> Atom.to_string(), expr} end)

      keys =
        @placeholder
        |> Regex.scan(msgid, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()
        |> Kernel.--(literal)

      with {:ok, names} <- binding_names(keys, bindings) do
        text =
          @placeholder
          |> Regex.split(msgid, include_captures: true, trim: true)
          |> Enum.map_join(fn part ->
            case Regex.run(~r/^%\{(\w+)\}$/, part, capture: :all_but_first) do
              [key] ->
                if key in literal,
                  do: part,
                  else: interpolation(key, Map.fetch!(names, key), bindings[key])

              nil ->
                escape(part)
            end
          end)

        renames = for {key, {:derived, name}} <- names, name != key, into: %{}, do: {key, name}
        {:ok, text, renames}
      end
    end

    defp interpolation(_key, {:derived, _name}, expr), do: "\#{#{Sourceror.to_string(expr)}}"
    defp interpolation(key, :explicit, expr), do: "\#{#{key} = #{Sourceror.to_string(expr)}}"

    defp unwrap_key({:__block__, _, [key]}) when is_atom(key), do: key
    defp unwrap_key(key) when is_atom(key), do: key

    # key => {:derived, name} | :explicit
    defp binding_names(keys, bindings) do
      Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, names} ->
        case Map.fetch(bindings, key) do
          {:ok, expr} ->
            name = derived_name(expr)

            taken? =
              Enum.any?(names, fn {other, kind} -> kind == {:derived, name} and other != key end)

            kind =
              if name && not taken?,
                do: {:derived, name},
                else: :explicit

            {:cont, {:ok, Map.put(names, key, kind)}}

          :error ->
            {:halt, {:skip, "binding %{#{key}} is not given"}}
        end
      end)
    end

    # the name ~t derives, for variables, assigns and field access only
    defp derived_name(expr) do
      ast = expr |> Sourceror.to_string() |> Code.string_to_quoted!()

      if simple?(ast) do
        # "%{user_name}" -> "user_name"
        ast |> sigil_msgid() |> String.slice(2..-2//1)
      end
    end

    defp simple?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
    defp simple?({:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx), do: true

    defp simple?({{:., _, [left, field]}, meta, []}) when is_atom(field),
      do: meta[:no_parens] == true and simple?(left)

    defp simple?(_), do: false

    defp sigil_msgid(ast) do
      parts = [{:"::", [], [{{:., [], [Kernel, :to_string]}, [], [ast]}, {:binary, [], nil}]}]
      {msgid, _} = VerifiedTranslations.Compiler.parse_parts(parts, __ENV__)
      msgid
    end

    defp rename(text, renames) do
      Regex.replace(@placeholder, text, fn whole, key ->
        case Map.fetch(renames, key) do
          {:ok, name} -> "%{#{name}}"
          :error -> whole
        end
      end)
    end

    defp escape(text) do
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\#{", "\\\#{")
      |> String.replace("\n", "\\n")
    end

    ## Translations

    defp locales(igniter, opts) do
      case opts[:locales] do
        [_ | _] = locales ->
          locales

        _ ->
          found =
            for {path, _} <- po_files(igniter, opts),
                [_, "LC_MESSAGES", locale | _] = path |> Path.split() |> Enum.reverse(),
                uniq: true,
                do: locale

          ["en" | Enum.sort(found -- ["en"])]
      end
    end

    # {path, %Expo.Messages{}} of every default domain PO file
    defp po_files(igniter, opts) do
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.filter(
        &(Path.extname(&1.path) == ".po" and
            String.starts_with?(Path.expand(&1.path), Path.expand(opts[:gettext])))
      )
      |> Enum.map(&{&1.path, Expo.PO.parse_string!(Rewrite.Source.get(&1, :content))})
    end

    defp write_translations(igniter, [], _locales, _opts), do: igniter

    defp write_translations(igniter, conversions, [source_locale | _] = locales, opts) do
      # {locale, domain, context, msgid} => PO entry
      catalog =
        for {path, messages} <- po_files(igniter, opts),
            [domain_file, "LC_MESSAGES", locale | _] = path |> Path.split() |> Enum.reverse(),
            locale in locales and locale != source_locale,
            {{context, msgid}, entry} <-
              PO.parse(Expo.PO.compose(messages) |> IO.iodata_to_binary(), locale),
            into: %{},
            do: {{locale, Path.rootname(domain_file), context, msgid}, entry}

      conversions
      |> Enum.uniq_by(&{&1.kind, &1.domain, &1.context, &1.new_msgid, &1[:forms]})
      |> Enum.reduce(igniter, fn conversion, igniter ->
        %{kind: kind, msgid: msgid, new_msgid: new_msgid, renames: renames} = conversion
        plural = if kind == :plural, do: Message.sorted_forms(conversion.forms)
        %{domain: domain, context: context} = conversion
        encode_opts = [plural: kind == :plural, context: context]

        translations =
          for locale <- locales -- [source_locale], into: %{} do
            imported =
              PO.convert(Map.get(catalog, {locale, domain, context, msgid}), kind, locale)

            {locale, rename_translation(imported, renames, kind, locale)}
          end

        path = Message.path(opts[:path], domain, new_msgid, plural: plural, context: context)

        Igniter.create_or_update_file(
          igniter,
          path,
          Message.encode(new_msgid, translations, encode_opts),
          fn source ->
            content = Rewrite.Source.get(source, :content)

            case JSON.decode(content) do
              {:ok, %{"msgid" => ^new_msgid} = existing} ->
                # keep translations already there, fill the empty ones
                current = Map.drop(existing, ["msgid", "msgctxt", "kind", "origin"])

                merged =
                  Map.merge(translations, current, fn _locale, imported, current ->
                    if current in ["", nil] or current == %{}, do: imported, else: current
                  end)

                Rewrite.Source.update(
                  source,
                  :content,
                  Message.encode(new_msgid, merged, encode_opts)
                )

              _ ->
                source
            end
          end
        )
      end)
    end

    defp rename_translation(nil, _renames, :singular, _locale), do: ""

    defp rename_translation(nil, _renames, :plural, locale) do
      case VerifiedTranslations.Plural.language(locale) do
        nil -> %{}
        lang -> Map.new(VerifiedTranslations.Plural.categories(lang), &{&1, ""})
      end
    end

    defp rename_translation(forms, renames, :plural, _locale),
      do: Map.new(forms, fn {category, text} -> {category, rename(text, renames)} end)

    defp rename_translation(text, renames, :singular, _locale), do: rename(text, renames)

    # drop migrated messages from PO/POT files unless a gettext call still uses them
    defp prune_po_files(igniter, [], _opts), do: igniter

    defp prune_po_files(igniter, conversions, opts) do
      still_used =
        igniter.rewrite
        |> Rewrite.sources()
        |> Enum.filter(&String.starts_with?(&1.path, "lib/"))
        |> Enum.map_join("\n", &Rewrite.Source.get(&1, :content))

      migrated =
        conversions
        |> Enum.reject(&gettext_reference?(still_used, &1.msgid))
        |> MapSet.new(&{&1.domain, &1.context, &1.msgid})

      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.filter(
        &(Path.extname(&1.path) in [".po", ".pot"] and
            String.starts_with?(Path.expand(&1.path), Path.expand(opts[:gettext])))
      )
      |> Enum.reduce(igniter, fn source, igniter ->
        po = Expo.PO.parse_string!(Rewrite.Source.get(source, :content))
        domain = source.path |> Path.basename() |> Path.rootname()

        kept =
          Enum.reject(po.messages, fn message ->
            context = if message.msgctxt, do: IO.iodata_to_binary(message.msgctxt)
            {domain, context, IO.iodata_to_binary(message.msgid)} in migrated
          end)

        if length(kept) == length(po.messages) do
          igniter
        else
          content = %{po | messages: kept} |> Expo.PO.compose() |> IO.iodata_to_binary()
          Igniter.update_file(igniter, source.path, &Rewrite.Source.update(&1, :content, content))
        end
      end)
    end

    # a remaining gettext family call with this msgid literal
    defp gettext_reference?(code, msgid) do
      literal = Regex.escape(inspect(msgid))
      code =~ ~r/[dpn]*gettext\(\s*(?:"[^"]*",\s*)?#{literal}/
    end

    defp report(igniter, conversions, skipped) do
      igniter =
        Igniter.add_notice(
          igniter,
          "verified_translations.migrate: converted #{length(conversions)} gettext call(s) " <>
            "to ~t (#{conversions |> Enum.uniq_by(& &1.new_msgid) |> length()} message(s))."
        )

      case skipped do
        [] ->
          igniter

        _ ->
          lines =
            Enum.map_join(skipped, "\n", fn {location, reason} -> "  #{location}: #{reason}" end)

          Igniter.add_notice(igniter, """
          verified_translations.migrate left #{length(skipped)} call(s) on gettext:
          #{lines}
          """)
      end
    end
  end
else
  defmodule Mix.Tasks.VerifiedTranslations.Migrate do
    @shortdoc "#{Mix.Tasks.VerifiedTranslations.Migrate.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc Mix.Tasks.VerifiedTranslations.Migrate.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("The task 'verified_translations.migrate' requires igniter.")
      exit({:shutdown, 1})
    end
  end
end
