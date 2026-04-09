@AGENTS.md

# Working in this repo

This is a CWS (Christchurch Web Solutions) project. Read `AGENTS.md` for the database migration workflow — it's the most important thing to understand here.

## Quick orientation

- **Stack:** Next.js 15 (App Router, TypeScript, Tailwind 4) + self-hosted Supabase + Coolify auto-deploy
- **Infra reference:** `/home/mark_harris/react/CWS-INFRASTRUCTURE.md` (read it if you need URLs, IPs, SSH commands, or to understand how deploys work)
- **Schema = code:** all DB changes go through `supabase/migrations/`. See `AGENTS.md` for the exact loop.
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

## When the user describes a feature that needs data

Default sequence:
1. Design the schema (tables, columns, constraints, indexes, RLS policies)
2. Create a migration: `./scripts/db-new-migration.sh "describe the change"`
3. Write the SQL in the new migration file
4. Apply: `./scripts/db-push.sh`
5. Regenerate types: `./scripts/db-types.sh`
6. Build the UI/API code using the new types
7. Commit migration + types + code together
8. The user pushes via GitHub Desktop — Coolify auto-deploys

This way the deployed code never hits a database that doesn't yet have its tables.
