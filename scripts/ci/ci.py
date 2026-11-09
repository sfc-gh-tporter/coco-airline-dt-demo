#!/usr/bin/env python3
"""scripts/ci/ci.py - CI/CD engine for the airline pipeline (stdlib only).

Every Snowflake call goes through the Snowflake CLI (`snow sql`), so there is exactly one
auth path:
  - GitHub Actions: `-x` temporary connection built from SNOWFLAKE_* env vars. The
    snowflakedb/snowflake-actions@v3 step (use-oidc: true) exports the OIDC token, so
    no key or password exists anywhere.
  - Local runs:     set SNOWFLAKE_CONNECTION_NAME=<name> to use a named connection.

Commands
  pr-check   --pr N --base SHA --head SHA   Build the PR's right-sized test environment
                                            (AIRLINE_CI.PR_<n>_*), run the gates, post the
                                            sticky PR comment, exit non-zero on failure.
  pr-cleanup --pr N                         Drop the PR's schemas.
  sweep      [--max-age-hours 24]           Drop PR schemas with no open PR / too old.
  deploy     --before SHA --after SHA       Prod deploy: query tags, DEPLOY_LOG, smoke test,
                                            automatic rollback, prod-last-good tag.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile

PROD_DB = "AIRLINE_PROD"
CI_DB = "AIRLINE_CI"
CI_WH = "AIRLINE_CI_WH"
PROD_WH = "AIRLINE_DEMO_WH"
MIRRORED_SCHEMAS = ("STAGING", "CURATED")          # schemas a PR env mirrors
PR_SKIP_PREFIXES = ("sql/00_account/", "sql/data_gen/", "sql/ops/")  # not part of the pipeline under test
PROD_SKIP_PREFIXES = ("sql/00_account/",)          # admin bootstrap, never deployed by CI
DEPLOY_ORDER = ["sql/ops/", "sql/staging/tables/", "sql/data_gen/", "sql/curated/tables/",
                "sql/curated/dynamic_tables/", "sql/curated/views/", "sql/curated/tasks/"]
COMMENT_MARKER = "<!-- coco-ci-report -->"
INCREMENTAL_BATCH = "tests/gates/incremental_batch.sql"

REF_RE = re.compile(r"\bAIRLINE_PROD\.(STAGING|CURATED)\.([A-Z0-9_]+)\b", re.I)
DEF_RE = re.compile(
    r"\b(CREATE(?:\s+OR\s+REPLACE)?|ALTER)\s+(?:TRANSIENT\s+)?(DYNAMIC\s+TABLE|TABLE|VIEW|TASK)"
    r"\s+(?:IF\s+NOT\s+EXISTS\s+)?AIRLINE_PROD\.(STAGING|CURATED)\.([A-Z0-9_]+)", re.I)


# --------------------------------------------------------------------------- snowflake
class SqlError(Exception):
    pass


def conn_args():
    name = os.environ.get("SNOWFLAKE_CONNECTION_NAME")
    if not name:
        return ["-x"]
    args = ["-c", name]
    # Local runs: act as the same role/warehouse the CI identity would use.
    if os.environ.get("SNOWFLAKE_ROLE"):
        args += ["--role", os.environ["SNOWFLAKE_ROLE"]]
    if os.environ.get("SNOWFLAKE_WAREHOUSE"):
        args += ["--warehouse", os.environ["SNOWFLAKE_WAREHOUSE"]]
    return args


def sf(sql, tag=None):
    """Run one or more statements; return a list (one per statement) of row-dict lists."""
    if tag:
        sql = f"ALTER SESSION SET QUERY_TAG = '{tag}';\n{sql}"
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as fh:
        fh.write(sql)
        path = fh.name
    try:
        p = subprocess.run(["snow", "sql", "-f", path, "--format", "json", *conn_args()],
                           capture_output=True, text=True)
    finally:
        os.unlink(path)
    if p.returncode != 0:
        raise SqlError(_clean_error(p.stderr + p.stdout))
    out = p.stdout.strip()
    if not out:
        return []
    data = json.loads(out)
    # single statement -> list of rows; multiple -> list of lists
    if data and isinstance(data[0], dict):
        data = [data]
    return data


def rows(sql, tag=None):
    """Rows of the LAST statement."""
    res = sf(sql, tag)
    return res[-1] if res else []


def _clean_error(text):
    lines = [l.strip(" │╭╮╰╯─") for l in text.splitlines()]
    msg = " ".join(l for l in lines if l and "Error" not in l[:7])
    return re.sub(r"\s+", " ", msg).strip()[:1500]


def lit(s):
    return "'" + str(s).replace("\\", "\\\\").replace("'", "''") + "'"


# --------------------------------------------------------------------------- git / gh
def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, check=True).stdout


def changed_files(base, head):
    out = git("diff", "--name-only", f"{base}...{head}")
    return sorted(f for f in out.splitlines() if f.strip())


def repo_slug():
    return os.environ.get("GITHUB_REPOSITORY") or \
        subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                       capture_output=True, text=True).stdout.strip()


def gh_api(*a):
    p = subprocess.run(["gh", "api", *a], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip())
    return json.loads(p.stdout) if p.stdout.strip() else None


# --------------------------------------------------------------------------- parsing
def read(path):
    with open(path) as fh:
        return fh.read()


def refs(text):
    return {(s.upper(), n.upper()) for s, n in REF_RE.findall(text)}


def definitions(text):
    """[(verb, kind, schema, name)] for objects a file creates/alters."""
    out = []
    for verb, kind, s, n in DEF_RE.findall(text):
        out.append((re.sub(r"\s+", " ", verb.upper()), re.sub(r"\s+", " ", kind.upper()),
                    s.upper(), n.upper()))
    return out


def order_key(path):
    for i, prefix in enumerate(DEPLOY_ORDER):
        if path.startswith(prefix):
            return (i, path)
    return (len(DEPLOY_ORDER), path)


def repo_sql_files():
    return sorted(f for f in git("ls-files", "sql").splitlines()
                  if f.endswith(".sql") and not f.startswith(PR_SKIP_PREFIXES))


# --------------------------------------------------------------------------- PR env
def pr_schema(pr, schema):
    return f"PR_{pr}_{schema}"


def render_for_pr(text, pr, tag):
    """Point SQL written for prod at the PR's schemas, on CI compute, as the CI role."""
    def repl(m):
        return f"{CI_DB}.{pr_schema(pr, m.group(1).upper())}.{m.group(2)}"
    out = REF_RE.sub(repl, text)
    out = re.sub(r"^\s*USE\s+ROLE\s+[^;]+;\s*$", "", out, flags=re.I | re.M)
    out = re.sub(r"\bWAREHOUSE\s*=\s*" + PROD_WH + r"\b", f"WAREHOUSE = {CI_WH}", out, flags=re.I)
    out = re.sub(r"\bUSE\s+WAREHOUSE\s+" + PROD_WH + r"\b", f"USE WAREHOUSE {CI_WH}", out, flags=re.I)
    if re.search(r"\bAIRLINE_PROD\b", re.sub(r"--[^\n]*", "", out), re.I):
        raise SqlError("refusing to run: rendered PR SQL still references AIRLINE_PROD")
    return f"USE WAREHOUSE {CI_WH};\nALTER SESSION SET QUERY_TAG = '{tag}';\n{out}"


