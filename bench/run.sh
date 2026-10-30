#!/usr/bin/env bash
# Benchmarks compile times of a generated Phoenix app:
# ~t (JSON) vs gettext (PO) vs gettext with split_module_by: [:locale].
#   bench/run.sh [MODULES] [MSGS_PER_MODULE] [LOCALES]
set -euo pipefail
cd "$(dirname "$0")"
MODULES=${1:-200}
PER_MODULE=${2:-25}
LOCALES=${3:-fi,sv,de,fr,es}
APP=app

(cd .. && mix compile >/dev/null)

if [ ! -d "$APP" ]; then
  mix phx.new "$APP" --app bench_app --no-ecto --no-mailer --no-dashboard --no-assets --install >/dev/null
  (cd "$APP" &&
    perl -0pi -e 's/(\{:gettext, "[^"]*"\},)/$1\n      {:verified_translations, path: "..\/.."},\n      {:igniter, "~> 0.8", only: [:dev, :test]},/' mix.exs &&
    mix deps.get >/dev/null &&
    mix verified_translations.install --locales "en,$LOCALES" --yes >/dev/null &&
    mix verified_translations.extract >/dev/null 2>&1)
fi

now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
timed() {
  local s; s=$(now)
  local out; out=$(cd "$APP" && mix compile --verbose 2>&1) || { echo "FAILED" >&2; echo "$out" | tail -20 >&2; exit 1; }
  local took; took=$(perl -e "printf q(%.2f), $(now) - $s")
  echo "${took}s ($(grep -c "^Compiled" <<<"$out" || true) modules)"
}
first_locale=${LOCALES%%,*}

edit() { # edit MODE MSGID_PREFIX
  if [ "$1" = sigil ]; then
    file=$(grep -l "\"msgid\": \"$2" "$APP"/priv/translations/default/*.json)
  else
    file="$APP/priv/gettext/$first_locale/LC_MESSAGES/default.po"
  fi
  perl -pi -e "s/\\[(\\w+)\\] \Q$2\E/[\$1] Edited $2/" "$file"
}

for mode in ${MODES:-gettext gettext-split plain sigil}; do
  elixir generate.exs "$APP" "$MODULES" "$PER_MODULE" "$LOCALES" "$mode"
  rm -rf "$APP/_build/dev/lib/bench_app"
  printf '%-14s cold compile:          %s\n' "$mode" "$(timed)"
  printf '%-14s no-op compile:         %s\n' "$mode" "$(timed)"
  [ "$mode" = plain ] && continue
  edit "$mode" "Message 1 of page 1 for"
  printf '%-14s edit 1 translation:    %s\n' "$mode" "$(timed)"
  edit "$mode" "Save"
  printf '%-14s edit shared message:   %s\n' "$mode" "$(timed)"
done

file=$(grep -l '"msgid": "Message 2 of page 3 for' "$APP"/priv/translations/default/*.json)
perl -pi -e "s/\"$first_locale\": \"[^\"]*\"/\"$first_locale\": \"\"/" "$file"
out=$(cd "$APP" && mix compile 2>&1 || true)
if grep -q "Message 2 of page 3 for %{name}\": $first_locale is not translated" <<<"$out"; then
  echo "sigil          break 1 translation:   compile error reported (ok)"
else
  echo "sigil          break 1 translation:   NOT DETECTED"
  echo "$out" | tail -20
  exit 1
fi
