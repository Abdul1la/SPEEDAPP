#!/bin/bash
# ------------------------------------------------------------------
#  SPEED APP - one-click redeploy to Railway
#  Double-click this file in Finder (or run ./redeploy.command).
#
#  1. Saves your code to GitHub (asks before committing changes)
#  2. Redeploys the MySQL database service
#  3. Uploads this folder to Railway and rebuilds the API (SPEEDAPP)
#  4. Checks that the server answers /health
#
#  First run only: installs the Railway CLI and opens the browser
#  so you can sign in to Railway.
# ------------------------------------------------------------------

PROJECT_ID="69304f59-2314-4f56-9a9e-f519b056d90b"   # Railway project "SPEED APP"
ENVIRONMENT="production"
API_SERVICE="SPEEDAPP"
DB_SERVICE="MySQL"
REDEPLOY_DB="yes"          # set to "no" to rebuild only the API
API_URL="https://speedapp-production.up.railway.app"

cd "$(dirname "$0")" || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.railway/bin:$HOME/.npm-global/bin:$PATH"

step()  { echo; echo "==> $1"; }
pause() { echo; read -r -p "Press Enter to close..." _; }
fail()  { echo; echo "FAILED: $1"; pause; exit 1; }

echo "SPEED APP - redeploy everything to Railway"
echo "Folder: $(pwd)"

# --- 1. Railway CLI ------------------------------------------------
if ! command -v railway >/dev/null 2>&1; then
  step "Installing the Railway CLI (first time only)"
  if command -v brew >/dev/null 2>&1; then
    brew install railway || fail "Could not install the Railway CLI with Homebrew."
  elif command -v npm >/dev/null 2>&1; then
    npm install -g @railway/cli || fail "Could not install the Railway CLI with npm."
  else
    fail "Install the Railway CLI first:  brew install railway"
  fi
fi

if ! railway whoami >/dev/null 2>&1; then
  step "Sign in to Railway (first time only) - a browser window will open"
  railway login || fail "Railway sign-in did not finish."
fi

step "Linking this folder to the Railway project"
if ! railway link --project "$PROJECT_ID" --environment "$ENVIRONMENT" --service "$API_SERVICE" >/dev/null 2>&1; then
  echo "Pick: project 'SPEED APP', environment 'production', service 'SPEEDAPP'"
  railway link || fail "Could not link to the Railway project."
fi

# --- 2. GitHub -----------------------------------------------------
step "Saving code to GitHub"
if [ -n "$(git status --porcelain)" ]; then
  git status --short
  read -r -p "Commit these changes and push them to GitHub? [Y/n] " answer
  if [[ ! "$answer" =~ ^[Nn] ]]; then
    read -r -p "Commit message (Enter = automatic): " message
    git add -A && git commit -q -m "${message:-Update $(date '+%Y-%m-%d %H:%M')}" \
      || fail "git commit failed."
  fi
fi
if git push -q origin HEAD 2>&1; then
  echo "GitHub is up to date."
else
  echo "WARNING: push to GitHub failed - Railway will still get the code from this computer."
fi

# --- 3. Database ---------------------------------------------------
if [ "$REDEPLOY_DB" = "yes" ]; then
  step "Redeploying $DB_SERVICE"
  railway redeploy --project "$PROJECT_ID" --environment "$ENVIRONMENT" --service "$DB_SERVICE" --yes || fail "MySQL redeploy failed."
fi

# --- 4. API --------------------------------------------------------
step "Uploading code and rebuilding $API_SERVICE (build logs below)"
railway up --project "$PROJECT_ID" --service "$API_SERVICE" --environment "$ENVIRONMENT" --ci \
  --message "$(git log -1 --pretty=%s 2>/dev/null || echo redeploy)" \
  || fail "The API build failed - read the log above, or open the Railway dashboard."

# --- 5. Check ------------------------------------------------------
step "Waiting for the server to answer"
for i in $(seq 1 30); do
  if curl -fsS -m 5 "$API_URL/health" 2>/dev/null | grep -q '"ok":true'; then
    echo; echo "DONE - SPEED APP is live: $API_URL"
    echo "Admin panel: $API_URL/admin"
    pause; exit 0
  fi
  sleep 4
done
fail "The server did not answer $API_URL/health yet. Check Deploy Logs in Railway."
