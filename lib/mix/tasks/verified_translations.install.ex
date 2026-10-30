defmodule Mix.Tasks.VerifiedTranslations.Install.Docs do
  @moduledoc false

  def short_doc, do: "Installs verified_translations into a Phoenix project"

  def example, do: "mix igniter.install verified_translations --locales en,fi,sv"

  def long_doc do
    """
    #{short_doc()}

    * configures `:verified_translations` locales in `config/config.exs`
    * adds `use VerifiedTranslations` next to every `use Gettext, backend: ...` in `lib/`
    * rewrites `gettext("literal")` calls to `~t"literal"`
    * imports existing translations from `priv/gettext` (when present)
    * adds `priv/translations` to Phoenix live reload patterns

    ## Example

    ```sh
    #{example()}
    ```

    ## Options

    * `--locales` - comma separated locales, source locale first. Defaults to
      the locale directories in `priv/gettext`, or `en`.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.VerifiedTranslations.Install do
    @shortdoc Mix.Tasks.VerifiedTranslations.Install.Docs.short_doc()
    @moduledoc Mix.Tasks.VerifiedTranslations.Install.Docs.long_doc()

    use Igniter.Mix.Task

    alias Igniter.Code.Common
    alias Sourceror.Zipper

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :verified_translations,
        example: Mix.Tasks.VerifiedTranslations.Install.Docs.example(),
        schema: [locales: :csv],
        defaults: [locales: []]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      locales = locales(igniter.args.options[:locales])
      [source_locale | _] = locales
      web = inspect(Igniter.Libs.Phoenix.web_module(igniter))

      igniter
      |> Igniter.Project.Config.configure(
        "config.exs",
        :verified_translations,
        [:locales],
        locales
      )
      |> Igniter.Project.Config.configure(
        "config.exs",
        :verified_translations,
        [:source_locale],
        source_locale
      )
      |> Igniter.Project.Config.configure(
        "config.exs",
        :verified_translations,
        [:gettext_backend],
        {:code, Sourceror.parse_string!("#{web}.Gettext")}
      )
      |> update_sources("lib/**/*.ex", &add_use/1)
      |> Igniter.update_glob("lib/**/*.ex", &code_gettext_to_sigil(&1, web))
      |> update_sources("lib/**/*.{ex,heex}", &heex_gettext_to_sigil(&1, web))
      |> add_live_reload_pattern()
      |> maybe_import_po()
      |> Igniter.add_notice("""
      verified_translations installed.

      Use ~t"Hello \#{name}" in templates and code. Every message lives in
      priv/translations/<domain>/<slug>-<hash>.json; compiling a new ~t
      creates the file and fails until all of #{Enum.join(locales -- [source_locale], ", ")} are translated:

          mix verified_translations.extract

      Set the locale with `plug VerifiedTranslations.Plug` in your browser
      pipeline and `on_mount: VerifiedTranslations.LiveView` in live sessions.
      VerifiedTranslations.put_locale/1 also sets the Gettext locale.
      """)
    end

    defp locales([_ | _] = locales), do: locales

    defp locales([]) do
      case File.ls("priv/gettext") do
        {:ok, entries} ->
          found = Enum.filter(entries, &File.dir?(Path.join("priv/gettext", &1)))
          if found == [], do: ["en"], else: ["en" | Enum.sort(found -- ["en"])]

        {:error, _} ->
          ["en"]
      end
    end

    # Applies `fun` to the content of every source matching `glob`, leaving the
    # Gettext backend (and its docs) alone.
    defp update_sources(igniter, glob, fun) do
      igniter = Igniter.include_glob(igniter, glob)
      matcher = GlobEx.compile!(Path.expand(glob))

      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.filter(&GlobEx.match?(matcher, Path.expand(&1.path)))
      |> Enum.reduce(igniter, fn source, igniter ->
        content = Rewrite.Source.get(source, :content)
        updated = if content =~ "use Gettext.Backend", do: content, else: fun.(content)

        if updated == content,
          do: igniter,
          else:
            Igniter.update_file(
              igniter,
              source.path,
              &Rewrite.Source.update(&1, :content, updated)
            )
      end)
    end

    # `use VerifiedTranslations` after every `use Gettext, backend: ...` lacking it
    @use_gettext ~r/^([ \t]*)use Gettext, backend: [^\n]*\n(?![ \t]*use VerifiedTranslations\b)/m

    defp add_use(content),
      do: Regex.replace(@use_gettext, content, "\\0\\1use VerifiedTranslations\n")

    # only convert where ~t is available: directly or through the web module
    defp sigil_available?(content, web) do
      content =~ ~r/^\s*use VerifiedTranslations\b/m or content =~ "use #{web},"
    end

    # gettext("Literal") calls in Elixir code, excluding function heads
    defp code_gettext_to_sigil(zipper, web) do
      if sigil_available?(zipper |> Zipper.node() |> Sourceror.to_string(), web) do
        Common.update_all_matches(zipper, &plain_gettext_call?/1, fn zipper ->
          {:code, Sourceror.parse_string!(~s|~t"#{literal(zipper)}"|)}
        end)
      else
        {:ok, zipper}
      end
    end

    defp plain_gettext_call?(zipper) do
      Igniter.Code.Function.function_call?(zipper, :gettext, 1) and
        not definition_head?(zipper) and
        case literal(zipper) do
          text when is_binary(text) -> not String.contains?(text, ["\"", "\#{", "%{", "\\"])
          _ -> false
        end
    end

    defp definition_head?(zipper) do
      case Zipper.up(zipper) do
        %Zipper{node: {kind, _, _}} when kind in [:def, :defp, :defmacro, :defmacrop, :when] ->
          true

        _ ->
          false
      end
    end

    defp literal(zipper) do
      with {:ok, arg} <- Igniter.Code.Function.move_to_nth_argument(zipper, 0),
           {:__block__, _, [text]} when is_binary(text) <- Zipper.node(arg) do
        text
      else
        _ -> nil
      end
    end

    # HEEx is a string, not Elixir AST: only exact `{gettext("Literal")}` expressions
    @heex_gettext ~r/\{gettext\("([^"\\#%]*)"\)\}/

    defp heex_gettext_to_sigil(content, web) do
      if sigil_available?(content, web) or not String.contains?(content, "defmodule"),
        do: Regex.replace(@heex_gettext, content, ~S|{~t"\1"}|),
        else: content
    end

    defp add_live_reload_pattern(igniter) do
      Enum.reduce(["config/runtime.exs", "config/dev.exs"], igniter, fn file, igniter ->
        if Igniter.exists?(igniter, file),
          do: Igniter.update_elixir_file(igniter, file, &insert_pattern/1),
          else: igniter
      end)
    end

    @pattern ~S|~r"priv/translations/.*\.json$"|

    defp insert_pattern(zipper) do
      cond do
        Common.move_to(zipper, &pattern?(&1, "priv/translations")) != :error ->
          {:ok, zipper}

        match?({:ok, _}, Common.move_to(zipper, &pattern?(&1, "priv/gettext"))) ->
          {:ok, gettext} = Common.move_to(zipper, &pattern?(&1, "priv/gettext"))
          {:ok, Zipper.insert_right(gettext, Sourceror.parse_string!(@pattern))}

        match?({:ok, _}, Common.move_to(zipper, &patterns_list?/1)) ->
          {:ok, list} = Common.move_to(zipper, &patterns_list?/1)
          Igniter.Code.List.append_to_list(list, Sourceror.parse_string!(@pattern))

        true ->
          {:ok, zipper}
      end
    end

    defp pattern?(zipper, prefix) do
      case Zipper.node(zipper) do
        {:sigil_r, _, [{:<<>>, _, [text]}, _]} when is_binary(text) ->
          String.starts_with?(text, prefix)

        _ ->
          false
      end
    end

    # the live_reload `patterns: [~r"...", ...]` list
    defp patterns_list?(zipper) do
      Igniter.Code.List.list?(zipper) and list_of_regexes?(Zipper.node(zipper))
    end

    defp list_of_regexes?({:__block__, _, [items]}) when is_list(items),
      do: list_of_regexes?(items)

    defp list_of_regexes?([_ | _] = items),
      do: Enum.all?(items, &match?({:sigil_r, _, _}, &1))

    defp list_of_regexes?(_), do: false

    defp maybe_import_po(igniter) do
      if File.dir?("priv/gettext") and Code.ensure_loaded?(Expo.PO) do
        Igniter.add_task(igniter, "verified_translations.import_po")
      else
        igniter
      end
    end
  end
else
  defmodule Mix.Tasks.VerifiedTranslations.Install do
    @shortdoc "#{Mix.Tasks.VerifiedTranslations.Install.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc Mix.Tasks.VerifiedTranslations.Install.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'verified_translations.install' requires igniter. Please install igniter and try again.

      Or add `use VerifiedTranslations` to the `html_helpers` of your web module manually.
      """)

      exit({:shutdown, 1})
    end
  end
end
