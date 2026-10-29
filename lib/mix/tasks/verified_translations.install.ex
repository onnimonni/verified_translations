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
      |> add_use()
      |> gettext_to_sigil()
      |> add_live_reload_pattern()
      |> maybe_import_po()
      |> Igniter.add_notice("""
      verified_translations installed.

      Use ~t"Hello \#{name}" in templates and code. Every message lives in
      priv/translations/<domain>/<slug>-<hash>.json; compiling a new ~t
      creates the file and fails until all of #{Enum.join(locales -- [source_locale], ", ")} are translated.

      Set the locale per process (plug / LiveView on_mount):

          VerifiedTranslations.put_locale("fi")

      Remove unused translation files with:

          mix verified_translations.unused --delete
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

    # `use VerifiedTranslations` after every `use Gettext, backend: ...`
    @use_gettext ~r/^([ \t]*)use Gettext, backend: [\w.]+[ \t]*\n/m

    defp add_use(igniter) do
      update_matching_files(igniter, "lib/**/*.ex", fn content ->
        if content =~ ~r/^\s*use VerifiedTranslations\b/m,
          do: content,
          else: Regex.replace(@use_gettext, content, "\\0\\1use VerifiedTranslations\n")
      end)
    end

    defp update_matching_files(igniter, glob, fun) do
      glob
      |> Path.wildcard()
      # leave the Gettext backend (and its docs) alone
      |> Enum.reject(&(File.read!(&1) =~ "use Gettext.Backend"))
      |> Enum.filter(&(fun.(File.read!(&1)) != File.read!(&1)))
      |> Enum.reduce(igniter, fn path, igniter ->
        Igniter.update_file(igniter, path, fn source ->
          Rewrite.Source.update(source, :content, fun.(Rewrite.Source.get(source, :content)))
        end)
      end)
    end

    # gettext("Literal text") -> ~t"Literal text", also inside ~H and .heex,
    # which are strings rather than Elixir AST
    @plain_gettext ~r/(?<![\w.])gettext\("([^"\\#%]*)"\)/

    defp gettext_to_sigil(igniter) do
      update_matching_files(igniter, "lib/**/*.{ex,heex}", fn content ->
        Regex.replace(@plain_gettext, content, ~S|~t"\1"|)
      end)
    end

    defp add_live_reload_pattern(igniter) do
      if Igniter.exists?(igniter, "config/runtime.exs") or
           Igniter.exists?(igniter, "config/dev.exs") do
        Enum.reduce(["config/runtime.exs", "config/dev.exs"], igniter, fn file, igniter ->
          if Igniter.exists?(igniter, file),
            do: Igniter.update_elixir_file(igniter, file, &insert_pattern/1),
            else: igniter
        end)
      else
        igniter
      end
    end

    defp insert_pattern(zipper) do
      already? = Common.move_to(zipper, &pattern?(&1, "priv/translations")) != :error

      case Common.move_to(zipper, &pattern?(&1, "priv/gettext")) do
        {:ok, gettext} when not already? ->
          {:ok,
           Zipper.insert_right(
             gettext,
             Sourceror.parse_string!(~S|~r"priv/translations/.*\.json$"|)
           )}

        _ ->
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
