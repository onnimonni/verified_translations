# VerifiedTranslations

Compile-time verified [Gettext](https://hexdocs.pm/gettext) translations for Phoenix.

`Phoenix.VerifiedRoutes` makes `~p"/missing"` a compile warning. `VerifiedTranslations`
does the same for text — but as a hard **compile error**, like typed translation keys in
TypeScript:

```heex
<h1>{~t"Welcome, #{@user.name}!"}</h1>
```

```
== Compilation error in file lib/my_app_web/controllers/page_html.ex ==
** (CompileError) lib/my_app_web/controllers/page_html/home.html.heex:3: 1 unverified translation(s) in MyAppWeb.PageHTML:
lib/my_app_web/controllers/page_html/home.html.heex:3: translation for "Welcome, %{name}!" (domain "default") is not verified:
  * fi: msgstr uses unknown binding(s) %{nimi} (priv/gettext/fi/LC_MESSAGES/default.po)
  * sv: empty msgstr (priv/gettext/sv/LC_MESSAGES/default.po)
Run `mix gettext.extract --merge` and translate the messages in priv/gettext.
```

## What is verified

For every `~t` and every locale in `priv/gettext` (except the source locale, usually `en`):

* msgid exists in the locale's PO file
* msgstr is not empty
* msgstr is not `#, fuzzy` (opt out with `allow_fuzzy: true`)
* msgstr only uses `%{bindings}` that the call site provides

All failures of a module are reported at once. Editing a `.po` file recompiles the
Gettext backend and every module using `~t`, so fixed or broken translations are
picked up by the next `mix compile` (and by Phoenix live reload).

## Sigil

```elixir
~t"Settings"                     # gettext("Settings")
~t"Hello #{name}"                # gettext("Hello %{name}", name: name)
~t"Hello #{@name}"               # works in HEEx and LiveView
~t"By #{@post.author.name}"      # binding is the last field: %{name}
```

Only variables, assigns and field access can be interpolated — bind anything else to a
variable first. The sigil expands to `Gettext.Macros.dgettext_with_backend/4`, so
`mix gettext.extract` picks up messages as usual and runtime behaviour is plain Gettext.

## Installation

With [Igniter](https://hexdocs.pm/igniter):

```sh
mix igniter.install verified_translations --locales fi,sv
```

This replaces every `use Gettext, backend: MyAppWeb.Gettext` in `lib/` with
`use VerifiedTranslations, backend: MyAppWeb.Gettext` (which still `use`s Gettext, so
`gettext/1` etc. keep working) and creates PO files for the given locales.

Manually:

```elixir
# mix.exs
{:verified_translations, "~> 0.1"}

# lib/my_app_web.ex (html_helpers/0) and anywhere else you `use Gettext`
use VerifiedTranslations, backend: MyAppWeb.Gettext
```

### Options

```elixir
use VerifiedTranslations,
  backend: MyAppWeb.Gettext,
  domain: "default",        # Gettext domain used by ~t
  locales: ["fi", "sv"],    # default: all locales in priv/gettext
  source_locale: "en",      # default: backend's default locale
  allow_fuzzy: false
```

## Workflow

```sh
# 1. write ~t"New text" -> mix compile fails: missing msgid in fi, sv
mix gettext.extract --merge   # verification is skipped while extracting
# 2. translate msgstr in priv/gettext/{fi,sv}/LC_MESSAGES/default.po
mix compile                   # passes
```

## Example app

[`example/`](example/) is a fresh `mix phx.new` app installed with
`mix verified_translations.install --locales fi,sv` and every `gettext/1` converted to `~t`.

```sh
cd example && mix deps.get && mix test
```

## Limitations

* Singular messages only (no plurals/`msgctxt` via `~t` yet — use `ngettext` for those).
* Requires Gettext `~> 0.26` / `1.x` and Elixir `~> 1.15`.

## License

MIT
