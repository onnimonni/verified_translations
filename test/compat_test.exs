defmodule VerifiedTranslations.CompatTest do
  # the extract test sets a global env var
  use ExUnit.Case, async: false

  alias VerifiedTranslations.Message

  @moduletag :tmp_dir

  defmodule Upcase do
    def postprocess(string, _opts), do: {:ok, String.upcase(string)}
  end

  defmodule Prefix do
    def init(opts), do: {:ok, Keyword.put_new(opts, :prefix, "!")}
    def preprocess({msgid, bindings}, opts), do: {:ok, {opts[:prefix] <> msgid, bindings}}
  end

  defp write(dir, msgid, translations, opts \\ []) do
    domain = Keyword.get(opts, :domain, "default")
    path = Message.path(dir, domain, msgid, Keyword.take(opts, [:context, :plural]))
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Message.encode(msgid, translations, Keyword.take(opts, [:context, :plural]))
    )

    path
  end

  defp compile(dir, use_opts, body) do
    module = Module.concat(__MODULE__, "M#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use VerifiedTranslations, path: #{inspect(dir)}, gettext_path: #{inspect(Path.join(dir, "gettext"))}#{if use_opts == "", do: "", else: ", " <> use_opts}
      #{body}
    end
    """)

    module
  end

  defp error(dir, use_opts, body) do
    e = assert_raise CompileError, fn -> compile(dir, use_opts, body) end
    Exception.message(e)
  end

  defp fi(fun), do: VerifiedTranslations.with_locale("fi", fun)

  describe "gettext_sigils options" do
    test "sigils: domain, context and keyword modifiers", %{tmp_dir: dir} do
      write(dir, "Welcome", %{"fi" => "Tervetuloa", "sv" => "Välkommen"},
        domain: "frontend",
        context: "dashboard"
      )

      write(dir, "Not found", %{"fi" => "Ei löytynyt", "sv" => "Hittades inte"},
        domain: "errors",
        context: "dashboard"
      )

      write(dir, "Yes", %{"fi" => "Kyllä", "sv" => "Ja"})

      m =
        compile(
          dir,
          ~S|sigils: [domain: "frontend", context: "dashboard", modifiers: [e: [domain: "errors"], g: [domain: :default, context: nil]]]|,
          ~S'''
          def welcome, do: ~t"Welcome"
          def not_found, do: ~t"Not found"e
          def yes, do: ~t"Yes"g
          '''
        )

      assert fi(fn -> {m.welcome(), m.not_found(), m.yes()} end) ==
               {"Tervetuloa", "Ei löytynyt", "Kyllä"}

      assert {:ok, %{"msgctxt" => "dashboard"}, _} =
               Message.read(Message.path(dir, "errors", "Not found", context: "dashboard"))
    end

    test "module modifiers: init, preprocess, postprocess", %{tmp_dir: dir} do
      write(dir, "!Hi", %{"fi" => "!Moi", "sv" => "!Hej"})

      m =
        compile(
          dir,
          "sigils: [modifiers: [u: #{inspect(Upcase)}, p: #{inspect(Prefix)}]]",
          ~S|def hi, do: ~t"Hi"pu|
        )

      assert m.hi() == "!HI"
      assert fi(&m.hi/0) == "!MOI"
    end

    test "unknown modifier", %{tmp_dir: dir} do
      assert error(dir, "", ~S|def x, do: ~t"X"z|) =~ ~s(unknown ~t modifier "z")
    end

    test "backend: brings in the Gettext macros", %{tmp_dir: dir} do
      defmodule Backend, do: use(Gettext.Backend, otp_app: :verified_translations)
      m = compile(dir, "backend: #{inspect(Backend)}", ~S|def g, do: gettext("Plain gettext")|)
      assert m.g() == "Plain gettext"
    end
  end

  describe "plurals" do
    test "tn/2 with CLDR categories per locale", %{tmp_dir: dir} do
      forms = [one: "%{count} file", other: "%{count} files"]

      write(
        dir,
        "%{count} files",
        %{
          "fi" => %{"one" => "%{count} tiedosto", "other" => "%{count} tiedostoa"},
          "ru" => %{
            "one" => "%{count} файл",
            "few" => "%{count} файла",
            "many" => "%{count} файлов",
            "other" => "%{count} файла"
          }
        },
        plural: forms
      )

      m =
        compile(
          dir,
          ~S|locales: ~w(en fi ru)|,
          ~S|def files(n), do: tn(n, one: "%{count} file", other: "%{count} files")|
        )

      assert Enum.map([1, 2], &m.files/1) == ["1 file", "2 files"]
      assert fi(fn -> Enum.map([1, 5], &m.files/1) end) == ["1 tiedosto", "5 tiedostoa"]

      assert VerifiedTranslations.with_locale("ru", fn -> Enum.map([1, 3, 5, 21], &m.files/1) end) ==
               ["1 файл", "3 файла", "5 файлов", "21 файл"]
    end

    test "tn/2 checks source and translated categories", %{tmp_dir: dir} do
      assert error(dir, "", ~S|def x(n), do: tn(n, other: "%{count} x")|) =~
               ~s(needs exactly the "en" plural categories)

      write(
        dir,
        "%{count} files",
        %{"fi" => %{"other" => "%{count} tiedostoa"}, "sv" => %{"one" => "1", "other" => "2"}},
        plural: [one: "%{count} file", other: "%{count} files"]
      )

      assert error(
               dir,
               "",
               ~S|def x(n), do: tn(n, one: "%{count} file", other: "%{count} files")|
             ) =~
               ~s(fi needs plural forms ["one", "other"], got ["other"])
    end

    test "tn/2 with other bindings", %{tmp_dir: dir} do
      write(
        dir,
        "%{name} has %{count} items",
        %{
          "fi" => %{"one" => "%{name}: %{count} tuote", "other" => "%{name}: %{count} tuotetta"},
          "sv" => %{"one" => "a", "other" => "b"}
        },
        plural: [one: "%{name} has one item", other: "%{name} has %{count} items"]
      )

      m =
        compile(
          dir,
          "",
          ~S|def x(name, n), do: tn(n, one: "#{name} has one item", other: "#{name} has %{count} items")|
        )

      assert m.x("Onni", 1) == "Onni has one item"
      assert fi(fn -> m.x("Onni", 3) end) == "Onni: 3 tuotetta"
    end

    test "~t N modifier (gettext_sigils compatible)", %{tmp_dir: dir} do
      write(
        dir,
        "%{count} error(s)",
        %{
          "fi" => %{"one" => "%{count} virhe", "other" => "%{count} virhettä"},
          "sv" => %{"one" => "%{count} fel", "other" => "%{count} fel"}
        },
        plural: true
      )

      m = compile(dir, "", ~S|def errors(xs), do: ~t"#{count = length(xs)} error(s)"N|)
      assert m.errors([1, 2]) == "2 error(s)"
      assert fi(fn -> {m.errors([1]), m.errors([1, 2])} end) == {"1 virhe", "2 virhettä"}

      assert error(dir, "", ~S|def x(n), do: ~t"#{n} things"N|) =~
               ~s(requires a "count" binding)
    end
  end

  describe "messages still in Gettext PO files" do
    setup %{tmp_dir: dir} do
      po_dir = Path.join([dir, "gettext", "fi", "LC_MESSAGES"])
      File.mkdir_p!(po_dir)

      File.write!(Path.join(po_dir, "default.po"), ~S'''
      msgid ""
      msgstr ""
      "Language: fi\n"
      "Plural-Forms: nplurals=2; plural=(n != 1);\n"

      msgid "Hello %{name}"
      msgstr "Hei %{name}"

      msgid "1 file"
      msgid_plural "%{count} files"
      msgstr[0] "%{count} tiedosto"
      msgstr[1] "%{count} tiedostoa"
      ''')

      :ok
    end

    test "fail compilation and name the command", %{tmp_dir: dir} do
      message = error(dir, ~S|locales: ~w(en fi)|, ~S|def x(name), do: ~t"Hello #{name}"|)
      assert message =~ "translations for fi are still in Gettext PO files"
      assert message =~ "mix verified_translations.extract"
      refute File.exists?(Message.path(dir, "default", "Hello %{name}"))
    end

    test "extract imports them, singular and plural", %{tmp_dir: dir} do
      System.put_env("VERIFIED_TRANSLATIONS_EXTRACT", "1")

      try do
        compile(dir, ~S|locales: ~w(en fi)|, ~S'''
        def x(name), do: ~t"Hello #{name}"
        def files(n), do: tn(n, one: "1 file", other: "%{count} files")
        ''')
      after
        System.delete_env("VERIFIED_TRANSLATIONS_EXTRACT")
      end

      m =
        compile(dir, ~S|locales: ~w(en fi)|, ~S'''
        def x(name), do: ~t"Hello #{name}"
        def files(n), do: tn(n, one: "1 file", other: "%{count} files")
        ''')

      assert fi(fn -> {m.x("Onni"), m.files(1), m.files(4)} end) ==
               {"Hei Onni", "1 tiedosto", "4 tiedostoa"}
    end
  end
end
