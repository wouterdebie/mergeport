#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

ACCOUNT="${GCLOUD_ACCOUNT:?Set GCLOUD_ACCOUNT to an account with access to wouterdebie-personal}"
GCLOUD=(gcloud --project=wouterdebie-personal --account="$ACCOUNT" --quiet)
BUCKET=gs://mergeport-app-site
test -s index.html
test -d assets

# Upload only public web assets, never infrastructure, scripts, or local files.
# Keep old assets so visitors with cached HTML are not broken during a deploy.
"${GCLOUD[@]}" storage rsync assets "$BUCKET/assets" --recursive \
    --cache-control='public,max-age=86400'
"${GCLOUD[@]}" storage cp assets/style.css "$BUCKET/assets/style.css" \
    --content-type='text/css; charset=utf-8' --cache-control='no-cache'
"${GCLOUD[@]}" storage cp index.html "$BUCKET/index.html" \
    --content-type='text/html; charset=utf-8' --cache-control='no-cache'
printf 'Deployed public assets to %s\nWebsite: https://mergeport.app\n' "$BUCKET"
