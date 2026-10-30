defmodule VerifiedTranslations.Credo.PreferSigilTest do
  use Credo.Test.Case

  alias VerifiedTranslations.Credo.PreferSigil

  test "reports gettext calls in code and ~H templates" do
    ~S'''
    defmodule MyAppWeb.Page do
      def gettext("Hello"), do: :ok
      def title, do: gettext("Settings")
      def files(n), do: ngettext("1 file", "%{count} files", n)

      def render(assigns) do
        ~H"""
        <p>gettext("plain text")</p>
        <p>{dgettext("errors", "Oops")}</p>
        """
      end
    end
    '''
    |> to_source_file()
    |> run_check(PreferSigil)
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(&{&1.trigger, &1.line_no}) |> Enum.sort() ==
               [{"dgettext", 9}, {"gettext", 3}, {"ngettext", 4}]

      assert Enum.find(issues, &(&1.trigger == "ngettext")).message =~ "Use tn/2"
    end)
  end

  test "~t and tn are fine" do
    ~S'''
    defmodule MyAppWeb.Page do
      def title, do: ~t"Settings"
      def files(n), do: tn(n, one: "1 file", other: "%{count} files")
    end
    '''
    |> to_source_file()
    |> run_check(PreferSigil)
    |> refute_issues()
  end
end
