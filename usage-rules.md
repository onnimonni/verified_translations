# VerifiedTranslations usage rules

`~t` translations are verified at compile time. A message that is missing in any configured
locale fails `mix compile`. Never work around that: translate the message.

## Writing text

- Write user-facing text as `~t"..."` in templates and code. Inside HEEx use `{~t"..."}`.
- Interpolate values directly: `~t"Hi #{@user.name}"` binds `%{user_name}`. Prefer variables,
  assigns and fields; name other expressions explicitly: `~t"#{count = length(items)} left"`.
- Never write a literal `%{x}` inside `~t`; interpolate a value instead.
- Plurals: `tn(count, one: "%{count} file", other: "%{count} files")`. Give exactly the source
  locale's CLDR categories in code. In the JSON file each locale needs exactly its own
  categories, e.g. Russian `one`, `few`, `many`, `other`.
- The module needs `use VerifiedTranslations`. Phoenix web modules get it from `use MyAppWeb, :html`.

- `gettext("...")`, `ngettext(...)` and the other Gettext macros are verified too and read from
  the same JSON files, but prefer `~t`/`tn` in new code (Credo flags the macros).
- Ordinals: `tn(n, ordinal: true, one: "%{count}st", two: "%{count}nd", few: "%{count}rd", other: "%{count}th")`.

## Translating

Each message is one JSON file at `priv/translations/<domain>/<slug>-<hash>.json`. Don't create,
rename or move these files by hand. Use the mix tasks, and always pass your exact model ID:

```sh
mix verified_translations.extract           # create files for new ~t messages
mix verified_translations.missing --json    # list what lacks translations
mix verified_translations.put --model <your-model-id> "Hi %{user_name}" fi="Moi %{user_name}" sv="Hej %{user_name}"
mix verified_translations.put --model <your-model-id> --from translations.json   # many at once
mix compile                                 # must pass
```

- `missing --json` prints entries in the format `put --from` accepts. Fill the empty locales and
  feed the entries back.
- `put` records your translations as `"origin": {"fi": {"by": "machine", "model": "..."}}`. Pass
  the exact model ID you run as (for example `claude-opus-5-5`), never a guess or a family name.
- Never pass `--human` and never run `mix verified_translations.review --approve`. Only people who
  checked the translations may do that. List what awaits review with
  `mix verified_translations.review`.
- Translations may only use `%{bindings}` that appear in the msgid. Keep them, but reorder them as
  the language needs.
- Don't edit the `"msgid"` key. Changing the text in code creates a new file; delete the old one
  with `mix verified_translations.unused --delete`.
- The source locale (usually `en`) is the msgid itself and needs no entry.

## Verifying translations

Verify every translation before you `put` it, and say in your summary which ones you're unsure
about:

1. **Meaning.** Translate back to the source language in your head; the meaning, tone and
   intent must match. Read the code around the `~t` (a button? an error? a page title?) rather
   than translating the string alone.
2. **Placeholders.** Every `%{binding}` of the msgid appears exactly once in each form, and
   nothing else looks like `%{...}`. The compiler rejects unknown bindings, but not missing ones.
3. **Consistency.** Search existing translations (`grep -r "<term>" priv/translations`) and reuse
   the same words for the same concepts, and the same formality (Finnish sinä/te, German du/Sie,
   French tu/vous) as the rest of the app.
4. **Plurals and ordinals.** Each form must read correctly for counts in its CLDR category
   (Russian `few`: 2-4, 22-24; `many`: 5-20, 25-30). Check a few counts for every form, not just
   1 and 2.
5. **Fit.** Keep UI strings about as long as the source; buttons and labels must not wrap. Keep
   the source's punctuation, capitalization style and trailing spaces where they matter.
6. **Don't translate** brand names, code, URLs, email addresses or `%{bindings}`.
7. **Unsure?** Leave the locale empty rather than guessing, and list it for a person to
   translate. Empty translations fail compilation, which is safer than a wrong one shipping.

## Migrating existing gettext code

- Run `mix verified_translations.migrate --dry-run`, review the diff, then run it without
  `--dry-run`. Don't rewrite `gettext` calls to `~t` by hand: the task also moves the
  translations and renames their placeholders.
- Calls it reports as left on Gettext (contexts, other domains) stay on Gettext.
- If compilation says translations "are still in Gettext PO files", run
  `mix verified_translations.extract`. It moves them into JSON.

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
