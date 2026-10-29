# Generates modules using translations + translated PO files into a Phoenix app.
#
#   elixir bench/generate.exs APP_DIR MODULES MSGS_PER_MODULE LOCALES MODE
#
# MODE is "sigil" (~t) or "gettext" (plain gettext/2 for comparison).
[app_dir, modules, per_module, locales, mode] = System.argv()
{modules, per_module} = {String.to_integer(modules), String.to_integer(per_module)}
locales = String.split(locales, ",")

web = app_dir |> Path.join("lib/*_web.ex") |> Path.wildcard() |> hd()
web_module = web |> File.read!() |> then(&Regex.run(~r/defmodule (\S+) do/, &1)) |> List.last()
gen_dir = Path.join([Path.rootname(web), "gen"])
File.rm_rf!(gen_dir)
File.mkdir_p!(gen_dir)

msg = fn m, i -> "Message #{i} of page #{m} for %{name}" end

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

for locale <- locales do
  dir = Path.join([app_dir, "priv/gettext", locale, "LC_MESSAGES"])
  File.mkdir_p!(dir)

  entries =
    for m <- 1..modules, i <- 1..per_module do
      text = msg.(m, i)
      ~s|msgid "#{text}"\nmsgstr "[#{locale}] #{text}"\n|
    end

  File.write!(Path.join(dir, "default.po"), [
    ~s|msgid ""\nmsgstr ""\n"Language: #{locale}\\n"\n\n|,
    Enum.intersperse(entries, "\n")
  ])
end

IO.puts(
  "generated #{modules} modules x #{per_module} msgs (#{modules * per_module} msgids) x #{length(locales)} locales, mode=#{mode}"
)
