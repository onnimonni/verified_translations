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
            ]) <>
              ~s|\nmsgid "1 file"\nmsgid_plural "%{count} files"\nmsgstr[0] "%{count} tiedosto"\nmsgstr[1] "%{count} tiedostoa"\n|
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

    # plurals become tn/2, computed bindings keep their key
    assert page =~ ~S|tn(n, one: "1 file", other: "%{count} files")|
    assert page =~ ~S|~t"Hi #{name = String.upcase(u)}"|

    # left on gettext
    assert page =~ ~S|dgettext("errors", "is invalid")|

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

    # computed binding: msgid unchanged
    assert json.("Hi %{name}") == %{"msgid" => "Hi %{name}", "fi" => "Moi %{name}"}

    plural_path =
      VerifiedTranslations.Message.path("priv/translations", "default", "%{count} files",
        plural: [{"one", "1 file"}, {"other", "%{count} files"}]
      )

    assert igniter |> content(plural_path) |> JSON.decode!() == %{
             "kind" => "plural",
             "msgid" => "%{count} files",
             "fi" => %{"one" => "%{count} tiedosto", "other" => "%{count} tiedostoa"}
           }
  end

  test "prunes migrated messages still not used by gettext", %{igniter: igniter} do
    fi = content(igniter, "priv/gettext/fi/LC_MESSAGES/default.po")
    pot = content(igniter, "priv/gettext/default.pot")

    refute fi =~ ~s(msgid "Settings")
    refute fi =~ ~s(msgid "Welcome, %{name}!")
    assert fi =~ ~s(msgid "Kept")
    refute fi =~ ~s(msgid "1 file")
    refute pot =~ ~s(msgid "Settings")
  end

  test "reports calls left on gettext", %{igniter: igniter} do
    skipped = Enum.find(igniter.notices, &(&1 =~ "left"))
    assert skipped =~ ~s(domain "errors")
    refute skipped =~ "ngettext"
  end
end

defmodule VerifiedTranslations.MigrateGettextSigilsTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "replaces gettext_sigils and schedules the PO import" do
    igniter =
      test_project(
        files: %{
          "lib/test_web.ex" => """
          defmodule TestWeb do
            def html do
              quote do
                use GettextSigils, backend: TestWeb.Gettext, sigils: [modifiers: [e: [domain: "errors"]]]
              end
            end
          end
          """
        }
      )
      |> Igniter.compose_task("verified_translations.migrate", ["--locales", "en,fi"])

    content =
      igniter.rewrite |> Rewrite.source!("lib/test_web.ex") |> Rewrite.Source.get(:content)

    assert content =~
             ~S|use VerifiedTranslations, backend: TestWeb.Gettext, sigils: [modifiers: [e: [domain: "errors"]]]|

    assert {"verified_translations.extract", []} in igniter.tasks
  end
end
