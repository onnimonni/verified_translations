defmodule Mix.Tasks.VerifiedTranslations.Install.Docs do
  @moduledoc false

  def short_doc, do: "Installs verified_translations into a Phoenix project"

  def example, do: "mix igniter.install verified_translations --locales en,fi,sv"

  def long_doc do
    """
    #{short_doc()}

    * configures `:verified_translations` locales in `config/config.exs`
    * adds `use VerifiedTranslations` next to every `use Gettext, backend: ...` in `lib/`
    * runs `mix verified_translations.migrate`: rewrites `gettext` calls (with
      bindings, in code, `~H` and `.heex`) to `~t`, moves their translations
      from `priv/gettext` into `priv/translations` and prunes the PO files
    * adds `priv/translations` to Phoenix live reload patterns
    * enables the `VerifiedTranslations.Credo.PreferSigil` Credo check (adds Credo if missing)

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
        example: Mix.Tasks.VerifiedTranslations.Install.Docs.example(),
        composes: ["verified_translations.migrate"],
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
      |> Igniter.compose_task("verified_translations.migrate", [
        "--locales",
        Enum.join(locales, ",")
      ])
      |> add_live_reload_pattern()
      |> enable_credo_check()
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

    # Credo check flagging gettext calls that `migrate` can rewrite to ~t
    @credo_check "{VerifiedTranslations.Credo.PreferSigil, []}"

    defp enable_credo_check(igniter) do
      igniter =
        if Igniter.Project.Deps.has_dep?(igniter, :credo),
          do: igniter,
          else:
            Igniter.Project.Deps.add_dep(
              igniter,
              {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
            )

      if Igniter.exists?(igniter, ".credo.exs") do
        Igniter.update_file(igniter, ".credo.exs", fn source ->
          content = Rewrite.Source.get(source, :content)

          cond do
            content =~ "VerifiedTranslations.Credo.PreferSigil" ->
              source

            content =~ ~r/(?:enabled|extra):\s*\[/ ->
              updated =
                Regex.replace(~r/((?:enabled|extra):\s*\[)/, content, "\\1\n#{@credo_check},",
                  global: false
                )

              Rewrite.Source.update(source, :content, updated)

            true ->
              source
          end
        end)
        |> then(fn igniter ->
          content =
            igniter.rewrite |> Rewrite.source!(".credo.exs") |> Rewrite.Source.get(:content)

          if content =~ "VerifiedTranslations.Credo.PreferSigil",
            do: igniter,
            else:
              Igniter.add_notice(
                igniter,
                "Add #{@credo_check} to the checks in .credo.exs to flag remaining gettext calls."
              )
        end)
      else
        Igniter.create_new_file(igniter, ".credo.exs", """
        # Credo merges `extra` checks into its default configuration.
        %{
          configs: [
            %{
              name: "default",
              checks: %{
                extra: [
                  #{@credo_check}
                ]
              }
            }
          ]
        }
        """)
      end
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