def compute_scope(changed):
    """Right-size the PR env: what to deploy, what to clone, what to test."""
    sql_changed = [f for f in changed if f.startswith("sql/") and f.endswith(".sql")]
    skipped = [f for f in sql_changed if f.startswith(PR_SKIP_PREFIXES)]
    deploy = [f for f in sql_changed if f not in skipped and os.path.exists(f)]

    changed_objs = set()
    for f in deploy:
        changed_objs |= {(s, n) for _, _, s, n in definitions(read(f))}

    # Downstream: any other pipeline file that reads an object this PR changes.
    downstream = []
    for f in repo_sql_files():
        if f in deploy:
            continue
        if refs(read(f)) & changed_objs:
            downstream.append(f)
    deploy_all = sorted(set(deploy) | set(downstream), key=order_key)

    # Parity tests: changed ones, plus existing ones that cover a changed object.
    tests = []
    for f in sorted(git("ls-files", "tests/parity").splitlines()) + \
            [f for f in changed if f.startswith("tests/parity/")]:
        if f.endswith(".sql") and os.path.exists(f) and f not in tests:
            if f in changed or refs(read(f)) & changed_objs:
                tests.append(f)

    replaced = set()           # CREATE OR REPLACE -> built fresh from the PR's code
    for f in deploy_all:
        for verb, _, s, n in definitions(read(f)):
            if verb == "CREATE OR REPLACE":
                replaced.add((s, n))
    wanted = set()
    for f in deploy_all + tests:
        wanted |= refs(read(f))
    return {"deploy": deploy_all, "downstream": downstream, "skipped": skipped,
            "tests": tests, "changed_objs": changed_objs, "clone_candidates": wanted - replaced}


