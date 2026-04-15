@AGENTS.md

# Working in this repo

This is a CWS (Christchurch Web Solutions) project. Read `AGENTS.md` for the database migration workflow — it's the most important thing to understand here.

## Quick orientation

- **Stack:** Next.js 15 (App Router, TypeScript, Tailwind 4) + self-hosted Supabase + Coolify auto-deploy via Dockerfile
- **Infra reference:** `/home/mark_harris/react/CWS-INFRASTRUCTURE.md` (read it if you need URLs, IPs, SSH commands, or to understand how deploys work)
- **Schema = code:** all DB changes go through `supabase/migrations/`. See `AGENTS.md` for the exact loop.
- **Per-project schema:** each project gets its own Postgres schema (e.g. `cortex`) within the shared `postgres` database. This gives us Supabase Studio visibility, `auth.uid()` for RLS, and access to realtime/storage. The schema name is in `DB_SCHEMA` in `.env.local`. Migrations auto-set `search_path` to the project schema.
- **Typed everywhere:** the Supabase client in `src/lib/supabase.ts` is typed via the generated `src/lib/database.types.ts`. Regenerate types after every migration with `./scripts/db-types.sh`.

## Skills available

- **frontend-design** (`.claude/skills/frontend-design/SKILL.md`) — invoke this whenever you're building UI. Don't ship generic AI-flavoured layouts. Pick a bold aesthetic direction and execute it cleanly.

## Default behaviours

- **Use the Supabase client from `src/lib/supabase.ts`** — don't create new clients inline.
- **Auth is intentionally NOT scaffolded.** When you need auth, follow the custom per-site pattern documented below under "Auth". Do not add Supabase Auth helpers.
- **For new pages**, use the App Router (`src/app/<route>/page.tsx`). Server Components by default; only mark `'use client'` when you need interactivity.
- **Tailwind 4** uses CSS-import config — no `tailwind.config.js`. Theme tokens go in `src/app/globals.css`.
- **Don't add a `pages/` directory.** App Router only.
- **Don't edit `database.types.ts` by hand** — always regenerate via `./scripts/db-types.sh`.
- **Don't commit `.env.local`** — it's gitignored and contains the Postgres password.
- **Don't remove or break the `Dockerfile` or `.dockerignore`** — Coolify uses the Dockerfile to build and deploy this app. `next.config.ts` must keep `output: "standalone"` for the Dockerfile to work. If you add new public assets or change the build, verify the Dockerfile still copies everything needed.

## When the user describes a feature that needs data

Default sequence:
1. Design the tables, columns, constraints, indexes, and RLS policies
2. Create a migration: `./scripts/db-new-migration.sh "describe the change"`
3. Write the SQL in the new migration file. The template already includes `SET search_path TO <schema>, public;` — your `CREATE TABLE`, `ALTER TABLE`, etc. land in the project schema automatically. For RLS policies, you can reference `auth.uid()` since we're in the shared `postgres` database with Supabase auth.
4. Apply: `./scripts/db-push.sh`
5. Regenerate types: `./scripts/db-types.sh`
6. Build the UI/API code using the new types
7. Commit migration + types + code together
8. Push to GitHub — Coolify auto-deploys

This way the deployed code never hits a database that doesn't yet have its tables.

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
- `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`

Ask Mark for the values via password manager.

## RLS policies across schemas

Tables live in the project schema but `auth.uid()` comes from the `auth` schema. This just works for basic RLS policies because `SET search_path TO <schema>, public;` includes `public` which has access to `auth.uid()`. But if you create RPC functions that need to access both project tables and auth, use `SECURITY DEFINER` with explicit `SET search_path = <schema>, extensions, public`.

## Next.js 16 gotchas (if upgrading)

- `middleware.ts` is renamed to `proxy.ts` (Edge Runtime)
- `NextResponse.redirect()` inside Docker uses internal hostname (`0.0.0.0:3000`) — use `x-forwarded-host` and `x-forwarded-proto` headers from Kong/Coolify to construct the correct public URL
- `useSearchParams()` now requires a `<Suspense>` boundary
