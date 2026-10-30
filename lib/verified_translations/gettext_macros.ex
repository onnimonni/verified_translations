defmodule VerifiedTranslations.GettextMacros do
  @moduledoc """
  Gettext's translation macros, compiled to verified JSON translations.

  `use VerifiedTranslations` imports these instead of `Gettext.Macros`'
  versions, so existing code keeps working while every call is verified at
  compile time and read from `priv/translations` like `~t`:

      gettext("Hello %{name}", name: user.name)
      ngettext("1 file", "%{count} files", n)
      dgettext("errors", "Not found")
      pgettext("menu", "Open")

  The msgid and binding names stay exactly as written, so the JSON file of
  `gettext("Hello %{name}", name: user.name)` has the msgid
  `"Hello %{name}"`. A plural call is the same message as
  `tn(n, one: "1 file", other: "%{count} files")`.

  Msgids, domains and contexts must be compile-time strings, like Gettext
  requires. Bindings may be a literal keyword list or any expression
  evaluating to a keyword list or map.

  Opt out with `use VerifiedTranslations, gettext: false`. Runtime functions
  such as `Gettext.dgettext(MyAppWeb.Gettext, "errors", msg)` (used by
  `translate_error/1`) are not affected.
  """

  alias VerifiedTranslations.Compiler

  @doc false
  def overridden do
    [
      gettext: 1,
      gettext: 2,
      dgettext: 2,
      dgettext: 3,
      pgettext: 2,
      pgettext: 3,
      dpgettext: 3,
      dpgettext: 4,
      ngettext: 3,
      ngettext: 4,
      dngettext: 4,
      dngettext: 5,
      pngettext: 4,
      pngettext: 5,
      dpngettext: 5,
      dpngettext: 6
    ]
  end

  defmacro gettext(msgid, bindings \\ []),
    do: Compiler.gettext(:default, nil, msgid, nil, nil, bindings, __CALLER__)

  defmacro dgettext(domain, msgid, bindings \\ []),
    do: Compiler.gettext(domain, nil, msgid, nil, nil, bindings, __CALLER__)

  defmacro pgettext(context, msgid, bindings \\ []),
    do: Compiler.gettext(:default, context, msgid, nil, nil, bindings, __CALLER__)

  defmacro dpgettext(domain, context, msgid, bindings \\ []),
    do: Compiler.gettext(domain, context, msgid, nil, nil, bindings, __CALLER__)

  defmacro ngettext(msgid, msgid_plural, count, bindings \\ []),
    do: Compiler.gettext(:default, nil, msgid, msgid_plural, count, bindings, __CALLER__)

  defmacro dngettext(domain, msgid, msgid_plural, count, bindings \\ []),
    do: Compiler.gettext(domain, nil, msgid, msgid_plural, count, bindings, __CALLER__)

  defmacro pngettext(context, msgid, msgid_plural, count, bindings \\ []),
    do: Compiler.gettext(:default, context, msgid, msgid_plural, count, bindings, __CALLER__)

  defmacro dpngettext(domain, context, msgid, msgid_plural, count, bindings \\ []),
    do: Compiler.gettext(domain, context, msgid, msgid_plural, count, bindings, __CALLER__)
end
