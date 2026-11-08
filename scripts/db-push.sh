#!/usr/bin/env bash
# Apply pending Supabase migrations to the live database.
#
# Each migration in supabase/migrations/*.sql is applied in filename order.
# Applied migrations are tracked in a table called `_cws_migrations` inside
# the project's schema within the `postgres` database.
#
# Usage:  ./scripts/db-push.sh
# Reads:  .env.local  (DB_SCHEMA, SUPABASE_HOST)

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env.local ]]; then
  echo "ERROR: .env.local not found. Copy .env.example -> .env.local and fill it in."
  exit 1
fi

# shellcheck disable=SC1091
source .env.local

: "${SUPABASE_HOST:=root@91.99.87.214}"
: "${SUPABASE_DB_USER:=supabase_admin}"
: "${SUPABASE_DB_CONTAINER:=supabase-db}"
: "${DB_SCHEMA:?Set DB_SCHEMA in .env.local (e.g. DB_SCHEMA=cortex)}"

# Functions that browser roles (anon, authenticated) may run, by name, space
# separated: RLS helpers the browser policies call and RPCs the browser or
# sbAsUser() really calls. Each must be safe for a signed-in user of ANY CWS
# app (never take a user id as a parameter). The migration that adds one
# grants EXECUTE to the exact role itself; db-push leaves a listed function's
# grants alone. A name covers every overload. Every other function is
# service_role only: step 5 takes away PUBLIC's default EXECUTE and step 7
# fails the push if anon or authenticated can still run it.
# (Was BROWSER_DEFINER_ALLOW, which covered SECURITY DEFINER functions only.)
BROWSER_FUNCTION_ALLOW=""

if [[ ! "${BROWSER_FUNCTION_ALLOW}" =~ ^[a-z0-9_\ ]*$ ]]; then
  echo "ERROR: BROWSER_FUNCTION_ALLOW must be lower-case function names separated by spaces." >&2
  exit 1
fi

PSQL_CMD="docker exec -i ${SUPABASE_DB_CONTAINER} psql -U ${SUPABASE_DB_USER} -d postgres -v ON_ERROR_STOP=1"

# SQL shared by steps 5, 7 and 8 (alias p = pg_proc).
# Functions this script manages: the project schema's own functions and
# procedures, not ones an extension installed there (CREATE EXTENSION with the
# schema on search_path); those belong to the extension and other schemas'
# tables may use them.
FN_OURS="p.pronamespace = '${DB_SCHEMA}'::regnamespace AND p.prokind IN ('f', 'p')
  AND NOT EXISTS (SELECT 1 FROM pg_depend e WHERE e.classid = 'pg_proc'::regclass
                  AND e.objid = p.oid AND e.deptype = 'e')"
# ...that can be called (trigger functions can't be called directly).
FN_CALLABLE="p.prorettype NOT IN ('trigger'::regtype, 'event_trigger'::regtype)"
FN_NOT_ALLOWED="p.proname <> ALL (string_to_array('${BROWSER_FUNCTION_ALLOW}', ' '))"
# Functions a browser role needs EXECUTE on to read: ones a SELECT (or ALL)
# policy calls, on a table that role can SELECT, and ones a view that role can
# SELECT calls (Postgres checks EXECUTE as the reader in both). Columns: fn,
# role, via.
BROWSER_FN_USES="
  SELECT d.refobjid AS fn, r.role, c.oid::regclass::text || ' policy ' || quote_ident(pol.polname) AS via
    FROM pg_depend d
    JOIN pg_policy pol ON d.classid = 'pg_policy'::regclass AND pol.oid = d.objid
    JOIN pg_class c ON c.oid = pol.polrelid
   CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(role)
   WHERE d.refclassid = 'pg_proc'::regclass AND pol.polcmd IN ('r', '*')
     AND (0::oid = ANY (pol.polroles) OR r.role::regrole::oid = ANY (pol.polroles))
     AND has_any_column_privilege(r.role, c.oid, 'SELECT')
  UNION ALL
  SELECT d.refobjid, r.role, v.oid::regclass::text || ' view'
    FROM pg_depend d
    JOIN pg_rewrite rw ON d.classid = 'pg_rewrite'::regclass AND rw.oid = d.objid
    JOIN pg_class v ON v.oid = rw.ev_class AND v.relkind = 'v'
   CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(role)
   WHERE d.refclassid = 'pg_proc'::regclass
     AND has_any_column_privilege(r.role, v.oid, 'SELECT')"
