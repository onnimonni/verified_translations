defmodule VerifiedTranslations.ExtractTest do
  # sets a global env var, so not async
  use ExUnit.Case, async: false

  alias VerifiedTranslations.Message

  @moduletag :tmp_dir

  test "extract mode creates stubs without failing and forces a recompile", %{tmp_dir: dir} do
    System.put_env("VERIFIED_TRANSLATIONS_EXTRACT", "1")

    [{module, _}] =
      try do
        Code.compile_string("""
        defmodule VerifiedTranslations.ExtractTest.M do
          use VerifiedTranslations, path: #{inspect(dir)}, locales: ["en", "fi"]
          def run, do: {~t"First", ~t"Second"}
        end
        """)
      after
        System.delete_env("VERIFIED_TRANSLATIONS_EXTRACT")
      end

    assert module.run() == {"First", "Second"}
    assert File.exists?(Message.path(dir, "default", "First"))
    assert File.exists?(Message.path(dir, "default", "Second"))
    assert module.__mix_recompile__?()
  end
end