def existing_prod_tables(candidates):
    if not candidates:
        return set()
    preds = " OR ".join(f"(table_schema = {lit(s)} AND table_name = {lit(n)})" for s, n in candidates)
    r = rows(f"SELECT table_schema, table_name FROM {PROD_DB}.INFORMATION_SCHEMA.TABLES WHERE {preds}")
    return {(x["TABLE_SCHEMA"], x["TABLE_NAME"]) for x in r}


def drop_pr_env(pr):
    sf(";\n".join(f"DROP SCHEMA IF EXISTS {CI_DB}.{pr_schema(pr, s)}" for s in MIRRORED_SCHEMAS))


def build_pr_env(pr, clones, tag):
    stmts = [f"USE WAREHOUSE {CI_WH}"]
    for s in MIRRORED_SCHEMAS:
        stmts.append(f"CREATE OR REPLACE SCHEMA {CI_DB}.{pr_schema(pr, s)} "
                     f"COMMENT = 'PR #{pr} test environment (auto-dropped when the PR closes)'")
    for s, n in sorted(clones):
        stmts.append(f"CREATE TABLE {CI_DB}.{pr_schema(pr, s)}.{n} CLONE {PROD_DB}.{s}.{n}")
    sf(";\n".join(stmts) + ";", tag)


# --------------------------------------------------------------------------- gates
class Gate:
    def __init__(self, name, blocking=True):
        self.name, self.blocking, self.status, self.detail = name, blocking, "SKIP", ""

    def ok(self, detail=""):
        self.status, self.detail = "PASS", detail

    def fail(self, detail):
        self.status, self.detail = "FAIL", detail

    def warn(self, detail):
        self.status, self.detail = "WARN", detail

    def skip(self, detail):
        self.status, self.detail = "SKIP", detail


def pr_dynamic_tables(pr, objs):
    names = {n for s, n in objs if s == "CURATED"}
    if not names:
        return []
    res = sf(f"SHOW DYNAMIC TABLES IN SCHEMA {CI_DB}.{pr_schema(pr, 'CURATED')}")
    return [r for r in (res[-1] if res else []) if r["name"] in names]


def gate_docs(pr, objs):
    g = Gate("Docs coverage")
    if not objs:
        g.skip("no tables/views changed")
        return g
    problems, documented = [], 0
    for s, n in sorted(objs):
        sch = pr_schema(pr, s)
        t = rows(f"SELECT comment FROM {CI_DB}.INFORMATION_SCHEMA.TABLES "
                 f"WHERE table_schema = {lit(sch)} AND table_name = {lit(n)}")
        if not t:
            continue
        cols = rows(f"SELECT column_name, comment FROM {CI_DB}.INFORMATION_SCHEMA.COLUMNS "
                    f"WHERE table_schema = {lit(sch)} AND table_name = {lit(n)} ORDER BY ordinal_position")
        missing = [c["COLUMN_NAME"].lower() for c in cols if not (c["COMMENT"] or "").strip()]
        documented += len(cols) - len(missing)
        if not (t[0]["COMMENT"] or "").strip():
            problems.append(f"`{n.lower()}`: no table comment")
        if missing:
            problems.append(f"`{n.lower()}`: {len(missing)}/{len(cols)} columns undocumented "
                            f"({', '.join(missing)})")
    if problems:
        g.fail("; ".join(problems))
    else:
        g.ok(f"table + all {documented} columns documented")
    return g


