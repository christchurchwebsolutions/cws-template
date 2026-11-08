// Static guard for function privileges in supabase/migrations. Run: npm test
//
// Every CWS app shares one PostgREST and one JWT secret, so anon (and the
// signed-in users of EVERY CWS app, as authenticated) can call any function
// in this schema they hold EXECUTE on, through /rest/v1/rpc. db-push.sh
// revokes PUBLIC's default EXECUTE after each migration and fails the push
// if a function is still open; this test catches the same mistakes before
// anything reaches the database:
//   * a migration grants EXECUTE on a function to anon, authenticated or
//     public that isn't on BROWSER_FUNCTION_ALLOW in scripts/db-push.sh;
//   * a migration grants EXECUTE on ALL functions in a schema, or a default
//     privilege on functions, to a browser role;
//   * a SECURITY DEFINER function, as the migrations leave it, has no
//     SET search_path;
//   * a name on BROWSER_FUNCTION_ALLOW matches no function the migrations
//     create (a stale entry would let a future function of that name through);
//   * a dollar-quoted block (DO, EXECUTE format) grants EXECUTE to a browser
//     role, which this guard can't read: write the GRANT as a plain statement.
// Overloads are tracked by name, and the live check in db-push.sh is the
// final word; this one exists to fail early, on your machine.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const MIGRATIONS = path.join(ROOT, "supabase/migrations");
const BROWSER_ROLES = new Set(["anon", "authenticated", "public"]);

/** The allow-list from scripts/db-push.sh (single source of truth). */
export function readAllowList(script = readFileSync(path.join(ROOT, "scripts/db-push.sh"), "utf8")) {
  const m = script.match(/^BROWSER_FUNCTION_ALLOW="([^"]*)"/m);
  if (!m) throw new Error("scripts/db-push.sh has no BROWSER_FUNCTION_ALLOW=\"...\" line");
  return m[1].split(/\s+/).filter(Boolean);
}

/**
 * Split SQL into statements, dropping comments and replacing dollar-quoted
 * bodies with a $body$ placeholder (so text inside a function body can't
 * look like a clause). Returns [{ text, bodies }], one per statement.
 */
export function splitSql(sql) {
  const statements = [];
  let cur = "", bodies = [], i = 0;
  const end = () => {
    if (cur.trim()) statements.push({ text: cur.trim().replace(/\s+/g, " "), bodies });
    cur = ""; bodies = [];
  };
  while (i < sql.length) {
    const c = sql[i], n = sql[i + 1];
    if (c === "-" && n === "-") { while (i < sql.length && sql[i] !== "\n") i++; cur += " "; continue; }
    if (c === "/" && n === "*") {
      let depth = 1; i += 2;
      while (i < sql.length && depth) {
        if (sql[i] === "/" && sql[i + 1] === "*") { depth++; i += 2; }
        else if (sql[i] === "*" && sql[i + 1] === "/") { depth--; i += 2; }
        else i++;
      }
      cur += " "; continue;
    }
    if (c === "'" || c === '"') {
      let j = i + 1;
      while (j < sql.length) { if (sql[j] === c) { if (sql[j + 1] === c) j += 2; else break; } else j++; }
      cur += sql.slice(i, j + 1); i = j + 1; continue;
    }
    if (c === "$") {
      const tag = sql.slice(i).match(/^\$([A-Za-z_][A-Za-z0-9_]*)?\$/);
      if (tag && !/[A-Za-z0-9_]/.test(sql[i - 1] ?? "")) {
        const end = sql.indexOf(tag[0], i + tag[0].length);
        const stop = end === -1 ? sql.length : end;
        bodies.push(sql.slice(i + tag[0].length, stop));
        cur += " $body$ "; i = end === -1 ? sql.length : end + tag[0].length; continue;
      }
    }
    if (c === ";") { end(); i++; continue; }
    cur += c; i++;
  }
  end();
  return statements;
}

/** Last part of a possibly schema-qualified, possibly quoted name, lower-cased. */
const ident = (s) => {
  const parts = s.trim().match(/"(?:[^"]|"")*"|[^."]+/g) ?? [s];
  const last = parts[parts.length - 1];
  return last.startsWith('"') ? last.slice(1, -1).replace(/""/g, '"') : last.toLowerCase();
};