# BROWSER_FN_USES, plus allow-listed functions, plus (repeatedly) any function
# of ours whose name appears in the body of a SECURITY INVOKER one already in
# the set: an invoker function runs the functions it calls as the browser,
# and Postgres doesn't record calls made inside a body. Matching by name can
# include too much, never too little; anything included that browsers can
# run makes step 7 fail, so it is a loud failure, never a broken read.
# Columns: fn, role, via.
BROWSER_FN_NEEDED="
  WITH RECURSIVE needed(fn, role, via) AS (
    SELECT u.fn, u.role, u.via FROM (${BROWSER_FN_USES}) u
    UNION
    SELECT p.oid, r.role, 'BROWSER_FUNCTION_ALLOW' FROM pg_proc p
     CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(role)
     WHERE ${FN_OURS} AND NOT (${FN_NOT_ALLOWED}) AND has_function_privilege(r.role, p.oid, 'EXECUTE')
    UNION
    SELECT callee.oid, n.role, 'the body of ' || caller.oid::regprocedure::text
      FROM needed n
      JOIN pg_proc caller ON caller.oid = n.fn AND NOT caller.prosecdef
      JOIN pg_proc callee ON callee.pronamespace = '${DB_SCHEMA}'::regnamespace AND callee.oid <> caller.oid
                         AND caller.prosrc ~* ('\\m' || callee.proname || '\\M')
  )
  SELECT fn, role, via FROM needed"

# Postgres gives PUBLIC (so anon, and any CWS app's signed-in token, through
# PostgREST /rpc) EXECUTE on every new function, and a per-schema default
# can't remove that. So after each migration: give service_role EXECUTE on
# every function, and take PUBLIC's EXECUTE away from each one that isn't on
# BROWSER_FUNCTION_ALLOW. A function a browser read or a listed function
# needs (BROWSER_FN_NEEDED) is left as it is, so this never breaks one; step 7
# then fails the push until it's listed or revoked. Explicit grants to anon or authenticated are left
# for step 7 too: they're someone's decision, so the push fails rather than
# silently undoing them.
lock_down_functions() {
  ssh "${SUPABASE_HOST}" "${PSQL_CMD}" <<EOSQL >/dev/null
DO \$lock\$
DECLARE f regprocedure;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure FROM pg_proc p
     WHERE ${FN_OURS} AND ${FN_CALLABLE}
       AND NOT EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                        WHERE a.grantee = 'service_role'::regrole AND a.privilege_type = 'EXECUTE')
  LOOP
    EXECUTE format('GRANT EXECUTE ON ROUTINE %s TO service_role', f);
  END LOOP;
  FOR f IN
    SELECT p.oid::regprocedure FROM pg_proc p
     WHERE ${FN_OURS} AND ${FN_CALLABLE} AND ${FN_NOT_ALLOWED}
       AND NOT EXISTS (SELECT 1 FROM (${BROWSER_FN_NEEDED}) u WHERE u.fn = p.oid)
       AND EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                    WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON ROUTINE %s FROM PUBLIC', f);
  END LOOP;
END
\$lock\$;
EOSQL
}