def gate_refresh_mode(dts):
    g = Gate("Dynamic table refresh mode")
    if not dts:
        g.skip("no dynamic tables changed")
        return g
    bad = [f"`{d['name'].lower()}` is {d['refresh_mode']} ({d.get('refresh_mode_reason') or 'no reason'})"
           for d in dts if d["refresh_mode"] != "INCREMENTAL" or (d.get("refresh_mode_reason") or "").strip()]
    if bad:
        g.fail("; ".join(bad))
    else:
        g.ok(", ".join(f"`{d['name'].lower()}` INCREMENTAL" for d in dts))
    return g


def gate_parity(pr, tests, tag):
    g = Gate("Parity vs incumbent")
    if not tests:
        g.skip("no parity test covers the changed objects")
        return g
    checks, failed = [], []
    for f in tests:
        try:
            for res in sf(render_for_pr(read(f), pr, tag)):
                for r in res:
                    if "CHECK_NAME" in r:
                        checks.append(r)
                        if str(r.get("PASSED")).lower() not in ("true", "1"):
                            failed.append(f"{r['CHECK_NAME']}: {r.get('DETAIL')}")
        except SqlError as e:
            failed.append(f"`{f}` errored: {e}")
    if failed:
        g.fail("; ".join(failed))
    elif not checks:
        g.fail("parity tests returned no CHECK_NAME/PASSED rows")
    else:
        g.ok(f"{len(checks)}/{len(checks)} checks passed (" +
             "; ".join(f"{c['CHECK_NAME']}: {c.get('DETAIL')}" for c in checks) + ")")
    return g


def gate_incremental(pr, dts, clones, tag):
    g = Gate("Incremental behavior")
    if not dts:
        g.skip("no dynamic tables changed")
        return g
    if not os.path.exists(INCREMENTAL_BATCH):
        g.skip(f"{INCREMENTAL_BATCH} not found")
        return g
    batch = read(INCREMENTAL_BATCH)
    if not refs(batch) <= clones:
        g.skip("localized batch touches tables outside this PR's scope")
        return g
    try:
        sf(render_for_pr(batch, pr, tag))
        notes, bad = [], []
        for d in dts:
            fq = f"{CI_DB}.{pr_schema(pr, 'CURATED')}.{d['name']}"
            stats = rows(f"USE WAREHOUSE {CI_WH};\nALTER DYNAMIC TABLE {fq} REFRESH", tag)[0]
            s = json.loads(stats.get("statistics") or "{}")
            hist = rows(f"SELECT refresh_action, state FROM TABLE({CI_DB}.INFORMATION_SCHEMA."
                        f"DYNAMIC_TABLE_REFRESH_HISTORY(NAME => {lit(fq)})) "
                        f"WHERE refresh_trigger = 'MANUAL' ORDER BY refresh_start_time DESC LIMIT 1")
            action = hist[0]["REFRESH_ACTION"] if hist else "UNKNOWN"
            total = rows(f"SELECT COUNT(*) AS n FROM {fq}")[0]["N"]
            changed = int(s.get("insertedRows", 0)) + int(s.get("deletedRows", 0))
            notes.append(f"`{d['name'].lower()}` {action}: {s.get('insertedRows', 0)} rows rewritten "
                         f"of {total:,}")
            if action != "INCREMENTAL" or changed > 0.05 * max(total, 1):
                bad.append(notes[-1])
        if bad:
            g.fail("; ".join(bad))
        else:
            g.ok("; ".join(notes))
    except SqlError as e:
        g.fail(str(e))
    return g


