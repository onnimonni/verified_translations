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
  end

  describe "gettext macro overrides" do
    test "gettext calls read verified JSON, keeping msgids and binding names", %{tmp_dir: dir} do
      write(dir, "Hello %{name}", %{"fi" => "Hei %{name}", "sv" => "Hej %{name}"})
      write(dir, "Not found", %{"fi" => "Ei löytynyt", "sv" => "Hittades inte"}, domain: "errors")
      write(dir, "Open", %{"fi" => "Avaa", "sv" => "Öppna"}, context: "menu")

      m =
        compile(dir, "", ~S'''
        @greeting "Hello %{name}"
        def hello(user), do: gettext("Hello %{name}", name: user.name)
        def hello_map(bindings), do: gettext(@greeting, bindings)
        def not_found, do: dgettext("errors", "Not found")
        def open, do: pgettext("menu", "Open")
        ''')

      assert m.hello(%{name: "Onni"}) == "Hello Onni"

      assert fi(fn ->
               {m.hello(%{name: "Onni"}), m.hello_map(%{name: "Onni"}), m.not_found(), m.open()}
             end) == {"Hei Onni", "Hei Onni", "Ei löytynyt", "Avaa"}
    end

    test "ngettext is the same message as tn/2", %{tmp_dir: dir} do
      write(
        dir,
        "%{count} files",
        %{
          "fi" => %{"one" => "%{count} tiedosto", "other" => "%{count} tiedostoa"},
          "sv" => %{"one" => "%{count} fil", "other" => "%{count} filer"}
        },
        plural: [{"one", "1 file"}, {"other", "%{count} files"}]
      )

      m =
        compile(dir, "", ~S'''
        def a(n), do: ngettext("1 file", "%{count} files", n)
        def b(n), do: tn(n, one: "1 file", other: "%{count} files")
        ''')

      assert {m.a(1), m.a(3)} == {"1 file", "3 files"}

      assert fi(fn -> {m.a(1), m.a(3), m.b(3)} end) ==
               {"1 tiedosto", "3 tiedostoa", "3 tiedostoa"}
    end

    test "verifies like ~t", %{tmp_dir: dir} do
      assert error(dir, "", ~S|def x, do: gettext("Brand new")|) =~ "created translation file"

      assert error(dir, "", ~S|def x, do: gettext("Hi %{name}", nome: 1)|) =~
               "binding %{name} is missing"

      assert error(dir, "", ~S|def x(m), do: gettext(m)|) =~ "msgid must be a compile-time string"
    end

    test "gettext: false keeps Gettext's macros", %{tmp_dir: dir} do
      defmodule Backend, do: use(Gettext.Backend, otp_app: :verified_translations)

      m =
        compile(
          dir,
          "backend: #{inspect(Backend)}, gettext: false",
          ~S|def g, do: gettext("Plain gettext")|
        )

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

    test "ordinals", %{tmp_dir: dir} do
      forms = [
        {"one", "%{count}st"},
        {"two", "%{count}nd"},
        {"few", "%{count}rd"},
        {"other", "%{count}th"}
      ]

      path =
        Message.path(dir, "default", "%{count}th", plural: forms, ordinal: true)

      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Message.encode(
          "%{count}th",
          %{
            "fi" => %{"other" => "%{count}."},
            "sv" => %{"one" => "%{count}:a", "other" => "%{count}:e"}
          },
          plural: true,
          ordinal: true
        )
      )

      m =
        compile(dir, "", ~S'''
        def place(n), do: tn(n, ordinal: true, one: "%{count}st", two: "%{count}nd", few: "%{count}rd", other: "%{count}th")
        ''')

      assert Enum.map([1, 2, 3, 4, 11, 21, 22, 113], &m.place/1) ==
               ~w(1st 2nd 3rd 4th 11th 21st 22nd 113th)

      assert fi(fn -> m.place(2) end) == "2."

      assert VerifiedTranslations.with_locale("sv", fn -> {m.place(1), m.place(3)} end) ==
               {"1:a", "3:e"}

      assert {:ok, %{"kind" => "ordinal"}, _} = Message.read(path)

      # cardinal categories are not accepted for an ordinal
      assert error(
               dir,
               "",
               ~S|def x(n), do: tn(n, ordinal: true, one: "%{count}st", other: "%{count}th")|
             ) =~
               ~s(needs exactly the "en" ordinal categories)
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
