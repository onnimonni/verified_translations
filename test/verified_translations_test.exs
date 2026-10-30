defmodule VerifiedTranslationsTest do
  use ExUnit.Case, async: true

  alias VerifiedTranslations.{Compiler, Message}

  @moduletag :tmp_dir

  defp put(dir, msgid, translations) do
    path = Message.path(dir, "default", msgid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Message.encode(msgid, translations))
    path
  end

  defp compile!(dir, body, opts \\ "") do
    module = Module.concat(__MODULE__, "M#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use VerifiedTranslations, path: #{inspect(dir)}, locales: ["en", "fi", "sv"]#{opts}
      def run(name, user), do: (_ = {name, user}; #{body})
    end
    """)

    module
  end

  defp compile_error(dir, body, opts \\ "") do
    error = assert_raise CompileError, fn -> compile!(dir, body, opts) end
    Exception.message(error)
  end

  test "inlines translations with bindings", %{tmp_dir: dir} do
    put(dir, "Hello %{name}", %{"fi" => "Hei %{name}", "sv" => "Hej %{name}"})
    module = compile!(dir, ~S|~t"Hello #{name}"|)

    assert module.run("Onni", nil) == "Hello Onni"
    assert VerifiedTranslations.with_locale("fi", fn -> module.run("Onni", nil) end) == "Hei Onni"
    assert VerifiedTranslations.with_locale("sv", fn -> module.run(1, nil) end) == "Hej 1"

    assert VerifiedTranslations.with_locale("de", fn -> module.run("Onni", nil) end) ==
             "Hello Onni"

    # unset: falls back to Gettext's locale
    assert VerifiedTranslations.get_locale() == Gettext.get_locale()
  end

  test "field access bindings and source locale override", %{tmp_dir: dir} do
    put(dir, "By %{user_name}", %{
      "en" => "Written by %{user_name}",
      "fi" => "%{user_name} kirjoitti",
      "sv" => "Av %{user_name}"
    })

    module = compile!(dir, ~S|~t"By #{user.name}"|)

    assert module.run(nil, %{name: "Onni"}) == "Written by Onni"

    assert VerifiedTranslations.with_locale("fi", fn -> module.run(nil, %{name: "Onni"}) end) ==
             "Onni kirjoitti"
  end

  test "creates a stub for missing messages and fails", %{tmp_dir: dir} do
    message = compile_error(dir, ~S|~t"Brand new"|)
    assert message =~ ~s("Brand new": created translation file, translate fi, sv)

    path = Message.path(dir, "default", "Brand new")
    assert {:ok, %{"msgid" => "Brand new", "fi" => "", "sv" => ""}, _} = Message.read(path)

    # still failing until translated
    assert compile_error(dir, ~S|~t"Brand new"|) =~ "fi is not translated; sv is not translated"

    put(dir, "Brand new", %{"fi" => "Upouusi", "sv" => "Helt ny"})
    assert compile!(dir, ~S|~t"Brand new"|)
  end

  test "create_missing: false only reports", %{tmp_dir: dir} do
    assert compile_error(dir, ~S|~t"Nope"|, ", create_missing: false") =~
             "missing translation file"

    refute File.exists?(Message.path(dir, "default", "Nope"))
  end

  test "rejects unknown bindings, unknown locales and wrong msgid", %{tmp_dir: dir} do
    put(dir, "Hi %{name}", %{"fi" => "Moi %{nimi}", "sv" => "Hej", "fl" => "typo"})
    message = compile_error(dir, ~S|~t"Hi #{name}"|)
    assert message =~ "fi uses unknown %{nimi}"
    assert message =~ ~s(unknown locale "fl")

    path = Message.path(dir, "default", "Other")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"msgid": "Changed", "fi": "x", "sv": "y"}))
    assert compile_error(dir, ~S|~t"Other"|) =~ ~s(msgid in file is "Changed")
  end

  test "rejects invalid JSON and non-string values", %{tmp_dir: dir} do
    path = Message.path(dir, "default", "Broken")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"msgid": "Broken",))
    assert compile_error(dir, ~S|~t"Broken"|) =~ "invalid JSON"

    put(dir, "Number", %{"fi" => 1, "sv" => "y"})
    assert compile_error(dir, ~S|~t"Number"|) =~ "fi must be a string"
  end

  test "reports all errors of a module at once", %{tmp_dir: dir} do
    assert compile_error(dir, ~S|{~t"One", ~t"Two"}|) =~ "2 untranslated message(s)"
  end

  test "rejects literal placeholders and ambiguous keys", %{tmp_dir: dir} do
    assert compile_error(dir, ~S|~t"Hi %{name}"|) =~ "literal %{name}"

    assert compile_error(dir, ~S|~t"#{name} #{name = user}"|) =~
             "ambiguous interpolation keys name"
  end

  test "file without msgid is rejected", %{tmp_dir: dir} do
    path = Message.path(dir, "default", "Anon")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"fi": "x", "sv": "y"}))
    assert compile_error(dir, ~S|~t"Anon"|) =~ "msgid is missing"
  end

  test "unicode and ?/! variable names", %{tmp_dir: dir} do
    put(dir, "Hi %{käyttäjä} %{ready?}", %{"fi" => "Moi %{käyttäjä} %{ready?}", "sv" => "Hej"})
    module = compile!(dir, ~S|(käyttäjä = name; ready? = user; ~t"Hi #{käyttäjä} #{ready?}")|)

    assert VerifiedTranslations.with_locale("fi", fn -> module.run("Onni", true) end) ==
             "Moi Onni true"
  end

  test "use options are evaluated and a later domain overrides", %{tmp_dir: dir} do
    path = Message.path(dir, "admin", "Admin only")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Message.encode("Admin only", %{"fi" => "Vain admin"}))
    module = Module.concat(__MODULE__, "Opts#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      @dir #{inspect(dir)}
      use VerifiedTranslations, path: @dir, locales: ~w(en fi sv)
      use VerifiedTranslations, domain: "admin", locales: ~w(en fi)
      def run, do: ~t"Admin only"
    end
    """)

    assert VerifiedTranslations.with_locale("fi", fn -> module.run() end) == "Vain admin"
  end

  test "locale syncs with and falls back to Gettext" do
    VerifiedTranslations.with_locale("fi", fn -> assert Gettext.get_locale() == "fi" end)
    refute Gettext.get_locale() == "fi"
    Gettext.with_locale("sv", fn -> assert VerifiedTranslations.get_locale() == "sv" end)
  end

  test "only configured locales are required", %{tmp_dir: dir} do
    put(dir, "Only fi", %{"fi" => "Vain suomi"})
    assert compile!(dir, ~S|~t"Only fi"|, ~S|, locales: ["en", "fi"]|)
  end

  test "__mix_recompile__? tracks only the module's own files", %{tmp_dir: dir} do
    path = put(dir, "Tracked", %{"fi" => "a", "sv" => "b"})
    module = compile!(dir, ~S|~t"Tracked"|)

    refute module.__mix_recompile__?()
    assert module.__verified_translations__() == [path]

    put(dir, "Unrelated", %{"fi" => "a", "sv" => "b"})
    refute module.__mix_recompile__?()

    put(dir, "Tracked", %{"fi" => "changed", "sv" => "b"})
    assert module.__mix_recompile__?()
  end

  describe "parse_parts/2" do
    defp parse(string) do
      {:sigil_t, _, [{:<<>>, _, parts}, []]} = Code.string_to_quoted!("~t\"#{string}\"")
      {msgid, bindings} = Compiler.parse_parts(parts, __ENV__)
      {msgid, Keyword.keys(bindings)}
    end

    test "variables, assigns and field access" do
      assert parse(~S|Hi #{name}|) == {"Hi %{name}", [:name]}
      assert parse(~S|Hi #{@name}|) == {"Hi %{name}", [:name]}

      assert parse(~S|Hi #{@user.name} #{post.title}|) ==
               {"Hi %{user_name} %{post_title}", [:user_name, :post_title]}

      assert parse(~S|#{a.name} and #{b.name}|) ==
               {"%{a_name} and %{b_name}", [:a_name, :b_name]}

      assert parse(~S|Line\nbreak|) == {"Line\nbreak", []}
      assert parse(~S|#{a} and #{a}|) == {"%{a} and %{a}", [:a]}
    end

    # same keys as gettext_sigils, so their PO msgids import 1:1
    test "gettext_sigils compatible keys" do
      assert parse(~S|#{count = length(xs)} items|) == {"%{count} items", [:count]}
      assert parse(~S|#{length(xs)}|) == {"%{length}", [:length]}
      assert parse(~S|#{String.upcase(x)}|) == {"%{string_upcase}", [:string_upcase]}
      assert parse(~S|#{a + b}|) == {"%{var}", [:var]}
      assert parse(~S|#{userName}|) == {"%{username}", [:username]}

      assert parse(~S|#{fruit.name} is #{color}|) ==
               {"%{fruit_name} is %{color}", [:fruit_name, :color]}
    end
  end

  test "file names are readable, stable and unique" do
    assert Message.file_name("Hello %{name}!") =~ ~r/^hello-name-[0-9a-f]{32}\.json$/
    assert Message.file_name("Hyvää päivää") =~ ~r/^hyvää-päivää-[0-9a-f]{32}\.json$/
    refute Message.file_name("Hello") == Message.file_name("hello")
    assert Message.file_name("!!!") =~ ~r/^[0-9a-f]{32}\.json$/

    # collided with the old 8 character hash
    a = String.duplicate("a", 48)
    refute Message.file_name(a <> " 9343") == Message.file_name(a <> " 81140")

    # long and unicode text stays well below the 255 byte limit
    assert byte_size(Message.file_name(String.duplicate("각", 48))) < 120
    assert byte_size(Message.file_name(String.duplicate("x", 500))) < 120
  end
end