def gate_lint(files):
    g = Gate("SQL lint (sqlfluff)", blocking=False)
    if not files:
        g.skip("no SQL changed")
        return g
    try:
        p = subprocess.run(["sqlfluff", "lint", "--dialect", "snowflake", "--format", "json",
                            "--nofail", *files], capture_output=True, text=True)
    except FileNotFoundError:
        g.skip("sqlfluff not installed")
        return g
    if p.returncode != 0 and not p.stdout.strip():
        g.skip("sqlfluff not available")
        return g
    try:
        viol = [(f["filepath"], v) for f in json.loads(p.stdout) for v in f.get("violations", [])]
    except json.JSONDecodeError:
        g.skip("could not parse sqlfluff output")
        return g
    if not viol:
        g.ok("no findings")
    else:
        top = "; ".join(f"{os.path.basename(fp)}:{v.get('start_line_no', '?')} {v.get('code')}"
                        for fp, v in viol[:5])
        g.warn(f"{len(viol)} advisory finding(s): {top}")
    return g


def gate_cost(tag_prefix):
    g = Gate("Cost of this run", blocking=False)
    r = rows(f"SELECT COUNT(*) AS q, ROUND(SUM(total_elapsed_time)/1000, 1) AS secs, "
             f"ROUND(SUM(bytes_scanned)/POW(1024,3), 2) AS gb "
             f"FROM TABLE({CI_DB}.INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT => 10000)) "
             f"WHERE query_tag LIKE {lit(tag_prefix + '%')}")
    if r:
        g.ok(f"{r[0]['Q']} queries, {r[0]['SECS'] or 0}s, {r[0]['GB'] or 0} GB scanned on {CI_WH}")
    return g


# --------------------------------------------------------------------------- report
ICON = {"PASS": "PASS", "FAIL": "FAIL", "WARN": "WARN", "SKIP": "skip"}


def report(pr, head, scope, clones, deploy_results, gates):
    failed = [g for g in gates if g.blocking and g.status == "FAIL"]
    verdict = "FAILED" if failed else "PASSED"
    lines = [COMMENT_MARKER, f"## CI checks {verdict} for `{head[:7]}`", ""]
    lines.append(f"**Test environment:** `{CI_DB}.PR_{pr}_*` - {len(clones)} zero-copy clone(s) "
                 f"of only what this PR touches, {len(scope['deploy'])} file(s) deployed. "
                 f"Dropped automatically when the PR closes.")
    lines.append("")
    lines.append("| Check | Result | Details |")
    lines.append("|---|---|---|")
    for g in gates:
        req = "" if g.blocking else " (advisory)"
        lines.append(f"| {g.name}{req} | **{ICON[g.status]}** | {g.detail.replace('|', '/')} |")
    lines.append("")
    lines.append("<details><summary>Scope</summary>\n")
    lines.append("- Cloned from prod: " + (", ".join(f"`{s.lower()}.{n.lower()}`" for s, n in sorted(clones)) or "none"))
    for f, ok, msg in deploy_results:
        lines.append(f"- Deployed `{f}`: {'ok' if ok else 'FAILED - ' + msg}")
    for f in scope["downstream"]:
        lines.append(f"- `{f}` redeployed because it depends on a changed object")
    for f in scope["skipped"]:
        lines.append(f"- `{f}` not deployed to the PR environment (admin / generator file)")
    for f in scope["tests"]:
        lines.append(f"- Parity test `{f}`")
    lines.append("\n</details>")
    if failed:
        lines.append("")
        lines.append("Fix the failing check(s) and push to this branch; CI re-runs automatically.")
    return "\n".join(lines), not failed


def post_comment(pr, body):
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as fh:
            fh.write(body + "\n")
    if not os.environ.get("GITHUB_ACTIONS") and not os.environ.get("CI_POST_COMMENT"):
        print(body)
        return
    slug = repo_slug()
    existing = gh_api(f"repos/{slug}/issues/{pr}/comments", "--paginate") or []
    mine = [c for c in existing if COMMENT_MARKER in (c.get("body") or "")]
    if mine:
        gh_api("-X", "PATCH", f"repos/{slug}/issues/comments/{mine[-1]['id']}", "-f", f"body={body}")
    else:
        gh_api("-X", "POST", f"repos/{slug}/issues/{pr}/comments", "-f", f"body={body}")


