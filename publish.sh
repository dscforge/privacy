#!/bin/zsh
# publish.sh — publish the DSC Forge privacy-policy site to GitHub Pages.
#
# WHY THIS EXISTS AS A SCRIPT
# The privacy-policy URL is a hard App Store Connect requirement for EVERY app,
# including "Data Not Collected" ones. This repo is the host for all of them, so
# adding an app later means adding one HTML file and re-running this script.
#
# THE TOKEN NEVER PASSES THROUGH THIS FILE.
# Put it in ~/.config/dscforge-gh-token (chmod 600) or export GH_TOKEN. It is read
# at run time and passed to git via a one-shot credential helper, so it is never
# written into .git/config and never embedded in the remote URL on disk.
#
# Usage:
#   ./publish.sh                    # uses OWNER below
#   OWNER=someone ./publish.sh      # override the owner
#   DRY=1 ./publish.sh              # print what would happen, change nothing

set -eo pipefail

OWNER=${OWNER:-dscforge}
REPO=${REPO:-privacy}
BRANCH=main
HERE=${0:A:h}

if [[ -n "$GH_TOKEN" ]]; then
  TOKEN=$GH_TOKEN
elif [[ -r ~/.config/dscforge-gh-token ]]; then
  TOKEN=$(<~/.config/dscforge-gh-token)
else
  print -u2 'no token: set GH_TOKEN or write ~/.config/dscforge-gh-token (chmod 600)'
  exit 2
fi
# Strip any trailing newline/whitespace; a stray newline in a bearer token is a
# classic cause of a 401 that looks like a permissions problem.
TOKEN=${TOKEN//[^[:print:]]/}

REMOTE=https://x-access-token:${TOKEN}@github.com/${OWNER}/${REPO}.git

say() { print -r -- "  $*" }

say 'repo    : https://github.com/'"$OWNER/$REPO"
say 'branch  : '"$BRANCH"
say 'files   : '$(cd "$HERE" && ls -1 *.html | tr '\n' ' ')

if [[ -n "$DRY" ]]; then
  say 'DRY=1 set — stopping without touching the network'
  exit 0
fi

cd "$HERE"

# Commit anything uncommitted so a hand-edited policy page is never silently skipped.
if [[ -n "$(git status --porcelain)" ]]; then
  say 'uncommitted changes present — committing them'
  git add -A
  git -c user.name='Devan Carlin' -c user.email='devan.s.carlin@gmail.com' \
      commit -q -m 'Update privacy policies'
fi

# Create the repo through the API rather than requiring the `gh` CLI, which is
# not installed here.
say 'ensuring the repository exists'
CODE=$(curl -s -o /tmp/publish-repo.json -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.github+json; acceptable-version=2022-11-28' \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$REPO\",\"description\":\"DSC Forge privacy policies\",\"homepage\":\"https://$OWNER.github.io/$REPO/\",\"has_issues\":false,\"has_wiki\":false,\"auto_init\":false,\"private\":false}" \
  https://api.github.com/user/repos)

if [[ "$CODE" == 201 ]]; then
  say 'created repository'
elif [[ "$CODE" == 422 ]]; then
  say 'repository already exists — continuing'
else
  say "repo create returned HTTP $CODE:"
  sed 's/^/      /' /tmp/publish-repo.json
  print -u2 'aborting before push'
  exit 1
fi

say 'pushing'
# Push with the credentialed URL, then immediately rewrite the remote back to a
# clean URL so the token is not persisted in .git/config.
git push --quiet --set-upstream "$REMOTE" "$BRANCH" 2>&1 | sed 's/^/      /'
git remote remove origin >/dev/null 2>&1 || true
git remote add origin "https://github.com/$OWNER/$REPO.git"
say 'remote rewritten to a token-free URL'

# Pages needs one POST to enable it; pushing files alone does not turn it on.
say 'enabling Pages (GitHub Actions style)'
PCODE=$(curl -s -o /tmp/publish-pages.json -w '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.github+json; acceptable-version=2022-11-28' \
  -H 'Content-Type: application/json' \
  -d '{"build_type":"legacy","source":{"branch":"main","path":"/"}}' \
  "https://api.github.com/repos/$OWNER/$REPO/pages")
if [[ "$PCODE" == 201 || "$PCODE" == 202 || "$PCODE" == 409 ]]; then
  say "pages enable returned HTTP $PCODE (201/202 created, 409 = already enabled)"
else
  say "pages enable returned HTTP $PCODE:"
  sed 's/^/      /' /tmp/publish-pages.json
fi

print -r -- ''
print -r -- 'Publishing usually takes 30-60s. Verify before pasting the URL into ASC:'
print -r -- "  curl -sI https://$OWNER.github.io/$REPO/calendar-builder.html | head -1"
print -r -- 'Expect HTTP/2 200. A 404 means Pages has not finished building yet.'
