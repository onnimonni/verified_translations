defmodule VerifiedTranslations.MigrateTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp po(locale, entries) do
    body =
      Enum.map_join(entries, "\n", fn {msgid, msgstr} ->
        ~s|msgid #{inspect(msgid)}\nmsgstr #{inspect(msgstr)}\n|
      end)

    ~s|msgid ""\nmsgstr ""\n"Language: #{locale}\\n"\n\n| <> body
  end

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  setup do
    igniter =
      test_project(
        files: %{
          "lib/test_web/live/page.ex" => ~S'''
          defmodule TestWeb.Page do
            use TestWeb, :html

            def gettext_like("Hello"), do: :ok
            def title, do: gettext("Settings")
            def greet(user), do: gettext("Hi %{name}", name: user.name)
            def files(n), do: ngettext("1 file", "%{count} files", n)
            def error, do: dgettext("errors", "is invalid")
            def computed(u), do: gettext("Hi %{name}", name: String.upcase(u))

            def render(assigns) do
              ~H"""
              <p title={gettext("Settings")}>gettext("Visible text")</p>
              <p>{gettext("Welcome, %{name}!", name: @current_user.name)}</p>
              """
            end
          end
          ''',
          "lib/test_web/live/page.html.heex" => ~S'''
          <h1>{gettext("Quote \"me\"")}</h1>
          ''',
          "lib/test/plain.ex" => ~S'''
          defmodule Test.Plain do
            def text, do: gettext("Not a web module")
          end
          ''',
          "priv/gettext/default.pot" =>
            po("", [{"Settings", ""}, {"Hi %{name}", ""}, {"Kept", ""}]),
          "priv/gettext/fi/LC_MESSAGES/default.po" =>
            po("fi", [
              {"Settings", "Asetukset"},
              {"Hi %{name}", "Moi %{name}"},
              {"Welcome, %{name}!", "Tervetuloa, %{name}!"},
              {"Kept", "Pidetty"}
            ])
        }
      )
      |> Igniter.compose_task("verified_translations.migrate", ["--locales", "en,fi"])

    %{igniter: igniter}
  end

  test "rewrites gettext calls in code, ~H and .heex", %{igniter: igniter} do
    page = content(igniter, "lib/test_web/live/page.ex")

    assert page =~ ~S|def gettext_like("Hello"), do: :ok|
    assert page =~ ~S|def title, do: ~t"Settings"|
    assert page =~ ~S|def greet(user), do: ~t"Hi #{user.name}"|
    assert page =~ ~S|<p title={~t"Settings"}>gettext("Visible text")</p>|
    assert page =~ ~S|<p>{~t"Welcome, #{@current_user.name}!"}</p>|

    # left on gettext
    assert page =~ ~S|ngettext("1 file", "%{count} files", n)|
    assert page =~ ~S|dgettext("errors", "is invalid")|
    assert page =~ ~S|gettext("Hi %{name}", name: String.upcase(u))|

    assert content(igniter, "lib/test_web/live/page.html.heex") =~ ~S|{~t"Quote \"me\""}|
    assert content(igniter, "lib/test/plain.ex") =~ ~S|gettext("Not a web module")|
  end

  test "moves translations to JSON with renamed placeholders", %{igniter: igniter} do
    json = fn msgid ->
      path = VerifiedTranslations.Message.path("priv/translations", "default", msgid)
      igniter |> content(path) |> JSON.decode!()
    end

    assert json.("Settings") == %{"msgid" => "Settings", "fi" => "Asetukset"}
    assert json.("Hi %{user_name}") == %{"msgid" => "Hi %{user_name}", "fi" => "Moi %{user_name}"}

    assert json.("Welcome, %{current_user_name}!") ==
             %{
               "msgid" => "Welcome, %{current_user_name}!",
               "fi" => "Tervetuloa, %{current_user_name}!"
             }

    assert json.(~S|Quote "me"|) == %{"msgid" => ~S|Quote "me"|, "fi" => ""}
  end

  test "prunes migrated messages still not used by gettext", %{igniter: igniter} do
    fi = content(igniter, "priv/gettext/fi/LC_MESSAGES/default.po")
    pot = content(igniter, "priv/gettext/default.pot")

    refute fi =~ ~s(msgid "Settings")
    refute fi =~ ~s(msgid "Welcome, %{name}!")
    assert fi =~ ~s(msgid "Kept")
    # still used by the gettext call with a computed binding
    assert fi =~ ~s(msgid "Hi %{name}")
    refute pot =~ ~s(msgid "Settings")
  end

  test "reports calls left on gettext", %{igniter: igniter} do
    skipped = Enum.find(igniter.notices, &(&1 =~ "left"))
    assert skipped =~ "plural (ngettext)"
    assert skipped =~ ~s(domain "errors")
    assert skipped =~ "binding %{name} is not a variable, assign or field"
  end
end