# --------------------------------------------------------------------------- commands
def cmd_pr_check(a):
    pr, head = a.pr, a.head
    tag = f"gh:pr:{pr}:{head[:12]}"
    scope = compute_scope(changed_files(a.base, head))
    gates, deploy_results = [], []
    clones = set()

    if not scope["deploy"] and not scope["tests"]:
        g = Gate("Snowflake checks")
        g.skip("no pipeline SQL or tests changed - nothing to run in Snowflake")
        body, _ = report(pr, head, scope, clones, [], [g])
        post_comment(pr, body)
        return 0

    clones = existing_prod_tables(scope["clone_candidates"])
    drop_pr_env(pr)
    build_pr_env(pr, clones, tag)

    deploy_gate = Gate("Deploy into PR environment")
    for f in scope["deploy"]:
        try:
            sf(render_for_pr(read(f), pr, f"{tag}:{f}"))
            deploy_results.append((f, True, ""))
        except SqlError as e:
            deploy_results.append((f, False, str(e)))
    bad = [f"`{f}`: {m}" for f, ok, m in deploy_results if not ok]
    if bad:
        deploy_gate.fail("; ".join(bad))
    else:
        deploy_gate.ok(f"{len(deploy_results)} file(s) applied")
    gates.append(deploy_gate)

    if deploy_gate.status == "PASS":
        dts = pr_dynamic_tables(pr, scope["changed_objs"])
        gates.append(gate_refresh_mode(dts))
        gates.append(gate_parity(pr, scope["tests"], tag))     # before the batch mutates inputs
        gates.append(gate_incremental(pr, dts, clones, tag))
        gates.append(gate_docs(pr, scope["changed_objs"]))
        for d in dts:   # stop CI dynamic tables from refreshing until the PR env is dropped
            sf(f"ALTER DYNAMIC TABLE {CI_DB}.{pr_schema(pr, 'CURATED')}.{d['name']} SUSPEND")
    gates.append(gate_lint([f for f in scope["deploy"] if os.path.exists(f)]))
    gates.append(gate_cost(tag))

    body, ok = report(pr, head, scope, clones, deploy_results, gates)
    post_comment(pr, body)
    return 0 if ok else 1


def cmd_pr_cleanup(a):
    drop_pr_env(a.pr)
    print(f"Dropped {CI_DB}.PR_{a.pr}_* schemas")
    return 0


def cmd_sweep(a):
    open_prs = {str(p["number"]) for p in
                gh_api(f"repos/{repo_slug()}/pulls?state=open&per_page=100") or []}
    res = rows(f"SHOW SCHEMAS LIKE 'PR\\\\_%' IN DATABASE {CI_DB}")
    now = dt.datetime.now(dt.timezone.utc)
    dropped = []
    for r in res:
        m = re.match(r"PR_(\d+)_", r["name"])
        if not m:
            continue
        created = dt.datetime.fromisoformat(str(r["created_on"]).replace("Z", "+00:00"))
        if created.tzinfo is None:
            created = created.replace(tzinfo=dt.timezone.utc)
        age_h = (now - created).total_seconds() / 3600
        if m.group(1) not in open_prs or age_h > a.max_age_hours:
            sf(f"DROP SCHEMA IF EXISTS {CI_DB}.{r['name']}")
            dropped.append(f"{r['name']} (PR open: {m.group(1) in open_prs}, age {age_h:.1f}h)")
    print("Swept: " + (", ".join(dropped) if dropped else "nothing to drop"))
    return 0


