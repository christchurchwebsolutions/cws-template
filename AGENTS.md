<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

# CWS project conventions

This is a CWS (Christchurch Web Solutions) project: Next.js 15 (App Router, TypeScript, Tailwind) on top of self-hosted Supabase. Auto-deployed via Coolify on push to `main`.

Full infra reference: `/home/mark_harris/react/CWS-INFRASTRUCTURE.md`.

## Database changes — ALWAYS use migrations

**Never** make schema changes in the Supabase Studio UI. Schema lives in git, in `supabase/migrations/`. Each project uses its own **Postgres schema** (e.g. `cortex`) within the shared `postgres` database. The schema name is set via `DB_SCHEMA` in `.env.local`. The flow:

1. **Create a migration file**:
   ```bash
   ./scripts/db-new-migration.sh "short description"
   ```
   Creates `supabase/migrations/<timestamp>_<description>.sql` with `SET search_path TO <schema>, public;` already included.

2. **Write the SQL**. Include `CREATE TABLE` / `ALTER TABLE`, indexes, and Row Level Security (`ALTER TABLE foo ENABLE ROW LEVEL SECURITY;` plus policies). Since we're in the shared `postgres` database, you can use `auth.uid()` in RLS policies. Tables are created in the project schema automatically thanks to the `SET search_path`.

3. **Apply it to the live database**:
   ```bash
   ./scripts/db-push.sh
   ```
   SSHs to the Supabase server and runs the migration against the `postgres` database.

4. **Regenerate TypeScript types**:
   ```bash
   ./scripts/db-types.sh
   ```
   Writes `src/lib/database.types.ts` from the project schema. Use these types in the Supabase client:
   ```ts
   import type { Database } from '@/lib/database.types'
   import { createClient } from '@supabase/supabase-js'
   const supabase = createClient<Database>(url, key)
   ```

5. **Commit everything together** — migration SQL, regenerated types, and code that depends on them. Push to GitHub. Coolify auto-deploys. The migration is *already* live (you applied it in step 3) so the deployed code matches the database.

### Why this order?
Apply the migration **before** pushing code, so new code never hits a database without its tables. For destructive or schema-breaking migrations, talk to Mark first.

### Rolling back
No automatic rollback. If a migration is wrong, write a new "fix" migration that reverses it.

## Repo conventions

- Supabase client: `src/lib/supabase.ts` — use everywhere instead of creating new clients.
- Auth helpers: `src/lib/auth.ts` — sign in / sign up / sign out / get user already wired.
- App Router only — don't add a `pages/` directory.
- Env vars: copy `.env.example` → `.env.local` for local dev. `.env.local` is gitignored.

## Connection patterns

- **Browser code**: use `NEXT_PUBLIC_SUPABASE_URL` (the public HTTPS URL).
- **Server code**: same client works fine. For raw private-network access from a Coolify-deployed app, Kong is at `http://10.0.1.2:8000`.

## Don't

- Don't run schema commands directly with `psql` against the live DB unless you also write a migration capturing the change.
- Don't commit `.env.local` or any file matching `*credentials*`.
- Don't edit `src/lib/database.types.ts` by hand — always regenerate.