/** Split a list at commas that aren't inside parentheses or quotes. */
function splitTop(list) {
  const out = []; let depth = 0, cur = "", q = null;
  for (const ch of list) {
    if (q) { cur += ch; if (ch === q) q = null; continue; }
    if (ch === '"' || ch === "'") { q = ch; cur += ch; continue; }
    if (ch === "(") depth++;
    if (ch === ")") depth--;
    if (ch === "," && depth === 0) { out.push(cur); cur = ""; continue; }
    cur += ch;
  }
  if (cur.trim()) out.push(cur);
  return out.map((s) => s.trim()).filter(Boolean);
}

/** Function name from "schema.fn(args)" or "fn". */
const fnName = (item) => ident(item.replace(/\(.*$/s, ""));

const toBrowser = (roles) => splitTop(roles.replace(/\bwith\s+grant\s+option\b.*$/i, "").replace(/\bgranted\s+by\b.*$/i, ""))
  .map((r) => ident(r.replace(/^group\s+/i, "")))
  .filter((r) => BROWSER_ROLES.has(r));

const EXEC = /\b(execute|all)\b/i;
// A grant or revoke on functions inside a dollar-quoted block (DO loops, EXECUTE format).
// [^;'] keeps each match inside one quoted statement.
const DYN_GRANT = /\bgrant\b[^;']*?\bon\s+(all\s+)?(function|procedure|routine)s?\b[^;']*?\bto\b[^;']*?\b(anon|authenticated|public)\b/i;
const DYN_REVOKE = /\brevoke\b[^;']*?\bon\s+(all\s+)?(function|procedure|routine)s?\b[^;']*?\bfrom\b([^;']*)/i;

const quoted = (s) => [...s.matchAll(/'((?:[^']|'')*)'/g)].map((q) => fnName(q[1].replace(/''/g, "'")));

/** The functions a dynamic revoke loop covers, out of the ones known so far. */
function loopTargets(body, known) {
  const list = body.match(/\bforeach\b[\s\S]*?\bin\s+array\s+array\s*\[([\s\S]*?)\]/i);
  if (list) return quoted(list[1]);
  const kept = new Set();
  for (const m of body.matchAll(/\bproname\s*(?:<>|!=)\s*'((?:[^']|'')*)'/gi)) kept.add(m[1].toLowerCase());
  for (const m of body.matchAll(/\bproname\s+not\s+in\s*\(([^)]*)\)/gi)) quoted(m[1]).forEach((n) => kept.add(n));
  for (const m of body.matchAll(/\bproname\s*(?:<>|!=)\s*all\s*\(([\s\S]*?)\)\s*(?:\)|and\b|or\b|loop\b|$)/gi)) quoted(m[1]).forEach((n) => kept.add(n));
  return known.filter((n) => !kept.has(n));
}

/**
 * Check a list of { file, sql } migrations, in order, against an allow-list,
 * working out the state they leave behind. Returns problem strings.
 */
