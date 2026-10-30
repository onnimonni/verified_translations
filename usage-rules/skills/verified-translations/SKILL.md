---
name: verified-translations
description: "Use this skill when adding or changing user-facing text in a Phoenix app that uses verified_translations (~t sigil), or when mix compile fails with untranslated message(s)."
---

## Overview

`~t"..."` text is verified at compile time against JSON files in
`priv/translations/<domain>/`, one file per message holding every locale. A missing or wrong
translation is a compile error that names the file and the locales.

## Fixing "untranslated message(s)" compile errors

1. `mix verified_translations.extract` creates the files for every new `~t` message.
2. `mix verified_translations.missing --json > /tmp/missing.json` lists the empty locales.
3. Write each translation into the JSON entries. Keep every `%{binding}` from `"msgid"`, and
   remove the `"missing"` and `"domain"` keys or leave them; they're ignored.
4. `mix verified_translations.put --from /tmp/missing.json`, or one message at a time:
   `mix verified_translations.put "Save" fi=Tallenna sv=Spara`. `put` rejects unknown locales
   and bindings and writes nothing when anything is invalid.
5. `mix compile` must pass. Run `mix verified_translations.unused --delete` when text was
   changed or removed.

## Rules

- Write text as `~t"..."`, with `{~t"..."}` in HEEx. Interpolate only variables, assigns or field
  access. `#{@user.name}` becomes the binding `%{user_name}`.
- Never edit `"msgid"`, rename translation files or create them by hand.
- Never bypass verification by using plain strings, `gettext/1` or `create_missing: false`.
- Plurals: `tn(count, one: "...", other: "...")`. In JSON each locale is an object with exactly its
  CLDR categories, e.g. `"fi": {"one": "...", "other": "..."}`.
- "still in Gettext PO files" compile errors: run `mix verified_translations.extract`.
- Set the locale with `VerifiedTranslations.put_locale/1`, which also sets Gettext's locale.
  A LiveView needs a remount (`push_navigate`) after a locale switch.
