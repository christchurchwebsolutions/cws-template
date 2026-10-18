import 'server-only'
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import type { Database } from './database.types'
import { dbSchema } from './db-schema'

/**
 * Server-only Supabase client with the service-role key. It bypasses RLS,
 * so it is the ONLY client that writes. Use it in Route Handlers, Server
 * Actions and Server Components, after your own auth/permission checks.
 *
 * Never import this from a 'use client' file: `server-only` makes the build
 * fail if you do. Browser and anon reads use `./supabase` instead.
 */
let admin: SupabaseClient<Database> | null = null

export function supabaseAdmin(): SupabaseClient<Database> {
  if (admin) return admin
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!url || !key) {
    throw new Error('NEXT_PUBLIC_SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not configured')
  }
  admin = createClient<Database>(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
    db: { schema: dbSchema() },
  })
  return admin
}
