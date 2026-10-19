@AGENTS.md

# Working in this repo

This is a CWS (Christchurch Web Solutions) project. Read `AGENTS.md` for the database migration workflow — it's the most important thing to understand here.

## Quick orientation

- **Stack:** Next.js 15 (App Router, TypeScript, Tailwind 4) + self-hosted Supabase + Coolify auto-deploy via Dockerfile
- **Infra reference:** `/home/mark_harris/react/CWS-INFRASTRUCTURE.md` (read it if you need URLs, IPs, SSH commands, or to understand how deploys work)
- **Schema = code:** all DB changes go through `supabase/migrations/`. See `AGENTS.md` for the exact loop.
- **Per-project schema:** each project gets its own Postgres schema (e.g. `cortex`) within the shared `postgres` database. This gives us Supabase Studio visibility, `auth.uid()` for RLS, and access to realtime/storage. The schema name is in `DB_SCHEMA` (used by the db scripts) and `NEXT_PUBLIC_DB_SCHEMA` (used by both Supabase clients via `src/lib/db-schema.ts`) in `.env.local` and Coolify (set `NEXT_PUBLIC_DB_SCHEMA` as a build-time variable, like the other `NEXT_PUBLIC_` keys, because Next.js inlines it at build). **The two must match.** Without `NEXT_PUBLIC_DB_SCHEMA` the clients throw at startup rather than silently querying `public`. Migrations auto-set `search_path` to the project schema.
- **Typed everywhere:** the Supabase client in `src/lib/supabase.ts` is typed via the generated `src/lib/database.types.ts`. Regenerate types after every migration with `./scripts/db-types.sh`.

## Skills available

- **frontend-design** (`.claude/skills/frontend-design/SKILL.md`) — invoke this whenever you're building UI. Don't ship generic AI-flavoured layouts. Pick a bold aesthetic direction and execute it cleanly.

## Default behaviours