export function checkMigrations(migrations, allow) {
  const allowed = new Set(allow);
  const problems = [];
  const fns = new Map(); // name -> { definer, hasPath, file }
  const grants = new Map(); // name -> Map(browser role -> file that granted it)
  const defaults = new Map(); // browser role -> file of ALTER DEFAULT PRIVILEGES ... GRANT ... ON FUNCTIONS

  const grant = (name, roles, file) => {
    const g = grants.get(name) ?? new Map();
    for (const r of roles) g.set(r, file);
    grants.set(name, g);
  };
  const revoke = (names, roles) => { for (const n of names) for (const r of roles) grants.get(n)?.delete(r); };

  for (const { file, sql } of migrations) {
    for (const { text: st, bodies } of splitSql(sql)) {
      for (const raw of bodies) {
        const body = raw.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/--[^\n]*/g, " ");
        if (DYN_GRANT.test(body)) {
          problems.push(`${file}: a dollar-quoted block grants a function to a browser role; write the GRANT as a plain statement so this guard can read it`);
        }
        // A lockdown loop (REVOKE ... ON FUNCTION %s FROM PUBLIC, anon, authenticated) covers
        // the functions an ARRAY[...] lists, or else every function so far except the ones it
        // excludes by name (proname <> 'x', NOT IN (...), <> ALL (...)). db-push.sh checks the
        // real result.
        const rv = body.match(DYN_REVOKE);
        if (rv) revoke(loopTargets(body, [...grants.keys()]), toBrowser(rv[3]));
      }
      let m;
      if ((m = st.match(/^create\s+(?:or\s+replace\s+)?(function|procedure)\s+((?:"(?:[^"]|"")*"|[\w$])+(?:\s*\.\s*(?:"(?:[^"]|"")*"|[\w$]+))?)\s*\(/i))) {
        fns.set(ident(m[2]), {
          definer: /\bsecurity\s+definer\b/i.test(st),
          hasPath: /\bset\s+search_path\b/i.test(st),
          file,
        });
        continue;
      }
      if ((m = st.match(/^alter\s+(function|procedure|routine)\s+([^\s(]+(?:\s*\.\s*[^\s(]+)?)\s*(\([^)]*\))?\s*(.*)$/i))) {
        const name = ident(m[2]), rest = m[4];
        const f = fns.get(name) ?? { definer: false, hasPath: false, file };
        const rn = rest.match(/^rename\s+to\s+(\S+)/i);
        if (rn) {
          const to = ident(rn[1]);
          fns.delete(name); fns.set(to, f);
          if (grants.has(name)) { grants.set(to, grants.get(name)); grants.delete(name); }
          continue;
        }
        if (/\bsecurity\s+definer\b/i.test(rest)) f.definer = true;
        if (/\bsecurity\s+invoker\b/i.test(rest)) f.definer = false;
        if (/\bset\s+search_path\b/i.test(rest)) f.hasPath = true;
        if (/\breset\s+(search_path|all)\b/i.test(rest)) f.hasPath = false;
        f.file = file;
        fns.set(name, f);
        continue;
      }
      if ((m = st.match(/^drop\s+(function|procedure|routine)\s+(?:if\s+exists\s+)?(.*?)(?:\s+(?:cascade|restrict))?$/i))) {
        for (const item of splitTop(m[2])) { fns.delete(fnName(item)); grants.delete(fnName(item)); }
        continue;
      }
      if ((m = st.match(/^alter\s+default\s+privileges\b.*?\b(grant|revoke)\s+(.*?)\s+on\s+(functions|routines)\s+(to|from)\s+(.*)$/i))) {
        if (!EXEC.test(m[2])) continue;
        for (const r of toBrowser(m[5])) {
          if (m[1].toLowerCase() === "grant") defaults.set(r, file); else defaults.delete(r);
        }
        continue;
      }
      if ((m = st.match(/^(grant|revoke)\s+(.*?)\s+on\s+all\s+(functions|procedures|routines)\s+in\s+schema\s+.*?\s+(to|from)\s+(.*)$/i))) {
        if (!EXEC.test(m[2])) continue;
        const roles = toBrowser(m[5]);
        if (m[1].toLowerCase() === "revoke") { revoke([...grants.keys()], roles); continue; }
        if (roles.length) problems.push(`${file}: GRANT ${m[2]} ON ALL ${m[3].toUpperCase()} to ${roles.join(", ")}; grant browser roles single, allow-listed functions only`);
        continue;
      }
      if ((m = st.match(/^grant\s+(.*?)\s+on\s+(function|procedure|routine)\s+(.*)\s+to\s+(.*)$/i))) {
        const roles = toBrowser(m[4]);
        if (roles.length && EXEC.test(m[1])) for (const item of splitTop(m[3])) grant(fnName(item), roles, file);
        continue;
      }
      if ((m = st.match(/^revoke\s+(.*?)\s+on\s+(function|procedure|routine)\s+(.*)\s+from\s+(.*)$/i))) {
        if (!EXEC.test(m[1]) || /^grant\s+option\s+for\b/i.test(m[1])) continue;
        revoke(splitTop(m[3]).map(fnName), toBrowser(m[4]));
      }
    }
  }

  for (const [name, g] of grants) {
    if (allowed.has(name)) continue;
    for (const [role, file] of g) {
      problems.push(`${file}: grants EXECUTE on ${name} to ${role}, but ${name} isn't on BROWSER_FUNCTION_ALLOW in scripts/db-push.sh`);
    }
  }
  for (const [role, file] of defaults) {
    problems.push(`${file}: ALTER DEFAULT PRIVILEGES grants EXECUTE on new functions to ${role}`);
  }
  for (const [name, f] of fns) {
    if (f.definer && !f.hasPath) problems.push(`${f.file}: SECURITY DEFINER function ${name} has no SET search_path`);
  }
  for (const name of allowed) {
    if (!fns.has(name)) problems.push(`BROWSER_FUNCTION_ALLOW lists ${name}, but no migration creates a function by that name`);
  }
  return problems;
}


