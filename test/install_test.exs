defmodule VerifiedTranslations.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp content(igniter, path),
    do: igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)

  defp install(files) do
    test_project(files: files)
    |> Igniter.compose_task("verified_translations.install", ["--locales", "en,fi"])
  end

  test "creates .credo.exs with the check and adds credo" do
    igniter = install(%{})

    assert content(igniter, ".credo.exs") =~
             "extra: [\n          {VerifiedTranslations.Credo.PreferSigil, []}"

    assert content(igniter, "mix.exs") =~ "{:credo,"
  end

  test "adds the check to an existing config once" do
    credo = """
    %{
      configs: [
        %{
          name: "default",
          checks: %{
            enabled: [
              {Credo.Check.Readability.ModuleDoc, []}
            ]
          }
        }
      ]
    }
    """

    igniter = install(%{".credo.exs" => credo})
    updated = content(igniter, ".credo.exs")
    assert updated =~ "{VerifiedTranslations.Credo.PreferSigil, []},"
    assert updated =~ "{Credo.Check.Readability.ModuleDoc, []}"

    again =
      install(%{".credo.exs" => updated})
      |> content(".credo.exs")

    assert again |> String.split("PreferSigil") |> length() == 2
  end

  test "configures locales" do
    assert install(%{}) |> content("config/config.exs") =~ ~s(locales: ["en", "fi"])
  end
end
