defmodule VerifiedTranslationsTest do
  use ExUnit.Case, async: true

  defp compile!(body, opts \\ "") do
    module = Module.concat(__MODULE__, "M#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use VerifiedTranslations, backend: VerifiedTranslations.TestGettext#{opts}
      def run(name), do: (_ = name; #{body})
    end
    """)

    module
  end

  defp compile_error(body, opts \\ "") do
    error = assert_raise CompileError, fn -> compile!(body, opts) end
    Exception.message(error)
  end

  test "translates with bindings named after variables" do
    module = compile!(~S|~t"Hello #{name}"|)

    assert module.run("Onni") == "Hello Onni"

    Gettext.with_locale(VerifiedTranslations.TestGettext, "fi", fn ->
      assert module.run("Onni") == "Hei Onni"
    end)
  end

  test "fails when msgid is missing in a locale" do
    message = compile_error(~S|~t"Only in Finnish"|)
    assert message =~ ~s(translation for "Only in Finnish")
    assert message =~ "sv: missing msgid"
    refute message =~ "en:"
  end

  test "fails on empty msgstr" do
    assert compile_error(~S|~t"Empty"|) =~ "sv: empty msgstr"
  end

  test "fails on unknown binding in msgstr" do
    assert compile_error(~S|~t"Bad binding"|) =~ "fi: msgstr uses unknown binding(s) %{nimi}"
  end

  test "fuzzy translations fail unless allowed" do
    assert compile_error(~S|~t"Fuzzy"|) =~ "fi: fuzzy translation"
    assert compile!(~S|~t"Fuzzy"|, ", allow_fuzzy: true")
  end

  test "only checks configured locales" do
    assert compile!(~S|~t"Only in Finnish"|, ~S|, locales: ["fi"]|)
  end

  test "reports all errors in a module" do
    message = compile_error(~S|{~t"Empty", ~t"Only in Finnish"}|)
    assert message =~ "2 unverified translation(s)"
  end

  test "rejects complex interpolations" do
    assert compile_error(~S|~t"Hello #{String.upcase(name)}"|) =~ "only interpolates variables"
  end

  describe "parse_parts/2" do
    defp parse(string) do
      {:sigil_t, _, [{:<<>>, _, parts}, []]} = Code.string_to_quoted!("~t\"#{string}\"")
      {msgid, bindings} = VerifiedTranslations.Verifier.parse_parts(parts, __ENV__)
      {msgid, Keyword.keys(bindings)}
    end

    test "variables, assigns and field access" do
      assert parse(~S|Hi #{name}|) == {"Hi %{name}", [:name]}
      assert parse(~S|Hi #{@name}|) == {"Hi %{name}", [:name]}
      assert parse(~S|Hi #{@user.name} #{post.title}|) == {"Hi %{name} %{title}", [:name, :title]}
      assert parse(~S|#{a} and #{a}|) == {"%{a} and %{a}", [:a]}
    end
  end
end
