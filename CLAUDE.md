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
- **Use the auth helpers from `src/lib/auth.ts`** for sign in/up/out.
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

## Auth — DO NOT use GoTrue emails

**This is a hard-won lesson from another CWS project.** If this project needs user authentication with email flows (signup confirmation, password reset, email verification):

**DO NOT rely on Supabase GoTrue's built-in email templates.** They are broken on self-hosted:
- Templates don't reliably load
- Confirmation links point at Studio URL instead of the app
- Templates are server-wide (can't brand per-project on shared Supabase)

**Instead, use this pattern:**
1. Set `AUTOCONFIRM=true` on GoTrue — signups are instant, no email confirmation step
2. Build custom email flows via self-hosted Postal (STARTTLS on port 587):
   - **Password reset:** custom API endpoint → HMAC-signed action token (with expiry) → branded email via Postal → callback endpoint verifies token → `supabase.auth.admin.updateUserById()` to set new password
   - **Signup welcome:** fire-and-forget branded email after signup
   - **Email verification** (for features like reminders): separate table with verification tokens — NOT for auth
3. Use React Email templates with a shared BaseLayout (light theme — Outlook desktop fights dark backgrounds)
4. HMAC-signed action tokens for stateless email verification

Talk to Mark before implementing auth — he has working reference code in the Cortex project.

## RLS policies across schemas

Tables live in the project schema but `auth.uid()` comes from the `auth` schema. This just works for basic RLS policies because `SET search_path TO <schema>, public;` includes `public` which has access to `auth.uid()`. But if you create RPC functions that need to access both project tables and auth, use `SECURITY DEFINER` with explicit `SET search_path = <schema>, extensions, public`.

## Next.js 16 gotchas (if upgrading)

- `middleware.ts` is renamed to `proxy.ts` (Edge Runtime)
- `NextResponse.redirect()` inside Docker uses internal hostname (`0.0.0.0:3000`) — use `x-forwarded-host` and `x-forwarded-proto` headers from Kong/Coolify to construct the correct public URL
- `useSearchParams()` now requires a `<Suspense>` boundary
