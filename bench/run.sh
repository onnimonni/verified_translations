#!/usr/bin/env bash
# Benchmarks compile times of a generated Phoenix app using ~t vs plain gettext.
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
    mix verified_translations.install --yes >/dev/null)
fi

now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
t() { local s; s=$(now); "$@" >/dev/null 2>&1 || { echo "FAILED: $*" >&2; (cd "$APP" && mix compile 2>&1 | tail -20) >&2; exit 1; }; perl -e "printf q(%.2f), $(now) - $s"; }
compile() { (cd "$APP" && mix compile); }
po="$APP/priv/gettext/${LOCALES%%,*}/LC_MESSAGES/default.po"

for mode in gettext sigil; do
  elixir generate.exs "$APP" "$MODULES" "$PER_MODULE" "$LOCALES" "$mode"
  (cd "$APP" && mix deps.compile verified_translations --force >/dev/null 2>&1 && rm -rf _build/dev/lib/bench_app)
  printf '%-8s cold compile:            %ss\n' "$mode" "$(t compile)"
  printf '%-8s no-op compile:           %ss\n' "$mode" "$(t compile)"
  touch "$po"
  printf '%-8s touch po (no change):    %ss\n' "$mode" "$(t compile)"
  perl -pi -e 's/\[(\w+)\] Message 1 of page 1 for/[$1] Changed message 1 of page 1 for/' "$po"
  printf '%-8s edit 1 translation:      %ss\n' "$mode" "$(t compile)"
done

perl -0pi -e 's/msgstr "\[(\w+)\] Message 2 of page 3 for %\{name\}"/msgstr ""/' "$po"
out=$(cd "$APP" && mix compile 2>&1 || true)
if grep -q "Message 2 of page 3" <<<"$out"; then
  echo "sigil    break 1 translation:      compile error reported (ok)"
else
  echo "sigil    break 1 translation:      NOT DETECTED"; exit 1
fi
