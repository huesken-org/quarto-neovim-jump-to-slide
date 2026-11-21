#!/usr/bin/env bash
# Runs all tests.
#   test/run.sh [quarto-project-for-integration-tests]
# Default project: ../go/go-testing-and-debugging (needs slides_04.html rendered).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
project=$(realpath "${1:-$repo/../go/go-testing-and-debugging}")

# Quarto does not follow symlinked extensions -> copy into the fixture.
rm -rf "$here/fixture/_extensions/quarto-jump"
mkdir -p "$here/fixture/_extensions"
cp -r "$repo/_extensions/quarto-jump" "$here/fixture/_extensions/"
(cd "$here/fixture" && quarto render deck.qmd --quiet && quarto render page.qmd --quiet)

echo "== neovim (server + search) =="
nvim --headless -u NONE -l "$here/run.lua" "$project"

echo "== browser js (jsdom) =="
if [ ! -d "$here/node-deps/node_modules/jsdom" ]; then
  mkdir -p "$here/node-deps" && (cd "$here/node-deps" && npm init -y >/dev/null && npm install --silent jsdom@24)
fi
node "$here/js-test.cjs" "$here/node-deps/node_modules" "$project" 2> >(grep -v 'Could not parse CSS' >&2)