# ---- prod deploy
def log_rows(entries):
    if not entries:
        return
    vals = ",\n".join(
        "(" + ", ".join(lit(e[k]) for k in ("deploy_id", "git_sha", "actor", "file_path", "action",
                                              "status", "query_tag", "message")) +
        f", {lit(e['started_at'])}::TIMESTAMP_LTZ, {lit(e['finished_at'])}::TIMESTAMP_LTZ)"
        for e in entries)
    sf(f"INSERT INTO {PROD_DB}.OPS.DEPLOY_LOG (deploy_id, git_sha, actor, file_path, action, status, "
       f"query_tag, message, started_at, finished_at) VALUES\n{vals}")


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def smoke_test(objs, force_fail=False):
    """Return a list of failure strings (empty = healthy)."""
    fails = []
    for s, n in sorted(objs):
        t = rows(f"SELECT table_type, row_count FROM {PROD_DB}.INFORMATION_SCHEMA.TABLES "
                 f"WHERE table_schema = {lit(s)} AND table_name = {lit(n)}")
        if not t:
            fails.append(f"{s}.{n} does not exist")
            continue
        if s == "CURATED" and not (t[0]["ROW_COUNT"] or 0) > 0:
            fails.append(f"{s}.{n} has no rows")
        dts = rows(f"SHOW DYNAMIC TABLES LIKE {lit(n)} IN SCHEMA {PROD_DB}.{s}")
        if dts:
            d = dts[0]
            if d["refresh_mode"] != "INCREMENTAL":
                fails.append(f"{n} refresh_mode is {d['refresh_mode']}")
            h = rows(f"SELECT state FROM TABLE({PROD_DB}.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY("
                     f"NAME => {lit(PROD_DB + '.' + s + '.' + n)})) ORDER BY refresh_start_time DESC LIMIT 1")
            if h and h[0]["STATE"] not in ("SUCCEEDED", "EXECUTING", "SCHEDULED"):
                fails.append(f"{n} last refresh {h[0]['STATE']}")
    if force_fail:
        fails.append("rollback drill: smoke failure forced by workflow input")
    return fails


def update_last_good(sha):
    slug = repo_slug()
    try:
        gh_api("-X", "PATCH", f"repos/{slug}/git/refs/tags/prod-last-good", "-f", f"sha={sha}", "-F", "force=true")
    except RuntimeError:
        gh_api("-X", "POST", f"repos/{slug}/git/refs", "-f", "ref=refs/tags/prod-last-good", "-f", f"sha={sha}")


def cmd_deploy(a):
    run_id = f"{os.environ.get('GITHUB_RUN_ID', 'local')}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
    actor = os.environ.get("GITHUB_ACTOR", os.environ.get("USER", "local"))
    sha = a.after
    zero = "0" * 40
    if a.before and a.before != zero:
        files = changed_files(a.before, sha)
    else:
        files = sorted(git("ls-files", "sql").splitlines())
    files = sorted((f for f in files if f.endswith(".sql") and f.startswith("sql/")
                    and not f.startswith(PROD_SKIP_PREFIXES) and os.path.exists(f)), key=order_key)
    print(f"[DEPLOY prod] {len(files)} file(s) for {sha[:7]}: {files}")
    if not files:
        print("No deployable SQL changes.")
        return 0

    objs = {(s, n) for f in files for _, _, s, n in definitions(read(f))}
    pre_existing = existing_prod_tables(objs)
    log, applied, failure = [], [], None
    for f in files:
        tag = f"gh:prod:{sha[:12]}:{run_id}:{f}"
        start = now_iso()
        try:
            sf(f"ALTER SESSION SET QUERY_TAG = '{tag}';\n{read(f)}")
            applied.append(f)
            log.append(dict(deploy_id=run_id, git_sha=sha, actor=actor, file_path=f, action="DEPLOY",
                            status="SUCCESS", query_tag=tag, message="", started_at=start, finished_at=now_iso()))
            print(f"  applied {f}")
        except SqlError as e:
            failure = f"{f}: {e}"
            log.append(dict(deploy_id=run_id, git_sha=sha, actor=actor, file_path=f, action="DEPLOY",
                            status="FAILED", query_tag=tag, message=str(e), started_at=start, finished_at=now_iso()))
            print(f"  FAILED {f}: {e}")
            break

    if not failure:
        start = now_iso()
        fails = smoke_test(objs, force_fail=a.force_smoke_failure)
        log.append(dict(deploy_id=run_id, git_sha=sha, actor=actor, file_path="(all changed objects)",
                        action="SMOKE_TEST", status="FAILED" if fails else "SUCCESS",
                        query_tag=f"gh:prod:{sha[:12]}:{run_id}:smoke", message="; ".join(fails)[:3900],
                        started_at=start, finished_at=now_iso()))
        print("  smoke: " + ("; ".join(fails) if fails else "healthy"))
        if fails:
            failure = "smoke test: " + "; ".join(fails)

    if failure:
        log += rollback(objs, pre_existing, applied, run_id, sha, actor)
        log_rows(log)
        print(f"[DEPLOY prod] FAILED and rolled back: {failure}")
        return 1

    log_rows(log)
    if os.environ.get("GITHUB_ACTIONS"):
        update_last_good(sha)
    print(f"[DEPLOY prod] SUCCESS ({len(applied)} file(s)); prod-last-good -> {sha[:7]}")
    return 0