- **Two Supabase clients, don't create new ones inline.** Browser and anon reads use `src/lib/supabase.ts` (anon key). Server writes use `supabaseAdmin()` from `src/lib/supabase-admin.ts` (service-role key, `import 'server-only'`, bypasses RLS) in Route Handlers, Server Actions and Server Components, after your own auth checks. Never import `supabase-admin.ts` from a `'use client'` file.
- **Auth is intentionally NOT scaffolded.** When you need auth, follow the custom per-site pattern documented below under "Auth". Do not add Supabase Auth helpers.
- **For new pages**, use the App Router (`src/app/<route>/page.tsx`). Server Components by default; only mark `'use client'` when you need interactivity.
- **Tailwind 4** uses CSS-import config — no `tailwind.config.js`. Theme tokens go in `src/app/globals.css`.
- **Don't add a `pages/` directory.** App Router only.
- **Don't edit `database.types.ts` by hand** — always regenerate via `./scripts/db-types.sh`.
- **Don't commit `.env.local`** — it's gitignored and contains the Postgres password and the service-role key. `.env.example` is tracked and lists every key: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_DB_SCHEMA` (browser), `SUPABASE_SERVICE_ROLE_KEY` (server only, never `NEXT_PUBLIC_`), `DB_SCHEMA` (must equal `NEXT_PUBLIC_DB_SCHEMA`), `POSTGRES_PASSWORD` (db scripts only).
- **Don't remove or break the `Dockerfile` or `.dockerignore`** — Coolify uses the Dockerfile to build and deploy this app. `next.config.ts` must keep `output: "standalone"` for the Dockerfile to work. If you add new public assets or change the build, verify the Dockerfile still copies everything needed.

## When the user describes a feature that needs data

Default sequence:
1. Design the tables, columns, constraints, indexes, RLS policies and browser grants (see "Browsers read, the server writes" below)
2. Create a migration: `./scripts/db-new-migration.sh "describe the change"`
3. Write the SQL in the new migration file. The template already includes `SET search_path TO <schema>, public;` — your `CREATE TABLE`, `ALTER TABLE`, etc. land in the project schema automatically. For RLS policies, you can reference `auth.uid()` since we're in the shared `postgres` database with Supabase auth.
4. Apply: `./scripts/db-push.sh`
5. Regenerate types: `./scripts/db-types.sh`
6. Build the UI/API code using the new types
7. Commit migration + types + code together
8. Push to GitHub — Coolify auto-deploys

This way the deployed code never hits a database that doesn't yet have its tables.

## Browsers read, the server writes (security rule)

Every CWS project shares one Supabase, one PostgREST and one JWT secret, so a logged-in token from ANY other CWS app (and the public anon key) is accepted against this project's schema too. A token with no `role` claim, such as a custom session cookie replayed as a Bearer token, runs as `anon` with `auth.uid()` set to its `sub`. Therefore:

- **Every new table:** `ALTER TABLE … ENABLE ROW LEVEL SECURITY;` in the same migration. No exceptions, including lookup tables.
- **Browser reads:** grant them explicitly, table by table, in the migration (`GRANT SELECT ON <schema>.<table> TO anon, authenticated;`), plus a `FOR SELECT` policy that shows only public rows. Use column-level `GRANT SELECT (col, …)` when a table has private columns. `db-push.sh` grants browsers nothing.
- **Writes:** only through the server with a service-role client (`SUPABASE_SERVICE_ROLE_KEY`, server-only code, never `NEXT_PUBLIC_`). Never add an INSERT/UPDATE/DELETE/ALL policy for `anon`, `authenticated` or `public`, and never `USING (true)` for anything but public reads.
- **Per-user policies** must key on this app's own users table (`auth.uid() = users.authUid`), never on the role alone (`TO authenticated USING (true)` is open to every CWS app's users).
- **Functions:** `SECURITY DEFINER` functions are `service_role` only (`REVOKE ALL ON FUNCTION … FROM PUBLIC, anon, authenticated; GRANT EXECUTE … TO service_role;`) unless the browser genuinely calls them and they're safe for any caller. Never let a browser-callable function take a user id as a parameter.
- **Views:** a view owned by `supabase_admin` runs with the owner's rights and bypasses RLS. Create every view `WITH (security_invoker = true)` (or `ALTER VIEW … SET (security_invoker = true)`), and grant it to browsers like a table.
- **`db-push.sh` fails loudly** if any table is left without RLS, a browser role holds a write grant, a browser policy allows writes, or a browser SELECT policy has no matching `GRANT SELECT` (reads broken).

### Existing projects adopting the new `db-push.sh`

The old script ran `GRANT ALL … TO anon, authenticated` on every push, so those grants are still there and the new script's check fails on the first push. Add a one-off migration before you push, listing the tables the browser really reads (check the code first: anything the browser writes must move behind a server route using `supabaseAdmin()`):

```sql
SET search_path TO <schema>, public;

BEGIN;
SET LOCAL lock_timeout = '5s';