function realMigrations() {
  let files = [];
  try { files = readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort(); } catch { /* no migrations yet */ }
  return files.map((file) => ({ file, sql: readFileSync(path.join(MIGRATIONS, file), "utf8") }));
}

test("this project's migrations keep every function service_role only unless allow-listed", () => {
  assert.deepEqual(checkMigrations(realMigrations(), readAllowList()), []);
});

test("BROWSER_FUNCTION_ALLOW holds only plain lower-case names", () => {
  for (const name of readAllowList()) assert.match(name, /^[a-z0-9_]+$/);
});

// --- The guard itself: it must catch each mistake and pass the safe patterns. ---

const run = (sql, allow = []) => checkMigrations([{ file: "m.sql", sql }], allow);

test("guard: passes the safe patterns", () => {
  assert.deepEqual(run(`
    SET search_path TO app, public;
    CREATE FUNCTION app.stats() RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = app, pg_temp AS $$ SELECT 1 $$;
    REVOKE ALL ON FUNCTION app.stats() FROM PUBLIC, anon, authenticated;
    GRANT EXECUTE ON FUNCTION app.stats() TO service_role;
    CREATE OR REPLACE FUNCTION is_member(p_id uuid) RETURNS boolean
      LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
      AS $fn$ SELECT true -- GRANT EXECUTE ON FUNCTION x TO anon in a comment is fine
      $fn$;
    GRANT EXECUTE ON FUNCTION is_member(uuid) TO authenticated;
    CREATE FUNCTION touch() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
    GRANT USAGE ON SCHEMA app TO anon, authenticated;
    GRANT SELECT ON app.posts TO anon, authenticated;
    GRANT authenticated TO some_role;
    ALTER DEFAULT PRIVILEGES IN SCHEMA app REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
    ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT EXECUTE ON FUNCTIONS TO service_role;
  `, ["is_member"]), []);
});

test("guard: a browser grant on a function that isn't allow-listed fails", () => {
  const p = run(`CREATE FUNCTION app.add(a int, b int) RETURNS int LANGUAGE sql AS $$ SELECT a + b $$;
                 GRANT EXECUTE ON FUNCTION app.add(int, int), app.other() TO service_role, authenticated;`);
  assert.equal(p.length, 2);
  assert.match(p[0], /add to authenticated/);
  assert.match(p[1], /other to authenticated/);
  assert.equal(run(`GRANT ALL ON ROUTINE "App"."Add"(int) TO public;`).length, 1);
  assert.equal(run(`GRANT EXECUTE ON PROCEDURE app.p() TO anon WITH GRANT OPTION;`).length, 1);
});

test("guard: judges the grants the migrations leave, not ones a later migration took back", () => {
  const early = { file: "1.sql", sql: `CREATE FUNCTION app.f() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;
    GRANT EXECUTE ON FUNCTION app.f() TO anon, authenticated;` };
  const check = (...later) => checkMigrations([early, ...later.map((sql, i) => ({ file: `${i + 2}.sql`, sql }))], []);
  assert.equal(check().length, 2);
  assert.deepEqual(check(`REVOKE ALL ON FUNCTION app.f() FROM PUBLIC, anon, authenticated;`), []);
  assert.deepEqual(check(`REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM anon, authenticated;`), []);
  assert.deepEqual(check(`DROP FUNCTION app.f();`), []);
  // Revoking from PUBLIC alone leaves the explicit grants.
  assert.equal(check(`REVOKE ALL ON FUNCTION app.f() FROM PUBLIC;`).length, 2);
  // The 18 Oct lockdown loop, then a fresh grant after it.
  const loop = `DO $$ DECLARE f regprocedure; BEGIN FOR f IN SELECT 1 LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f); END LOOP; END $$;`;
  assert.deepEqual(check(loop), []);
  assert.equal(check(loop + `GRANT EXECUTE ON FUNCTION app.f() TO authenticated;`).length, 1);
  // A loop that skips f by name, or lists other functions, leaves f's grants standing.
  assert.equal(check(loop.replace("SELECT 1", "SELECT p.oid FROM pg_proc p WHERE p.proname <> 'f'")).length, 2);
  assert.equal(check(loop.replace("SELECT 1", "SELECT p.oid FROM pg_proc p WHERE p.proname NOT IN ('g', 'f')")).length, 2);
  assert.equal(check(loop.replace("FOR f IN SELECT 1 LOOP", "FOREACH f IN ARRAY ARRAY['app.g(int)']::regprocedure[] LOOP")).length, 2);
  assert.deepEqual(check(loop.replace("FOR f IN SELECT 1 LOOP", "FOREACH f IN ARRAY ARRAY['app.g(int)', 'app.f()']::regprocedure[] LOOP")), []);
  // Renamed: the grant follows the function.
  assert.match(check(`ALTER FUNCTION app.f() RENAME TO g;`)[0], /EXECUTE on g to/);
});