def rollback(objs, pre_existing, applied, run_id, sha, actor):
    """New objects are dropped; changed objects are re-applied from the prod-last-good tag."""
    entries = []
    tag = f"gh:prod:{sha[:12]}:{run_id}:rollback"
    kinds = {}
    for f in applied:
        for _, kind, s, n in definitions(read(f)):
            kinds[(s, n)] = kind
    for s, n in sorted(objs - pre_existing):
        start = now_iso()
        kind = kinds.get((s, n), "TABLE")
        try:
            sf(f"ALTER SESSION SET QUERY_TAG = '{tag}';\nUSE ROLE PROD_GH_ACTIONS_DEPLOY_RL;\n"
               f"DROP {kind} IF EXISTS {PROD_DB}.{s}.{n}")
            entries.append(dict(deploy_id=run_id, git_sha=sha, actor=actor, file_path=f"{s}.{n}",
                                action="ROLLBACK", status="SUCCESS", query_tag=tag,
                                message=f"dropped new {kind.lower()}", started_at=start, finished_at=now_iso()))
            print(f"  rollback: dropped new {kind.lower()} {s}.{n}")
        except SqlError as e:
            entries.append(dict(deploy_id=run_id, git_sha=sha, actor=actor, file_path=f"{s}.{n}",
                                action="ROLLBACK", status="FAILED", query_tag=tag, message=str(e),
                                started_at=start, finished_at=now_iso()))
    for f in applied:
        if not ({(s, n) for _, _, s, n in definitions(read(f))} & pre_existing):
            continue
        start = now_iso()
        try:
            old = git("show", f"prod-last-good:{f}")
            sf(f"ALTER SESSION SET QUERY_TAG = '{tag}';\n{old}")
            status, msg = "SUCCESS", "re-applied from prod-last-good"
        except (subprocess.CalledProcessError, SqlError) as e:
            status, msg = "FAILED", f"could not restore from prod-last-good: {e}"
        entries.append(dict(deploy_id=run_id, git_sha=sha, actor=actor, file_path=f, action="ROLLBACK",
                            status=status, query_tag=tag, message=msg, started_at=start, finished_at=now_iso()))
        print(f"  rollback: {f}: {msg}")
    return entries


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pr-check"); p.add_argument("--pr", required=True)
    p.add_argument("--base", required=True); p.add_argument("--head", required=True)
    p = sub.add_parser("pr-cleanup"); p.add_argument("--pr", required=True)
    p = sub.add_parser("sweep"); p.add_argument("--max-age-hours", type=float, default=24)
    p = sub.add_parser("deploy"); p.add_argument("--before", default="")
    p.add_argument("--after", default="HEAD")
    p.add_argument("--force-smoke-failure", action="store_true",
                   help="rollback drill: fail the smoke test on purpose")
    a = ap.parse_args()
    for attr in ("after", "head"):
        if getattr(a, attr, None) == "HEAD":
            setattr(a, attr, git("rev-parse", "HEAD").strip())
    return {"pr-check": cmd_pr_check, "pr-cleanup": cmd_pr_cleanup,
            "sweep": cmd_sweep, "deploy": cmd_deploy}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
