import { createClient } from '@supabase/supabase-js'
import type { Database } from './database.types'
import { dbSchema } from './db-schema'

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!

// Browser and anon reads. Queries go to this project's schema, not `public`.
export const supabase = createClient<Database>(supabaseUrl, supabaseAnonKey, {
  db: { schema: dbSchema() },
})
