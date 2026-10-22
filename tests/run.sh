#!/bin/sh
# Runs every tests/*_spec.lua in its own headless Neovim. Pass spec names to run only those.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$root/tests/bin:$PATH"
status=0
guard=""
command -v timeout >/dev/null 2>&1 && guard="timeout 180"
specs=${*:-$(cd "$root/tests" && ls *_spec.lua)}
for spec in $specs; do
  echo "== $spec"
  if ! $guard nvim --headless -u NONE -i NONE -n --cmd "set rtp^=$root" -c "luafile $root/tests/$spec"; then
    status=1
  fi
done
exit $status
