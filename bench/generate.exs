# Generates modules using translations + translated files into a Phoenix app.
#
#   elixir bench/generate.exs APP_DIR MODULES MSGS_PER_MODULE LOCALES MODE
#
# MODE is "sigil" (~t + priv/translations JSON) or "gettext" (gettext/2 + PO).
[app_dir, modules, per_module, locales, mode] = System.argv()
{modules, per_module} = {String.to_integer(modules), String.to_integer(per_module)}
locales = String.split(locales, ",")

web = app_dir |> Path.join("lib/*_web.ex") |> Path.wildcard() |> hd()
web_module = web |> File.read!() |> then(&Regex.run(~r/defmodule (\S+) do/, &1)) |> List.last()
gen_dir = Path.join([Path.rootname(web), "gen"])
File.rm_rf!(gen_dir)
File.mkdir_p!(gen_dir)

msg = fn m, i -> "Message #{i} of page #{m} for %{name}" end
msgids = for m <- 1..modules, i <- 1..per_module, do: msg.(m, i)

call = fn
  "sigil", text -> ~s|~t"#{String.replace(text, "%{name}", "\#{@name}")}"|
  "gettext", text -> ~s|gettext("#{text}", name: @name)|
end

for m <- 1..modules do
  body =
    Enum.map_join(1..per_module, "\n", fn i -> "      <p>{#{call.(mode, msg.(m, i))}}</p>" end)

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
root |> Path.join("message-*.json") |> Path.wildcard() |> Enum.each(&File.rm!/1)

# fill stubs of non-generated messages (e.g. CoreComponents)
for path <- Path.wildcard(Path.join(root, "*.json")) do
  data = path |> File.read!() |> JSON.decode!()
  filled = Map.new(locales, &{&1, translate.(&1, data["msgid"])})
  File.write!(path, JSON.encode!(Map.merge(data, filled)))
end

case mode do
  "sigil" ->
    for text <- msgids do
      translations = Map.new(locales, &{&1, translate.(&1, text)})
      json = JSON.encode!(Map.put(translations, "msgid", text))
      hash = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      slug = text |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
      File.write!(Path.join(root, "#{slug}-#{hash}.json"), json)
    end

  "gettext" ->
    for locale <- locales do
      dir = Path.join([app_dir, "priv/gettext", locale, "LC_MESSAGES"])
      File.mkdir_p!(dir)

      entries =
        for text <- msgids,
            do: ~s|msgid "#{text}"\nmsgstr "#{translate.(locale, text)}"\n|

      File.write!(Path.join(dir, "default.po"), [
        ~s|msgid ""\nmsgstr ""\n"Language: #{locale}\\n"\n\n|,
        Enum.intersperse(entries, "\n")
      ])
    end
end

IO.puts(
  "generated #{modules} modules x #{per_module} msgs (#{length(msgids)} msgids) x " <>
    "#{length(locales)} locales, mode=#{mode}"
)
