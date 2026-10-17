# ERP-Lite – Thapa Kurtha Corner sales app

Mobile-first sales, udharo (credit), customer and vendor tracking. Static website (no build step) + Supabase database.

```
index.html, sw.js, manifest.webmanifest, icon.svg   the app (served as-is)
database/migrations/                                database changes, oldest first
tests/                                              automatic tests (npm test)
.github/workflows/                                  ci.yml, db-migrate.yml, keepalive.yml
vercel.json, .vercelignore                          hosting settings
```

## How changes go live
1. Work on a branch, open a Pull Request. CI runs the tests. Vercel gives a private test link for the branch.
2. Try the test link on your phone. Merge to `main` only when CI is green.
3. Vercel deploys `main` to production automatically.
4. Wrong release? Vercel > Deployments > pick the last good one > Promote / Instant Rollback.

## Database changes
- Add a new file `database/migrations/<YYYYMMDDHHMMSS>_name.sql`. Never edit an old one.
- Back up first (app > Report > download both CSV files).
- Run the **Database migrate (manual)** workflow in the Actions tab. Approve it when asked.

## One-time setup
- Vercel: project thapa-kurtha-sales > Settings > Git > connect this repository (production branch `main`).
- GitHub secrets (Settings > Secrets and variables > Actions): `SUPABASE_ACCESS_TOKEN` (Supabase account > Access Tokens) and `SUPABASE_DB_PASSWORD` (Supabase project > Database settings; reset it there if you do not know it).
- GitHub: Settings > Environments > new `production` > Required reviewers = you.
- GitHub: Settings > Branches > protect `main` > require the CI check to pass.
- Supabase: Authentication settings > turn off new sign-ups after the owner account exists.

## Secrets
Only the *publishable* key is in the code (safe by design; the database rules protect the data). Never commit service-role keys, database passwords or tokens.
