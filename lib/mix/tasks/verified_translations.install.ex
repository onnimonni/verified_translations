defmodule Mix.Tasks.VerifiedTranslations.Install.Docs do
  @moduledoc false

  def short_doc, do: "Installs verified_translations into a Phoenix project"

  def example, do: "mix igniter.install verified_translations --locales fi,sv"

  def long_doc do
    """
    #{short_doc()}

    Replaces `use Gettext, backend: MyAppWeb.Gettext` with
    `use VerifiedTranslations, backend: MyAppWeb.Gettext` in your web module
    so the `~t` sigil is available in all controllers, components and LiveViews.

    ## Example

    ```sh
    #{example()}
    ```

    ## Options

    * `--locales` - comma separated locales to create PO files for (runs `mix gettext.merge`)
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.VerifiedTranslations.Install do
    @shortdoc Mix.Tasks.VerifiedTranslations.Install.Docs.short_doc()
    @moduledoc Mix.Tasks.VerifiedTranslations.Install.Docs.long_doc()

    use Igniter.Mix.Task

    alias Igniter.Code.{Common, Function}

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
      igniter
      |> Igniter.update_glob("lib/**/*.ex", &replace_use_gettext/1)
      |> add_locales(igniter.args.options[:locales])
      |> Igniter.add_notice("""
      verified_translations installed.

      Use ~t"Hello \#{name}" instead of gettext("Hello %{name}", name: name).
      Missing translations now fail compilation. Workflow:

          mix gettext.extract --merge   # add new msgids to priv/gettext
          # translate msgstr in priv/gettext/<locale>/LC_MESSAGES/*.po
          mix compile
      """)
    end

    defp replace_use_gettext(zipper) do
      Common.update_all_matches(
        zipper,
        &(Function.function_call?(&1, :use, 2) and
            Function.argument_equals?(&1, 0, Gettext)),
        fn zipper ->
          Function.update_nth_argument(zipper, 0, fn arg ->
            {:ok, Common.replace_code(arg, VerifiedTranslations)}
          end)
        end
      )
    end

    defp add_locales(igniter, []), do: igniter

    defp add_locales(igniter, locales) do
      Enum.reduce(locales, Igniter.add_task(igniter, "gettext.extract"), fn locale, igniter ->
        Igniter.add_task(igniter, "gettext.merge", ["priv/gettext", "--locale", locale])
      end)
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

      Or replace `use Gettext, backend: MyAppWeb.Gettext` with
      `use VerifiedTranslations, backend: MyAppWeb.Gettext` manually.
      """)

      exit({:shutdown, 1})
    end
  end
end