-- RLS on for every table, including the migration ledger.
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT c.relname FROM pg_class c
           WHERE c.relnamespace = '<schema>'::regnamespace AND c.relkind IN ('r','p') AND NOT c.relrowsecurity
  LOOP
    EXECUTE format('ALTER TABLE <schema>.%I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- Revoke everything the old script granted, then give back only the reads.
REVOKE ALL ON ALL TABLES    IN SCHEMA <schema> FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA <schema> FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA <schema> REVOKE ALL ON TABLES    FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA <schema> REVOKE ALL ON SEQUENCES FROM anon, authenticated;
GRANT ALL ON ALL TABLES    IN SCHEMA <schema> TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA <schema> TO service_role;

GRANT SELECT ON <schema>.posts, <schema>.categories TO anon, authenticated;  -- only what the browser reads

-- Drop any browser write policy (INSERT/UPDATE/DELETE/ALL TO public, anon or authenticated)
-- and any role-only read policy (TO authenticated USING (true)) on private tables.
-- Also drop every SELECT policy on a table you did NOT grant back above, or db-push
-- step 7 ("READS BROKEN") fails: a browser policy with no grant means a broken read.
-- DROP POLICY IF EXISTS <name> ON <schema>.<table>;

COMMIT;
```

Functions: Postgres lets PUBLIC run every new function, and a per-schema default can't change that. In the same migration, run `REVOKE ALL ON FUNCTION <schema>.<fn>(<args>) FROM PUBLIC, anon, authenticated; GRANT EXECUTE ON FUNCTION <schema>.<fn>(<args>) TO service_role;` for each function. db-push step 6 fails if a SECURITY DEFINER function is still runnable by a browser role. The exception is an RLS helper that your browser SELECT policies call (for example `current_user_id()`): leave it runnable by `authenticated` and add its name to `BROWSER_DEFINER_ALLOW` at the top of `scripts/db-push.sh`.

Worked examples: `stopaids-site` `20261018125836_*.sql`, `naughty-nights-out` `20261018134026_*.sql`, `hearth` `20261018190000_*.sql` (RLS helpers on the allow list).

## Auth — use custom per-site auth, NOT Supabase Auth

**Hard-won lesson — do NOT use shared Supabase Auth for end users.**

The self-hosted Supabase instance's `auth.users` table is **shared cluster-wide** across every CWS project. Using it for a customer-facing site means:
- A password change on one site affects every other site the user is on
- Email collisions between projects (a new signup fails if the email is used elsewhere)
- GoTrue's built-in email templates don't work on self-hosted (templates don't load, confirmation links point at Studio, can't brand per-project)

**Use custom per-site bcrypt + JWT cookies instead.** Reference implementation: `github.com/christchurchwebsolutions/naughty-nights-out` (public repo). Read:

- `supabase/migrations/20260414164809_switch_users_to_custom_auth_with_rls.sql` — schema (add `passwordHash` + `authUid`, enable RLS)
- `server/_core/auth.ts` — bcrypt, session JWT, PostgREST JWT for RLS
- `server/_core/supabase.ts` — `sbAdmin()` bypasses RLS; `sbAsUser(user)` applies RLS
- `server/_core/context.ts` — reads the session cookie, loads the user
- `server/routers.ts` → `auth` router — `signUp` / `signIn` / `signOut` tRPC mutations
- `client/src/pages/Login.tsx` — sign-in / sign-up form

Architecture summary:
- **Passwords:** bcrypt cost 12
- **Session:** httpOnly cookie carrying a JWT signed with `JWT_SECRET` (same secret PostgREST validates against)
- **RLS defense-in-depth:** policies key on `auth.uid() = users.authUid`. When you want RLS to apply, use `sbAsUser(ctx.user)` (generates a short-lived PostgREST JWT with sub=authUid). `sbAdmin()` uses the service_role key and bypasses RLS.

### Password reset / welcome emails

Use self-hosted Postal + HMAC-signed action tokens (not GoTrue emails — they're broken on self-hosted). Patterns to be filled in when Postal is deployed on the cluster.

### Required env vars when you add auth

- `JWT_SECRET` — **must match the supabase server's `JWT_SECRET`** so PostgREST validates our JWTs
- `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (the last is already in `.env.example` for writes)

Ask Mark for the values via password manager.

## RLS policies across schemas

Tables live in the project schema but `auth.uid()` comes from the `auth` schema. This just works for basic RLS policies because `SET search_path TO <schema>, public;` includes `public` which has access to `auth.uid()`. But if you create RPC functions that need to access both project tables and auth, use `SECURITY DEFINER` with explicit `SET search_path = <schema>, extensions, public`.

## Next.js 16 gotchas (if upgrading)

- `middleware.ts` is renamed to `proxy.ts` (Edge Runtime)
- `NextResponse.redirect()` inside Docker uses internal hostname (`0.0.0.0:3000`) — use `x-forwarded-host` and `x-forwarded-proto` headers from Kong/Coolify to construct the correct public URL
- `useSearchParams()` now requires a `<Suspense>` boundary
