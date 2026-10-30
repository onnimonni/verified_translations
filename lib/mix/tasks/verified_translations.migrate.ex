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

    Calls that cannot be expressed with `~t` are left alone and listed:
    plurals (`ngettext`), contexts (`pgettext`), other domains and bindings
    that are not a variable, assign or field access.

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
    alias VerifiedTranslations.Message

    @compile {:no_warn_undefined, [Expo.PO, Expo.Message, Expo.Messages]}

    # Gettext's own placeholder syntax
    @placeholder ~r/%\{(\w+)\}/

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

      {igniter, conversions, skipped} = rewrite_sources(igniter, web)
      locales = locales(igniter, opts)

      igniter
      |> write_translations(conversions, locales, opts)
      |> prune_po_files(conversions, opts)
      |> report(conversions, skipped)
    end

    ## Rewriting code and templates

    defp rewrite_sources(igniter, web) do
      matcher = GlobEx.compile!(Path.expand("lib/**/*.{ex,heex}"))

      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.filter(&GlobEx.match?(matcher, Path.expand(&1.path)))
      |> Enum.reduce({igniter, [], []}, fn source, {igniter, conversions, skipped} ->
        content = Rewrite.Source.get(source, :content)

        if content =~ "use Gettext.Backend" or not sigil_available?(source.path, content, web) do
          {igniter, conversions, skipped}
        else
          {patches, new_conversions, new_skipped} = rewrite(source.path, content)

          igniter =
            if patches == [],
              do: igniter,
              else:
                Igniter.update_file(igniter, source.path, fn source ->
                  Rewrite.Source.update(
                    source,
                    :content,
                    Sourceror.patch_string(content, patches)
                  )
                end)

          {igniter, conversions ++ new_conversions, skipped ++ new_skipped}
        end
      end)
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
        {:gettext, [msgid]} ->
          to_sigil(msgid, [])

        {:gettext, [msgid, bindings]} ->
          to_sigil(msgid, bindings)

        {:dgettext, ["default", msgid]} ->
          to_sigil(msgid, [])

        {:dgettext, ["default", msgid, bindings]} ->
          to_sigil(msgid, bindings)

        {:dgettext, [domain | _]} when is_binary(domain) ->
          {:skip, "domain #{inspect(domain)}"}

        {plural, _} when plural in [:ngettext, :dngettext, :pngettext] ->
          {:skip, "plural (#{plural})"}

        {context, _} when context in [:pgettext, :dpgettext] ->
          {:skip, "context (#{context})"}

        _ ->
          {:skip, "dynamic arguments"}
      end
    end

    defp unwrap({:__block__, _, [literal]}) when is_binary(literal) or is_list(literal),
      do: literal

    defp unwrap(other), do: other

    defp to_sigil(msgid, bindings) when is_binary(msgid) and is_list(bindings) do
      bindings =
        Map.new(bindings, fn {key, expr} -> {key |> unwrap_key() |> Atom.to_string(), expr} end)

      keys =
        @placeholder
        |> Regex.scan(msgid, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      with {:ok, renames} <- binding_names(keys, bindings) do
        parts = Regex.split(@placeholder, msgid, include_captures: true, trim: true)

        sigil =
          Enum.map_join(parts, fn part ->
            case Regex.run(~r/^%\{(\w+)\}$/, part, capture: :all_but_first) do
              [key] -> "\#{#{bindings |> Map.fetch!(key) |> Sourceror.to_string()}}"
              nil -> escape(part)
            end
          end)

        new_msgid = rename(msgid, renames)
        {:ok, ~s|~t"#{sigil}"|, %{msgid: msgid, new_msgid: new_msgid, renames: renames}}
      end
    end

    defp to_sigil(_msgid, _bindings), do: {:skip, "dynamic arguments"}

    defp unwrap_key({:__block__, _, [key]}) when is_atom(key), do: key
    defp unwrap_key(key) when is_atom(key), do: key

    # %{key} -> name ~t derives from the bound expression
    defp binding_names(keys, bindings) do
      Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, renames} ->
        with {:ok, expr} <- Map.fetch(bindings, key),
             {:ok, path} <- binding_path(expr) do
          name = Enum.join(path, "_")

          clash? =
            Enum.any?(renames, fn {other, other_name} ->
              other_name == name and
                Sourceror.to_string(bindings[other]) != Sourceror.to_string(expr)
            end)

          if clash?,
            do: {:halt, {:skip, "bindings would share the name %{#{name}}"}},
            else: {:cont, {:ok, Map.put(renames, key, name)}}
        else
          :error -> {:halt, {:skip, "binding %{#{key}} is not given"}}
          :complex -> {:halt, {:skip, "binding %{#{key}} is not a variable, assign or field"}}
        end
      end)
    end

    defp binding_path({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {:ok, [name]}

    defp binding_path({:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx),
      do: {:ok, [name]}

    defp binding_path({{:., _, [left, field]}, meta, []}) when is_atom(field) do
      with true <- Keyword.get(meta, :no_parens, false),
           {:ok, path} <- binding_path(left) do
        {:ok, path ++ [field]}
      else
        _ -> :complex
      end
    end

    defp binding_path(_), do: :complex

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
        &(Path.basename(&1.path) == "default.po" and
            String.starts_with?(Path.expand(&1.path), Path.expand(opts[:gettext])))
      )
      |> Enum.map(&{&1.path, Expo.PO.parse_string!(Rewrite.Source.get(&1, :content))})
    end

    defp write_translations(igniter, [], _locales, _opts), do: igniter

    defp write_translations(igniter, conversions, [source_locale | _] = locales, opts) do
      catalog =
        for {path, messages} <- po_files(igniter, opts),
            [_, "LC_MESSAGES", locale | _] = path |> Path.split() |> Enum.reverse(),
            locale in locales and locale != source_locale,
            %{__struct__: Expo.Message.Singular, msgctxt: nil, obsolete: false} = message <-
              messages.messages,
            not Expo.Message.has_flag?(message, "fuzzy"),
            (msgstr = IO.iodata_to_binary(message.msgstr)) != "",
            into: %{},
            do: {{locale, IO.iodata_to_binary(message.msgid)}, msgstr}

      conversions
      |> Enum.uniq_by(& &1.new_msgid)
      |> Enum.reduce(igniter, fn %{msgid: msgid, new_msgid: new_msgid, renames: renames},
                                 igniter ->
        translations =
          for locale <- locales -- [source_locale], into: %{} do
            {locale, catalog |> Map.get({locale, msgid}, "") |> rename(renames)}
          end

        path = Message.path(opts[:path], "default", new_msgid)

        Igniter.create_or_update_file(
          igniter,
          path,
          Message.encode(new_msgid, translations),
          fn source ->
            content = Rewrite.Source.get(source, :content)

            case JSON.decode(content) do
              {:ok, %{"msgid" => ^new_msgid} = existing} ->
                # keep translations already there, fill the empty ones
                merged =
                  Map.merge(translations, Map.delete(existing, "msgid"), fn _locale,
                                                                            imported,
                                                                            current ->
                    if current == "", do: imported, else: current
                  end)

                Rewrite.Source.update(source, :content, Message.encode(new_msgid, merged))

              _ ->
                source
            end
          end
        )
      end)
    end

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
        |> Enum.map(& &1.msgid)
        |> Enum.uniq()
        |> Enum.reject(&gettext_reference?(still_used, &1))
        |> MapSet.new()

      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.filter(
        &(Path.basename(&1.path) in ["default.po", "default.pot"] and
            String.starts_with?(Path.expand(&1.path), Path.expand(opts[:gettext])))
      )
      |> Enum.reduce(igniter, fn source, igniter ->
        po = Expo.PO.parse_string!(Rewrite.Source.get(source, :content))

        kept =
          Enum.reject(po.messages, fn message ->
            match?(%{__struct__: Expo.Message.Singular, msgctxt: nil}, message) and
              IO.iodata_to_binary(message.msgid) in migrated
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
