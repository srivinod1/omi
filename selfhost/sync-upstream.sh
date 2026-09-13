#!/usr/bin/env bash
# Pull the latest changes from BasedHardware/omi (upstream) into this fork
# without losing your own changes.
#
# Branch model:
#   main    -> pristine mirror of upstream/main. Never commit here directly.
#   custom  -> your changes, based on main. This is what gets deployed.
#
# Usage: selfhost/sync-upstream.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "Adding upstream remote (BasedHardware/omi)..."
  git remote add upstream https://github.com/BasedHardware/omi.git
fi

echo "==> Fetching upstream..."
git fetch upstream --prune

echo "==> Fast-forwarding main to upstream/main..."
git checkout main
git merge --ff-only upstream/main
git push origin main

echo "==> Merging main into custom..."
git checkout custom
if git merge main --no-edit; then
  echo "==> Merge clean. Pushing custom..."
  git push origin custom
  echo ""
  echo "Done. Push to 'custom' triggers the deploy workflow"
  echo "(.github/workflows/selfhost-deploy.yml) if you're using GitHub Actions CI/CD."
else
  echo ""
  echo "!! Merge conflict. Resolve the conflicts above, then:"
  echo "     git add <files>"
  echo "     git commit"
  echo "     git push origin custom"
fi
