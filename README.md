# VerifiedTranslations

Compile-time verified translations for Phoenix.

`Phoenix.VerifiedRoutes` warns about `~p"/missing"` at compile time. `VerifiedTranslations` does
the same for text, but as a hard **compile error**, like typed translation keys in TypeScript:

```heex
<h1>{~t"Welcome, #{@name}!"}</h1>
```

```
== Compilation error in file lib/my_app_web/controllers/page_html.ex ==
** (CompileError) lib/my_app_web/controllers/page_html/home.html.heex:3: 1 untranslated message(s) in MyAppWeb.PageHTML:
  lib/my_app_web/controllers/page_html/home.html.heex:3: "Welcome, %{name}!": fi uses unknown %{nimi}; sv is not translated
    priv/translations/default/welcome-name-0adeb8ce318553d7af0738e424d672b2.json
```

## Why not Gettext `.po` files?

The library was built for teams running **many parallel branches, worktrees and coding agents**:

* **One JSON file per message**, holding every locale. Two branches that add different
  messages never touch the same file, so translation files don't merge-conflict. There are
  no source line references and no whole-file rewrites on extract.
* **Translations are inlined at compile time** into the module that uses them, as a literal
  tuple with one slot per locale. There is no runtime lookup table and no Gettext backend to
  recompile. Editing a translation recompiles **only the modules that use that message**.
* **Strict and safe format.** JSON parses with Elixir's built-in `JSON` (no dependency, no code
  evaluation, no YAML-style implicit typing). Only `msgid` and configured locales are allowed as
  keys, and every value must be a string.

```json
// priv/translations/default/welcome-name-0adeb8ce318553d7af0738e424d672b2.json
{
  "msgid": "Welcome, %{name}!",
  "fi": "Tervetuloa, %{name}!",
  "sv": "Välkommen, %{name}!"
}
```

