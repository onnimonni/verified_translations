defmodule VerifiedTranslations.TestGettext do
  use Gettext.Backend, otp_app: :verified_translations, priv: "test/fixtures/gettext"
end
