if Code.ensure_loaded?(Credo.Check) do
  defmodule VerifiedTranslations.Credo.PreferSigil do
    use Credo.Check,
      id: "VT001",
      base_priority: :normal,
      category: :readability,
      explanations: [
        check: ~S"""
        Prefer the `~t` sigil and `tn/2` over Gettext's macros.

            # not preferred
            gettext("Welcome back, %{name}!", name: @user.name)
            ngettext("1 file", "%{count} files", length(files))

            # preferred
            ~t"Welcome back, #{@user.name}!"
            tn(length(files), one: "1 file", other: "%{count} files")

        Both are verified at compile time by verified_translations, but `~t`
        keeps the bindings next to the text. Fix all of them automatically
        with:

            mix verified_translations.migrate
        """
      ]

    @gettext ~w(gettext dgettext pgettext dpgettext ngettext dngettext pngettext dpngettext)a
    @definitions [:def, :defp, :defmacro, :defmacrop]
    @heex ~r/\{\s*((?:d?p?n?)gettext)\(/

    @doc false
    @impl true
    def run(%SourceFile{} = source_file, params) do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      Enum.reverse(result.issues)
    end

    # function heads named like gettext are definitions, not calls
    defp walk({kind, meta, [_head | body]}, ctx) when kind in @definitions do
      {{kind, meta, body}, ctx}
    end

    defp walk({name, meta, args} = ast, ctx) when name in @gettext and is_list(args) do
      {ast, put_issue(ctx, issue_for(ctx, name, meta[:line]))}
    end

    # {gettext(...)} expressions inside ~H templates
    defp walk({:sigil_H, meta, [{:<<>>, _, [template]}, _]} = ast, ctx)
         when is_binary(template) do
      ctx =
        @heex
        |> Regex.scan(template, return: :index)
        |> Enum.reduce(ctx, fn [_, {start, length}], ctx ->
          name = template |> binary_part(start, length) |> String.to_existing_atom()
          offset = template |> binary_part(0, start) |> String.split("\n") |> length()

          first_line =
            if meta[:delimiter] in [~s("""), "'''"], do: meta[:line] + 1, else: meta[:line]

          put_issue(ctx, issue_for(ctx, name, first_line + offset - 1))
        end)

      {ast, ctx}
    end

    defp walk(ast, ctx), do: {ast, ctx}

    defp issue_for(ctx, name, line_no) do
      replacement =
        if name in [:ngettext, :dngettext, :pngettext, :dpngettext], do: "tn/2", else: "~t"

      format_issue(
        ctx,
        message:
          "Use #{replacement} instead of #{name}; `mix verified_translations.migrate` rewrites it.",
        trigger: Atom.to_string(name),
        line_no: line_no
      )
    end
  end
end
