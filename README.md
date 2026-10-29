# VerifiedTranslations

Compile-time verified translations for Phoenix.

`Phoenix.VerifiedRoutes` warns about `~p"/missing"` at compile time. `VerifiedTranslations` does
the same for text, but as a hard **compile error**, like typed translation keys in TypeScript:

```heex
<h1>{~t"Welcome, #{@user.name}!"}</h1>
```

```
== Compilation error in file lib/my_app_web/controllers/page_html.ex ==
** (CompileError) lib/my_app_web/controllers/page_html/home.html.heex:3: 1 untranslated message(s) in MyAppWeb.PageHTML:
  lib/my_app_web/controllers/page_html/home.html.heex:3: "Welcome, %{name}!": fi uses unknown %{nimi}; sv is not translated
    priv/translations/default/welcome-name-0adeb8ce.json
```

## Why not Gettext `.po` files?

The library was built for teams running **many parallel branches, worktrees and coding agents**:

* **One JSON file per message**, holding every locale. Two branches that add different
  messages never touch the same file, so translation files don't merge-conflict. There are
  no source line references and no whole-file rewrites on extract.
* **Translations are inlined at compile time** into the module that uses them, as a `case` on
  the current locale. There is no runtime lookup table and no Gettext backend to recompile.
  Editing a translation recompiles **only the modules that use that message**.
* **Strict and safe format.** JSON parses with Elixir's built-in `JSON` (no dependency, no code
  evaluation, no YAML-style implicit typing). Only `msgid` and configured locales are allowed as
  keys, and every value must be a string.

```json
// priv/translations/default/welcome-name-0adeb8ce.json
{
  "msgid": "Welcome, %{name}!",
  "fi": "Tervetuloa, %{name}!",
  "sv": "Välkommen, %{name}!"
}
```

The file name is a readable slug plus a hash of the msgid, so the sigil finds its file directly
without an index.

## What is verified

For every `~t`, at compile time:

* the translation file exists. If it doesn't, compiling creates a stub you only need to fill in
* every configured locale except the source locale has a non-empty translation
* translations only use `%{bindings}` that the call site provides
* the file has no unknown locale keys (catches typos like `"fl"`) and its `msgid` matches

A module reports all of its failures at once.

## Sigil

```elixir
~t"Settings"
~t"Hello #{name}"                # msgid "Hello %{name}"
~t"Hello #{@name}"               # works in HEEx and LiveView
~t"By #{@post.author.name}"      # binding is the last field: %{name}
```

Only variables, assigns and field access can be interpolated. Bind anything else to a variable
first. The source text renders for the source locale and for unknown locales. To change the
English copy without changing the code, add an `"en"` key to the file.

## Installation

With [Igniter](https://hexdocs.pm/igniter):

```sh
mix igniter.install verified_translations --locales en,fi,sv
```

The installer:

* adds `config :verified_translations, locales: [...], source_locale: "en"`
* adds `use VerifiedTranslations` next to every `use Gettext, backend: ...`
* rewrites plain `gettext("literal")` calls (also inside `~H` and `.heex`) to `~t"literal"`
* imports existing translations from `priv/gettext/*/LC_MESSAGES/*.po`
* adds `priv/translations` to the Phoenix live reload patterns

To install manually, add `{:verified_translations, "~> 0.1"}`, the config above and
`use VerifiedTranslations` in the `html_helpers` of `lib/my_app_web.ex`.

### Configuration

```elixir
config :verified_translations,
  locales: ["en", "fi", "sv"],
  source_locale: "en",            # language of the text written in ~t
  path: "priv/translations",
  create_missing: true            # write stub files for new messages
```

`use VerifiedTranslations, domain: "admin"` (and any of the keys above) overrides the config per
module. Each domain is a subdirectory.

### Locale

The locale is stored per process:

```elixir
VerifiedTranslations.put_locale("fi")
VerifiedTranslations.with_locale("sv", fn -> ~t"Hello #{name}" end)
```

Set it in a plug for controllers and in an `on_mount` hook for LiveViews. See
[`example/lib/example_web/plugs/locale.ex`](example/lib/example_web/plugs/locale.ex).

## Workflow

```sh
# write ~t"New text" in code, then:
mix verified_translations.extract   # creates every missing file and lists untranslated ones
# fill in priv/translations/default/new-text-1a2b3c4d.json
mix compile                         # passes once every locale is translated
mix verified_translations.unused    # CI: fail on translation files no ~t uses (--delete removes them)
```

`mix compile` also creates stub files. `extract` creates them for every module in a single pass,
including modules that would otherwise wait on a failing dependency.

## Performance

[`bench/run.sh`](bench/run.sh) generates a Phoenix app with 200 LiveView-style modules × 25
messages (5,000 msgids) × 5 locales, then compares plain Gettext with `~t`. Measured on an Apple
Silicon laptop:

| | Gettext (`gettext/2` + `.po`) | `~t` + JSON |
|---|---|---|
| cold compile | 122.5s | **5.9s** |
| no-op `mix compile` | 0.66s | 0.66s |
| edit one translation | 123.0s (whole Gettext backend) | **0.86s** (only the module using it) |
| empty one translation | compiles, falls back to msgid at runtime | **compile error** |

Most of Gettext's time goes into compiling its backend, which turns every translation into a
function clause. `~t` reads one ~24µs JSON file per call site and inlines the strings. At runtime
each message costs one process-dictionary read and a `case`.

Parsing 5,000 message files with 6 locales each, by format: JSON 118ms, Erlang terms 156ms,
PO 158ms, Elixir literals 219ms, TOML 587ms, YAML 1316ms. JSON is both the fastest and the
safest, since it needs no code evaluation or implicit typing.

## Example app

[`example/`](example/) is a fresh `mix phx.new` app with
`mix verified_translations.install --locales en,fi,sv` applied, plus translated home-page text and
a `?locale=fi` plug.

```sh
cd example && mix deps.get && mix test
```

## Limitations

* No plurals or `msgctxt` yet. Keep using `ngettext` for plurals.
* The locale is per process. LiveViews need it set in `on_mount`.

## License

MIT