# 1. Ensure the project schema exists and Supabase roles can access it.
echo "Ensuring schema '${DB_SCHEMA}' exists in postgres..."
ssh "${SUPABASE_HOST}" "${PSQL_CMD}" <<EOSQL >/dev/null
CREATE SCHEMA IF NOT EXISTS ${DB_SCHEMA};
GRANT USAGE ON SCHEMA ${DB_SCHEMA} TO anon, authenticated, service_role;
-- Browsers read, the server writes. The server uses service_role (bypasses
-- RLS). Browser roles (anon, authenticated) get NOTHING here: a migration
-- that adds a browser-readable table grants the exact SELECT itself
-- (GRANT SELECT ON <table> TO anon, authenticated) with an RLS policy.
-- Never grant table privileges to browser roles in this script: it runs on
-- every push and would undo column-level grants and revokes. Every CWS app
-- shares one JWT secret, so an authenticated token from ANY other CWS app
-- is accepted here too.
GRANT ALL ON ALL TABLES IN SCHEMA ${DB_SCHEMA} TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA ${DB_SCHEMA} TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA ${DB_SCHEMA} REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA ${DB_SCHEMA} REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA ${DB_SCHEMA} GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA ${DB_SCHEMA} GRANT ALL ON SEQUENCES TO service_role;
-- Functions start service_role only. These drop any per-schema browser
-- default; PUBLIC's global default can't be removed per schema (it only
-- could for the whole cluster), so lock_down_functions revokes it.
ALTER DEFAULT PRIVILEGES IN SCHEMA ${DB_SCHEMA} REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA ${DB_SCHEMA} GRANT EXECUTE ON FUNCTIONS TO service_role;
EOSQL

# 2. Ensure migration tracking table exists in the project schema.
echo "Ensuring ${DB_SCHEMA}._cws_migrations table exists..."
ssh "${SUPABASE_HOST}" "${PSQL_CMD} -c \"CREATE TABLE IF NOT EXISTS ${DB_SCHEMA}._cws_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now()); ALTER TABLE ${DB_SCHEMA}._cws_migrations ENABLE ROW LEVEL SECURITY; REVOKE ALL ON ${DB_SCHEMA}._cws_migrations FROM anon, authenticated;\"" >/dev/null

# 3. Get list of already-applied migrations.
APPLIED=$(ssh "${SUPABASE_HOST}" "${PSQL_CMD} -At -c \"SELECT name FROM ${DB_SCHEMA}._cws_migrations ORDER BY name;\"")

