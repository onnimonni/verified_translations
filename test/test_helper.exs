# the global locale order used by ~t's tuple fast path
Application.put_env(:verified_translations, :locales, ["en", "fi", "sv"])
ExUnit.start()
