import type { Database } from './database.types'

/** The project's Postgres schema, as named in the generated types (./scripts/db-types.sh). */
export type DbSchema = Exclude<keyof Database, '__InternalSupabase'> & string

/**
 * Every CWS project lives in its own schema in the shared database, and the
 * shared PostgREST lists `public` first, so a client without `db.schema`
 * silently queries `public`. NEXT_PUBLIC_DB_SCHEMA must equal DB_SCHEMA (the
 * one the db-*.sh scripts use). Read with a literal `process.env.NEXT_PUBLIC_…`
 * so Next.js inlines it into the browser bundle.
 */
export function dbSchema(): DbSchema {
  const schema = process.env.NEXT_PUBLIC_DB_SCHEMA
  if (!schema) {
    throw new Error(
      'NEXT_PUBLIC_DB_SCHEMA is not set. Add it to .env.local (and Coolify) with the same value as DB_SCHEMA.',
    )
  }
  return schema as DbSchema
}
