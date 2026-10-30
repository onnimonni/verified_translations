# Generates modules using translations + translated files into a Phoenix app.
#
#   elixir bench/generate.exs APP_DIR MODULES MSGS_PER_MODULE LOCALES MODE
#
# MODE is "sigil" (~t + priv/translations JSON), "gettext" (gettext/2 + PO)
# or "gettext-split" (same, with `split_module_by: [:locale]` on the backend).
# Every module also uses one shared message, "Save".
[app_dir, modules, per_module, locales, mode] = System.argv()
{modules, per_module} = {String.to_integer(modules), String.to_integer(per_module)}
locales = String.split(locales, ",")
gettext? = mode != "sigil"

web = app_dir |> Path.join("lib/*_web.ex") |> Path.wildcard() |> hd()
web_module = web |> File.read!() |> then(&Regex.run(~r/defmodule (\S+) do/, &1)) |> List.last()
gen_dir = Path.join([Path.rootname(web), "gen"])
File.rm_rf!(gen_dir)
File.mkdir_p!(gen_dir)

# Gettext backend: split by locale only in gettext-split mode
backend = Path.join(Path.rootname(web), "gettext.ex")
source = File.read!(backend) |> String.replace(", split_module_by: [:locale]", "")

source =
  if mode == "gettext-split",
    do:
      Regex.replace(
        ~r/(use Gettext.Backend, otp_app: :\w+)/,
        source,
        "\\1, split_module_by: [:locale]"
      ),
    else: source

File.write!(backend, source)

msg = fn m, i -> "Message #{i} of page #{m} for %{name}" end
msgids = ["Save" | for(m <- 1..modules, i <- 1..per_module, do: msg.(m, i))]

call = fn
  text when gettext? -> ~s|gettext("#{text}", name: @name)|
  text -> ~s|~t"#{String.replace(text, "%{name}", "\#{@name}")}"|
end

for m <- 1..modules do
  body =
    ["Save" | Enum.map(1..per_module, &msg.(m, &1))]
    |> Enum.map_join("\n", fn text -> "      <p>{#{call.(text)}}</p>" end)

  File.write!(Path.join(gen_dir, "page_#{m}.ex"), """
  defmodule #{web_module}.Gen.Page#{m} do
    use #{web_module}, :html

    def render(assigns) do
      ~H\"\"\"
      <div>
  #{body}
      </div>
      \"\"\"
    end
  end
  """)
end

translate = fn locale, text -> "[#{locale}] #{text}" end

root = Path.join(app_dir, "priv/translations/default")
File.mkdir_p!(root)

# fill stubs of non-generated messages (e.g. CoreComponents)
generated = MapSet.new(msgids)

for path <- Path.wildcard(Path.join(root, "*.json")) do
  data = path |> File.read!() |> JSON.decode!()

  if data["msgid"] in generated do
    File.rm!(path)
  else
    filled = Map.new(locales, &{&1, translate.(&1, data["msgid"])})
    File.write!(path, JSON.encode!(Map.merge(data, filled)))
  end
end

for locale <- locales do
  File.rm_rf!(Path.join([app_dir, "priv/gettext", locale]))
end

if gettext? do
  for locale <- locales do
    dir = Path.join([app_dir, "priv/gettext", locale, "LC_MESSAGES"])
    File.mkdir_p!(dir)

    entries =
      for text <- msgids, do: ~s|msgid "#{text}"\nmsgstr "#{translate.(locale, text)}"\n|

    File.write!(Path.join(dir, "default.po"), [
      ~s|msgid ""\nmsgstr ""\n"Language: #{locale}\\n"\n\n|,
      Enum.intersperse(entries, "\n")
    ])
  end
else
  Code.prepend_path(Path.expand("../_build/dev/lib/verified_translations/ebin", __DIR__))

  for text <- msgids do
    translations = Map.new(locales, &{&1, translate.(&1, text)})
    path = VerifiedTranslations.Message.path(root |> Path.dirname(), "default", text)
    File.write!(path, VerifiedTranslations.Message.encode(text, translations))
  end
end

IO.puts(
  "generated #{modules} modules x #{per_module + 1} msgs (#{length(msgids)} msgids) x " <>
    "#{length(locales)} locales, mode=#{mode}"
)
