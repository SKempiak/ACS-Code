#!/usr/bin/env bash
# sync_data.sh — copy processed data into the report repository.
#
#   scripts/sync_data.sh [project ...]
#
# Copies <project>/data/processed/*.csv to ../ACS-Latex/<project>/data/, where
# the report's figures and tables read them with pgfplots. With no argument it
# syncs every project that has processed data.
set -euo pipefail

cd "$(dirname "$0")/.."            # ACS-Code
CODE_ROOT="$(pwd)"
LATEX_ROOT="$(cd ../ACS-Latex && pwd)"

projects=("$@")
if [ "${#projects[@]}" -eq 0 ]; then
  while IFS= read -r d; do projects+=("$d"); done < <(
    cd "$CODE_ROOT" && for p in */data/processed; do
      compgen -G "$p/*.csv" >/dev/null 2>&1 && echo "${p%%/*}"
    done
  )
fi

if [ "${#projects[@]}" -eq 0 ]; then
  echo "no processed data found; run an experiment first" >&2
  exit 1
fi

for p in "${projects[@]}"; do
  src="$CODE_ROOT/$p/data/processed"
  dst="$LATEX_ROOT/$p/data"
  if ! compgen -G "$src/*.csv" >/dev/null 2>&1; then
    echo "[$p] no CSVs in $src, skipping" >&2
    continue
  fi
  mkdir -p "$dst"
  cp -v "$src"/*.csv "$dst"/
done