test("guard: schema-wide and default browser grants on functions fail", () => {
  assert.equal(run(`GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app TO anon;`).length, 1);
  assert.equal(run(`GRANT ALL ON ALL ROUTINES IN SCHEMA app TO service_role, authenticated;`).length, 1);
  assert.equal(run(`ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT EXECUTE ON FUNCTIONS TO anon, authenticated;`).length, 2);
  assert.equal(run(`ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin GRANT ALL ON ROUTINES TO public;`).length, 1);
  assert.deepEqual(run(`ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT ALL ON FUNCTIONS TO anon, authenticated;
    ALTER DEFAULT PRIVILEGES IN SCHEMA app REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;`), []);
});

test("guard: SECURITY DEFINER without a fixed search_path fails, as the migrations leave it", () => {
  const nopath = `CREATE FUNCTION app.f() RETURNS int LANGUAGE sql SECURITY DEFINER AS $$ SELECT 1 $$;`;
  assert.equal(run(nopath).length, 1);
  // Clause after the body counts.
  assert.deepEqual(run(`CREATE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql SECURITY DEFINER SET search_path = app;`), []);
  // Fixed later by ALTER FUNCTION.
  assert.deepEqual(run(nopath + `ALTER FUNCTION app.f() SET search_path = app, pg_temp;`), []);
  // CREATE OR REPLACE without SET drops the earlier fix.
  assert.equal(run(nopath + `ALTER FUNCTION app.f() SET search_path = app;
    CREATE OR REPLACE FUNCTION app.f() RETURNS int LANGUAGE sql SECURITY DEFINER AS $$ SELECT 2 $$;`).length, 1);
  // Made definer later, or path reset.
  assert.equal(run(`CREATE FUNCTION f() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$; ALTER FUNCTION f() SECURITY DEFINER;`).length, 1);
  assert.equal(run(`CREATE FUNCTION f() RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = app AS $$ SELECT 1 $$;
    ALTER FUNCTION f() RESET search_path;`).length, 1);
  // Dropped, or made invoker: fine.
  assert.deepEqual(run(nopath + `DROP FUNCTION IF EXISTS app.f(), app.g(int) CASCADE;`), []);
  assert.deepEqual(run(nopath + `ALTER FUNCTION app.f() SECURITY INVOKER;`), []);
  // Text inside a body can't fake the clause.
  assert.equal(run(`CREATE FUNCTION f() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$ SELECT 'SET search_path' $$;`).length, 1);
});

test("guard: a dynamic browser grant it can't read fails", () => {
  assert.equal(run(`DO $$ BEGIN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', 'app.f()'); END $$;`).length, 1);
  assert.deepEqual(run(`DO $$ BEGIN EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', 'app.f()'); END $$;`), []);
});

test("guard: a stale allow-list entry fails", () => {
  assert.equal(run(`SELECT 1;`, ["gone"]).length, 1);
  assert.deepEqual(run(`CREATE FUNCTION app.kept() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;`, ["kept"]), []);
});

test("guard: reads the allow-list line from db-push.sh", () => {
  assert.deepEqual(readAllowList(`x\nBROWSER_FUNCTION_ALLOW="a_b  c"\n`), ["a_b", "c"]);
  assert.deepEqual(readAllowList(`BROWSER_FUNCTION_ALLOW=""`), []);
  assert.throws(() => readAllowList(`nothing here`));
});
