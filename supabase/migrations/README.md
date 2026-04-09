# Migrations

Each `.sql` file is one schema change, applied in filename order. Filenames are timestamped: `YYYYMMDDHHMMSS_short_description.sql`.

**Don't edit a migration after it's been pushed.** Once a migration has run against any environment, treat it as immutable — write a new migration to fix or amend it.

See `../../CLAUDE.md` for the full workflow.