The file name is a readable slug (at most 64 bytes) plus a 128-bit hash of the msgid, so the sigil
finds its file directly without an index. Stub files are created atomically, so parallel compilers
never read a half-written file.

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
~t"Hello #{@name}"               # works in HEEx and LiveView: %{name}
~t"By #{@post.author.name}"      # full path: %{post_author_name}
~t"#{a.name} meets #{b.name}"    # %{a_name} meets %{b_name}
~t"Line one\nline two"           # escapes work like in strings
```

Only variables, assigns and field access can be interpolated. Bind anything else to a variable
first. Bindings must implement `String.Chars`. The source text renders for the source locale and
for unknown locales. To change the English copy without changing the code, add an `"en"` key to
the file.

## Installation

With [Igniter](https://hexdocs.pm/igniter):

```sh
mix igniter.install verified_translations --locales en,fi,sv
```

The installer:

* adds `config :verified_translations, locales: [...], source_locale: "en", gettext_backend: ...`
* adds `use VerifiedTranslations` after every `use Gettext, backend: ...` (idempotent)
* runs `mix verified_translations.migrate` (see [Migrating from Gettext](#migrating-from-gettext))
* adds `priv/translations` to the Phoenix live reload patterns

To install manually, add `{:verified_translations, "~> 0.1"}`, the config above and
`use VerifiedTranslations` in the `html_helpers` of `lib/my_app_web.ex`.

### Migrating from Gettext

`mix verified_translations.migrate` (run by the installer, and safe to run again) moves an existing
Gettext app over. Add `--dry-run` to review the diff first.

```elixir
gettext("Welcome back, %{name}! You have %{n} items.", name: @user.name, n: @count)
# becomes
~t"Welcome back, #{@user.name}! You have #{@count} items."
```

* It rewrites `gettext/1,2` and `dgettext("default", ...)` in Elixir code, `~H` templates and
  `.heex` files, with minimal patches that leave the rest of each file untouched. Function heads,
  docs and plain template text are left alone.
* It moves each converted message's translations from `priv/gettext/*/LC_MESSAGES/default.po`
  into its JSON file. Placeholders are renamed to the names `~t` uses: `%{name}` becomes
  `%{user_name}` and `%{n}` becomes `%{count}`.
* It removes migrated messages from the `.po` and `.pot` files unless a remaining `gettext` call
  still uses them.
* It lists the calls left on Gettext, with file and line. These are plurals (`ngettext`),
  contexts (`pgettext`), other domains, and bindings that aren't a variable, assign or field.

### Configuration

```elixir
config :verified_translations,
  locales: ["en", "fi", "sv"],
  source_locale: "en",            # language of the text written in ~t
  path: "priv/translations",
  create_missing: true,           # write stub files for new messages
  gettext_backend: MyAppWeb.Gettext
```

Config is read with `Application.compile_env`, so changing it recompiles the callers and releases
refuse a different runtime value. `use VerifiedTranslations, domain: "admin"` (and any of the keys
above, including `@attributes` or `~w(...)`) overrides the config per module, even after
`use MyAppWeb, :html`. Each domain is a subdirectory.

### Locale

The locale is stored per process, like Gettext's:

```elixir
VerifiedTranslations.put_locale("fi")
VerifiedTranslations.with_locale("sv", fn -> ~t"Hello #{name}" end)
VerifiedTranslations.known_locales()
```

`put_locale/1` also sets the Gettext locale, so remaining `gettext`/`ngettext` calls and
`translate_error/1` render in the same language. When `put_locale/1` was never called, `~t`
follows the Gettext locale, so apps that already set it keep working.

```elixir
# router.ex: ?locale=fi, remembered in the session
plug VerifiedTranslations.Plug

live_session :default, on_mount: VerifiedTranslations.LiveView do
  ...
end
```

LiveView change tracking doesn't re-render expressions that use no assigns. That covers
`{~t"Settings"}`, just like `{gettext("Settings")}`, and it can't be changed from a macro because
HEEx analyzes templates before macros expand. To switch locale inside a LiveView, navigate so it
remounts: `push_navigate(socket, to: ~p"/settings?locale=fi")`. Processes started with `Task` or
`assign_async` don't inherit the locale; call `put_locale/1` in them.

## Workflow

```sh
# write ~t"New text" in code, then:
mix verified_translations.extract   # creates every missing file and lists untranslated ones
mix verified_translations.put "New text" fi="Uusi teksti" sv="Ny text"
mix compile                         # passes once every locale is translated
mix verified_translations.unused    # CI: fail on translation files no ~t uses (--delete removes them)
```

| Task | Purpose |
|---|---|
| `extract` | compiles with verification off, creating every missing file at once |
| `missing [--json]` | lists messages lacking a locale, without compiling. The JSON goes straight back into `put --from` |
| `put MSGID locale=text…` | writes translations and validates locales and `%{bindings}` first. `--from file.json` (or `-` for stdin) takes many messages at once; `--domain` picks the domain |
| `unused [--delete]` | lists or deletes files no `~t` uses. Exits non-zero for CI |
| `migrate` | rewrites `gettext` calls to `~t` and moves their translations (Igniter, supports `--dry-run`) |
| `import_po` | imports all translations from Gettext `.po` files, without touching code |

`mix compile` also creates stub files. `extract` creates them for every module in a single pass,
including modules that would otherwise wait on a failing dependency. It also adds empty keys when
you configure a new locale. Modules compiled during extraction are always recompiled and verified
afterwards, including in the same `mix do ...` run. In umbrella projects the tasks run per
application.

`mix verified_translations.import_po` migrates existing Gettext translations from the `default`
domain (`--domain errors` to add more). It never overwrites translations that already exist, and it
aborts when an existing file is invalid.

## Performance

[`bench/run.sh`](bench/run.sh) generates a Phoenix app with 200 HEEx modules. Each module uses 25
own messages plus one shared `"Save"`, which makes 5,001 msgids in 5 locales. The script compares
plain Gettext, Gettext with `split_module_by: [:locale]`, and `~t`. Measured on an Apple Silicon
laptop with Elixir 1.18, Gettext 1.0 and Phoenix 1.8:

| | Gettext | Gettext, split by locale | `~t` + JSON | plain HEEx, no translations |
|---|---|---|---|---|
| cold compile | 137.8s | 17.9s | **2.5s** | 2.5s |
| no-op `mix compile` | 0.76s | 0.52s | 0.61s | 0.48s |
| edit one translation | 139.5s | 16.5s | **0.73s** (1 module) | |
| edit a message used by all 200 modules | 134.0s | 16.3s | **2.4s** (200 modules) | |
| empty one translation | compiles, shows msgid | compiles, shows msgid | **compile error** | |

`~t` compiles as fast as untranslated text. Gettext recompiles its backend, which holds every
translation as function clauses, on any `.po` change. `~t` reads one small JSON file per call site
and only the modules using a changed message recompile.

Each `~t` compiles to a literal tuple with one slot per configured locale, indexed by the position
`put_locale/1` stores. Literals cost the compiler almost nothing. An earlier version inlined a
`case` with string building per locale, which took 6.0s cold. At runtime a static message takes
about 21ns (the `case` took 24ns) and a message with a binding about 70ns (the `case` took 32ns).
Modules that override `locales:` fall back to a map lookup.

[`bench/formats.exs`](bench/formats.exs) parses 5,000 one-message files with 6 locales in each
candidate format: JSON 128ms, Erlang terms 152ms, PO 175ms, Elixir literals 283ms, TOML 615ms,
YAML 1133ms. JSON is both the fastest and the safest, since it needs no code evaluation or
implicit typing.

## AI agents

The package ships [usage rules](usage-rules.md) and a pre-built
[skill](usage-rules/skills/verified-translations/SKILL.md) for
[usage_rules](https://hexdocs.pm/usage_rules). They teach agents the
`extract` → `missing --json` → `put --from` → `compile` loop and to never bypass verification:

```elixir
# mix.exs of your app
def project do
  [
    usage_rules: [
      file: "AGENTS.md",
      usage_rules: [:verified_translations],
      skills: [package_skills: [:verified_translations]]
    ]
  ]
end
```

```sh
mix usage_rules.sync
```

## Example app

[`example/`](example/) is a fresh `mix phx.new` app with
`mix verified_translations.install --locales en,fi,sv` applied, plus translated home-page text and
`plug VerifiedTranslations.Plug`.

```sh
cd example && mix deps.get && mix test
```

## Limitations

* No plurals or `msgctxt` yet. Keep using `ngettext` for plurals.
* A locale switch inside a LiveView needs a remount (see [Locale](#locale)).
* `unused --delete` doesn't support several umbrella apps sharing one translation directory.

## License

MIT
