# VerifiedTranslations usage rules

`~t` translations are verified at compile time. A message that is missing in any configured
locale fails `mix compile`. Never work around that: translate the message.

## Writing text

- Write user-facing text as `~t"..."` in templates and code. Inside HEEx use `{~t"..."}`.
- Interpolate only variables, assigns or field access: `~t"Hi #{@user.name}"`. The binding is
  named after the full path (`%{user_name}`). Bind other expressions to a variable first.
- Never write a literal `%{x}` inside `~t`; interpolate a variable instead.
- `~t` has no plural support yet. Use `ngettext/3` for plurals.
- The module needs `use VerifiedTranslations`. Phoenix web modules get it from `use MyAppWeb, :html`.

## Translating

Each message is one JSON file at `priv/translations/<domain>/<slug>-<hash>.json`. Don't create,
rename or move these files by hand. Use the mix tasks:

```sh
mix verified_translations.extract           # create files for new ~t messages
mix verified_translations.missing --json    # list what lacks translations
mix verified_translations.put "Hi %{user_name}" fi="Moi %{user_name}" sv="Hej %{user_name}"
mix verified_translations.put --from translations.json   # many at once
mix compile                                 # must pass
```

- `missing --json` prints entries in the format `put --from` accepts. Fill the empty locales and
  feed the entries back.
- Translations may only use `%{bindings}` that appear in the msgid. Keep them, but reorder them as
  the language needs.
- Don't edit the `"msgid"` key. Changing the text in code creates a new file; delete the old one
  with `mix verified_translations.unused --delete`.
- The source locale (usually `en`) is the msgid itself and needs no entry.

## Migrating existing gettext code

- Run `mix verified_translations.migrate --dry-run`, review the diff, then run it without
  `--dry-run`. Don't rewrite `gettext` calls to `~t` by hand: the task also moves the
  translations and renames their placeholders.
- Calls it reports as left on Gettext (plurals, contexts, other domains, computed bindings) stay
  on Gettext. To convert one with a computed binding, bind the value to a variable first and run
  the task again.

## Locale

- `VerifiedTranslations.put_locale("fi")` sets the locale for the current process and for
  Gettext. Use `plug VerifiedTranslations.Plug` and `on_mount: VerifiedTranslations.LiveView`
  rather than custom code.
- Processes started with `Task` or `assign_async` don't inherit the locale. Call `put_locale/1`
  in them or use `with_locale/2`.
- A LiveView doesn't re-render `~t` text when the locale changes. Switch locale with
  `push_navigate/2` to remount.

## Don't

- Don't replace `~t` with plain strings or `gettext/1` to make compilation pass.
- Don't set `create_missing: false` or edit config locales to silence errors.
- Don't commit JSON files with empty translations.