# 4. Walk migrations in order, apply any that are missing. Functions are
#    locked down straight after each one, so a later migration failing
#    can't leave an earlier one's functions open.
shopt -s nullglob
APPLIED_COUNT=0
for f in supabase/migrations/*.sql; do
  base=$(basename "$f")
  if grep -qx "$base" <<<"$APPLIED"; then
    echo "  - already applied:  $base"
    continue
  fi
  echo "  + applying:         $base"
  ssh "${SUPABASE_HOST}" "${PSQL_CMD}" < "$f"
  ssh "${SUPABASE_HOST}" "${PSQL_CMD} -c \"INSERT INTO ${DB_SCHEMA}._cws_migrations (name) VALUES ('$base');\"" >/dev/null
  lock_down_functions
  APPLIED_COUNT=$((APPLIED_COUNT + 1))
done

# 5. Lock down functions on every push, migrations or not, so an allow-list
#    change or a project adopting this script is put right.
echo "Locking down functions in '${DB_SCHEMA}'..."
lock_down_functions

# 6. Fail loudly if any table is left open to browsers: RLS off, a browser
#    role holding a write grant, or a browser policy that allows writes.
OPEN=$(ssh "${SUPABASE_HOST}" "${PSQL_CMD} -At" <<EOSQL
SELECT string_agg(DISTINCT x, ', ') FROM (
  SELECT c.relname || ' (no RLS)' AS x FROM pg_class c
   WHERE c.relnamespace = '${DB_SCHEMA}'::regnamespace AND c.relkind IN ('r','p') AND NOT c.relrowsecurity
  UNION ALL
  SELECT c.relname || ' (' || r.role || ' write grant)' FROM pg_class c
   CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(role)
   WHERE c.relnamespace = '${DB_SCHEMA}'::regnamespace AND c.relkind IN ('r','p','v','m')
     AND (has_table_privilege(r.role, c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
          OR has_any_column_privilege(r.role, c.oid, 'INSERT,UPDATE,REFERENCES'))
  UNION ALL
  SELECT tablename || '.' || policyname || ' (browser write policy)' FROM pg_policies
   WHERE schemaname = '${DB_SCHEMA}' AND permissive = 'PERMISSIVE' AND cmd <> 'SELECT'
     AND roles && ARRAY['public','anon','authenticated']::name[]
     AND NOT (coalesce(qual,'false') = 'false' AND coalesce(with_check,'false') = 'false')
) s;
EOSQL
)
if [ -n "${OPEN}" ]; then
  echo "SECURITY: tables open to browsers in '${DB_SCHEMA}': ${OPEN}" >&2
  echo "Fix with a migration: ALTER TABLE ... ENABLE ROW LEVEL SECURITY; REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ... FROM anon, authenticated; drop the write policy (the server writes with service_role)." >&2
  echo "First push after adopting this script? See CLAUDE.md, \"Existing projects adopting the new db-push.sh\"." >&2
  exit 1
fi

# 7. Fail loudly if a function is open: runnable by anon or authenticated
#    without being on BROWSER_FUNCTION_ALLOW, or SECURITY DEFINER (listed or
#    not, trigger or not) without a fixed search_path, which lets the caller's
#    search_path pick the tables and functions it runs with the owner's
#    rights.
OPEN_FN=$(ssh "${SUPABASE_HOST}" "${PSQL_CMD} -At" <<EOSQL
SELECT string_agg(x, '; ' ORDER BY x) FROM (
  SELECT p.oid::regprocedure::text || ' (runnable by ' || string_agg(r.role, ' and ' ORDER BY r.role)
         || coalesce(', needed by ' || (SELECT string_agg(DISTINCT u.via, ', ')
                                          FROM (${BROWSER_FN_NEEDED}) u WHERE u.fn = p.oid), '')
         || ')' AS x
    FROM pg_proc p
   CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(role)
   WHERE ${FN_OURS} AND ${FN_CALLABLE} AND ${FN_NOT_ALLOWED}
     AND has_function_privilege(r.role, p.oid, 'EXECUTE')
   GROUP BY p.oid
  UNION ALL
  SELECT p.oid::regprocedure::text || ' (SECURITY DEFINER without SET search_path)'
    FROM pg_proc p
   WHERE ${FN_OURS} AND p.prosecdef
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) cfg WHERE cfg LIKE 'search_path=%')
) s;
EOSQL
)
if [ -n "${OPEN_FN}" ]; then
  echo "SECURITY: functions open in '${DB_SCHEMA}': ${OPEN_FN}" >&2
  echo "Fix with a migration: REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon, authenticated; GRANT EXECUTE ON FUNCTION ... TO service_role;  and give every SECURITY DEFINER function SET search_path = ${DB_SCHEMA}, pg_temp (ALTER FUNCTION ... SET search_path = ...)." >&2
  echo "Only if the browser really calls it (an RLS helper a browser policy uses, or an RPC that acts only as auth.uid()): add its name to BROWSER_FUNCTION_ALLOW in scripts/db-push.sh and GRANT EXECUTE to just the role that needs it." >&2
  exit 1
fi

STALE_ALLOW=$(ssh "${SUPABASE_HOST}" "${PSQL_CMD} -At" <<EOSQL
SELECT string_agg(n, ' ') FROM unnest(string_to_array('${BROWSER_FUNCTION_ALLOW}', ' ')) AS n
 WHERE n <> '' AND NOT EXISTS (SELECT 1 FROM pg_proc p WHERE ${FN_OURS} AND p.proname = n);
EOSQL
)
if [ -n "${STALE_ALLOW}" ]; then
  echo "WARNING: BROWSER_FUNCTION_ALLOW names no function in '${DB_SCHEMA}': ${STALE_ALLOW} (remove them, or a function created later under that name is browser-callable unreviewed)." >&2
fi

# 8. Fail loudly if reads are broken: a browser SELECT policy with no
#    matching grant, or a browser read that calls a function its role can't
#    run. TO anon needs SELECT for anon, TO authenticated needs it for
#    authenticated, TO public (no TO clause) needs it for at least one.
#    New tables and functions get no browser grants by default, so the
#    migration that adds the policy must also GRANT SELECT (and EXECUTE on
#    any helper it calls, which also goes on BROWSER_FUNCTION_ALLOW).
UNGRANTED=$(ssh "${SUPABASE_HOST}" "${PSQL_CMD} -At" <<EOSQL
SELECT string_agg(x, '; ' ORDER BY x) FROM (
  SELECT DISTINCT c.relname || '.' || pol.polname AS x
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
   WHERE c.relnamespace = '${DB_SCHEMA}'::regnamespace
     AND pol.polpermissive AND pol.polcmd IN ('r','*')
     AND coalesce(pg_get_expr(pol.polqual, pol.polrelid), 'true') <> 'false'
     AND (('anon'::regrole::oid = ANY (pol.polroles) AND NOT has_any_column_privilege('anon', c.oid, 'SELECT'))
       OR ('authenticated'::regrole::oid = ANY (pol.polroles) AND NOT has_any_column_privilege('authenticated', c.oid, 'SELECT'))
       OR (0::oid = ANY (pol.polroles) AND NOT has_any_column_privilege('anon', c.oid, 'SELECT')
                                       AND NOT has_any_column_privilege('authenticated', c.oid, 'SELECT')))
  UNION
  SELECT u.via || ' calls ' || p.oid::regprocedure::text || ', which ' || u.role || ' cannot run'
    FROM (${BROWSER_FN_USES}) u
    JOIN pg_proc p ON p.oid = u.fn
   WHERE ${FN_OURS} AND NOT has_function_privilege(u.role, p.oid, 'EXECUTE')
) s;
EOSQL
)
if [ -n "${UNGRANTED}" ]; then
  echo "READS BROKEN: '${DB_SCHEMA}' browser reads that will fail: ${UNGRANTED}" >&2
  echo "Fix with a migration: GRANT SELECT ON <table> TO anon, authenticated;  (or TO the role the policy names; drop the policy if browsers shouldn't read it). For a function: GRANT EXECUTE ON FUNCTION ... TO <role>; and add it to BROWSER_FUNCTION_ALLOW." >&2
  exit 1
fi

# A browser-callable SECURITY INVOKER function whose body names a function of
# ours its role can't run. Matched by name, so it may be a column or a word in
# a comment: a warning, not a failure.
MAYBE_BROKEN=$(ssh "${SUPABASE_HOST}" "${PSQL_CMD} -At" <<EOSQL
SELECT string_agg(DISTINCT n.via || ' mentions ' || p.oid::regprocedure::text || ', which ' || n.role || ' cannot run', '; ')
  FROM (${BROWSER_FN_NEEDED}) n
  JOIN pg_proc p ON p.oid = n.fn
 WHERE n.via LIKE 'the body of %' AND ${FN_OURS} AND ${FN_CALLABLE}
   AND NOT has_function_privilege(n.role, p.oid, 'EXECUTE');
EOSQL
)
if [ -n "${MAYBE_BROKEN}" ]; then
  echo "WARNING: '${DB_SCHEMA}' browser calls that may fail: ${MAYBE_BROKEN}. If it really calls it, GRANT EXECUTE on it to that role and add it to BROWSER_FUNCTION_ALLOW." >&2
fi

echo "Done. ${APPLIED_COUNT} new migration(s) applied to schema '${DB_SCHEMA}'."
