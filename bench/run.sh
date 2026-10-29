#!/usr/bin/env bash
# Benchmarks compile times of a generated Phoenix app: ~t (JSON) vs plain gettext (PO).
#   bench/run.sh [MODULES] [MSGS_PER_MODULE] [LOCALES]
set -euo pipefail
cd "$(dirname "$0")"
MODULES=${1:-200}
PER_MODULE=${2:-25}
LOCALES=${3:-fi,sv,de,fr,es}
APP=app

if [ ! -d "$APP" ]; then
  mix phx.new "$APP" --app bench_app --no-ecto --no-mailer --no-dashboard --no-assets --install >/dev/null
  (cd "$APP" &&
    perl -0pi -e 's/(\{:gettext, "[^"]*"\},)/$1\n      {:verified_translations, path: "..\/.."},\n      {:igniter, "~> 0.8", only: [:dev, :test]},/' mix.exs &&
    mix deps.get >/dev/null &&
    mix verified_translations.install --locales "en,$LOCALES" --yes >/dev/null &&
    mix verified_translations.extract >/dev/null 2>&1)
fi

now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
t() {
  local s; s=$(now)
  (cd "$APP" && mix compile) >/dev/null 2>&1 || { echo "FAILED" >&2; (cd "$APP" && mix compile 2>&1 | tail -20) >&2; exit 1; }
  perl -e "printf q(%.2f), $(now) - $s"
}
recompiled() { (cd "$APP" && mix compile --verbose 2>&1 | grep -c '^Compiled' || true); }
first_locale=${LOCALES%%,*}

for mode in gettext sigil; do
  rm -rf "$APP/priv/gettext/"{fi,sv,de,fr,es}
  elixir generate.exs "$APP" "$MODULES" "$PER_MODULE" "$LOCALES" "$mode"
  rm -rf "$APP/_build/dev/lib/bench_app"
  cold=$(t)
  printf "%-8s cold compile:          %ss\n" "$mode" "$cold"
  noop=$(t)
  printf "%-8s no-op compile:         %ss\n" "$mode" "$noop"

  if [ "$mode" = gettext ]; then
    file="$APP/priv/gettext/$first_locale/LC_MESSAGES/default.po"
  else
    file=$(grep -l '"Message 1 of page 1 for' "$APP"/priv/translations/default/*.json)
  fi
  perl -pi -e 's/\[(\w+)\] Message 1 of page 1 for/[$1] Changed message 1 of page 1 for/' "$file"
  s=$(now); n=$(recompiled)
  printf '%-8s edit 1 translation:    %ss (%s files recompiled)\n' "$mode" "$(perl -e "printf q(%.2f), $(now) - $s")" "$n"
done

file=$(grep -l '"Message 2 of page 3 for' "$APP"/priv/translations/default/*.json)
perl -pi -e "s/\"$first_locale\":\"[^\"]*\"/\"$first_locale\":\"\"/" "$file"
out=$(cd "$APP" && mix compile 2>&1 || true)
if grep -q "Message 2 of page 3 for %{name}\": $first_locale is not translated" <<<"$out"; then
  echo "sigil    break 1 translation:   compile error reported (ok)"
else
  echo "sigil    break 1 translation:   NOT DETECTED"
  echo "$out" | tail -20
  exit 1
fi
