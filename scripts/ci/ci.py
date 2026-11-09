#!/usr/bin/env python3
"""scripts/ci/ci.py - thin CI/CD steps for the airline pipeline (stdlib only).

Every Snowflake call goes through the Snowflake CLI (`snow sql`):
  - GitHub Actions: `-x` temporary connection from SNOWFLAKE_* env vars. The
    snowflakedb/snowflake-actions@v3 step (use-oidc: true) supplies the OIDC token.
  - Local runs:     SNOWFLAKE_CONNECTION_NAME=<name> (plus SNOWFLAKE_ROLE / _WAREHOUSE).

Each command is one visible workflow step. Steps share results through a JSON state
file ($CI_STATE, default ./ci_state.json).

Pull request (validation only - data parity is proven in the developer sandbox):
  pr-plan     --pr N --base SHA --head SHA   Which files/objects this PR changes (no Snowflake).
  pr-validate --pr N                         Build the changed objects in AIRLINE_CI.PR_<n>,
                                             reading prod inputs (read-only). Dynamic tables
                                             are created with INITIALIZE = ON_SCHEDULE, so
                                             nothing is computed.
  pr-check-dt                                Changed dynamic tables are INCREMENTAL.
  pr-check-docs                              Changed tables/views have table + column comments.
  pr-report   --pr N --head SHA              Sticky PR comment + job summary; fails if any check did.
  pr-cleanup  --pr N                         Drop AIRLINE_CI.PR_<n>.

Prod deploy (after merge, behind the `prod` environment approval):
  deploy      --before SHA --after SHA       Apply changed SQL (query-tagged); roll back on error.
  smoke       [--force-failure]              Health-check deployed objects; roll back on failure.
  record                                     DEPLOY_LOG rows; move prod-last-good when healthy.
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
PR_SKIP_PREFIXES = ("sql/00_account/", "sql/data_gen/", "sql/ops/")  # not pipeline objects
PROD_SKIP_PREFIXES = ("sql/00_account/",)          # admin bootstrap, never deployed by CI
DEPLOY_ORDER = ["sql/ops/", "sql/staging/tables/", "sql/data_gen/", "sql/curated/tables/",
                "sql/curated/dynamic_tables/", "sql/curated/views/", "sql/curated/tasks/"]
DOCUMENTED_KINDS = ("TABLE", "DYNAMIC TABLE", "VIEW")
COMMENT_MARKER = "<!-- coco-ci-report -->"
STATE = os.environ.get("CI_STATE", "ci_state.json")

REF_RE = re.compile(r"\bAIRLINE_PROD\.(STAGING|CURATED)\.([A-Z0-9_]+)\b", re.I)
DEF_RE = re.compile(
    r"\b(CREATE(?:\s+OR\s+REPLACE)?|ALTER)\s+(?:TRANSIENT\s+)?(DYNAMIC\s+TABLE|TABLE|VIEW|TASK)"
    r"\s+(?:IF\s+NOT\s+EXISTS\s+)?AIRLINE_PROD\.(STAGING|CURATED)\.([A-Z0-9_]+)", re.I)
# The TARGET of a write statement is in prod (reading prod inside a CREATE ... AS is fine).
WRITE_TO_PROD_RE = re.compile(
    r"\b(?:CREATE(?:\s+OR\s+REPLACE)?(?:\s+[A-Z_]+)+?|ALTER(?:\s+[A-Z_]+)+?|DROP(?:\s+[A-Z_]+)+?"
    r"|INSERT\s+(?:OVERWRITE\s+)?INTO|UPDATE|DELETE\s+FROM|MERGE\s+INTO|TRUNCATE(?:\s+[A-Z_]+)*?)"
    r"\s+AIRLINE_PROD\.", re.I)

sys.stdout.reconfigure(line_buffering=True)


# --------------------------------------------------------------------------- snowflake
class SqlError(Exception):
    pass


def conn_args():
    name = os.environ.get("SNOWFLAKE_CONNECTION_NAME")
    if not name:
        return ["-x"]
    args = ["-c", name]
    if os.environ.get("SNOWFLAKE_ROLE"):
        args += ["--role", os.environ["SNOWFLAKE_ROLE"]]
    if os.environ.get("SNOWFLAKE_WAREHOUSE"):
        args += ["--warehouse", os.environ["SNOWFLAKE_WAREHOUSE"]]
    return args


def sf(sql):
    """Run one or more statements in ONE session; return a list of row-dict lists."""
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as fh:
        fh.write(sql)
        path = fh.name
    try:
        p = subprocess.run(["snow", "sql", "-f", path, "--format", "json", *conn_args()],
                           capture_output=True, text=True)
    finally:
        os.unlink(path)
    if p.returncode != 0:
        raise SqlError(_clean_error(p.stderr.strip() or p.stdout))
    out = p.stdout.strip()
    if not out:
        return []
    data = json.loads(out)
    if data and isinstance(data[0], dict):
        data = [data]
    return data


def _clean_error(text):
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)                 # terminal colours
    lines = [l.strip(" │╭╮╰╯─") for l in text.splitlines()]    # CLI error box
    msg = re.sub(r"\s+", " ", " ".join(l for l in lines if l and l != "Error")).strip()
    msg = re.sub(r"^\d{6} \([0-9A-Z]{5}\): [0-9a-f-]{36}: ", "", msg)   # code + query id
    return msg.replace("line 0 at position -1: ", "")[:1500]


def lit(s):
    return "'" + str(s).replace("\\", "\\\\").replace("'", "''") + "'"


# --------------------------------------------------------------------------- git / gh / state
def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, check=True).stdout


def changed_files(base, head):
    return sorted(f for f in git("diff", "--name-only", f"{base}...{head}").splitlines() if f.strip())


def repo_slug():
    return os.environ.get("GITHUB_REPOSITORY") or \
        subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                       capture_output=True, text=True).stdout.strip()


def gh_api(*a):
    p = subprocess.run(["gh", "api", *a], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip())
    return json.loads(p.stdout) if p.stdout.strip() else None


def load_state():
    if os.path.exists(STATE):
        with open(STATE) as fh:
            return json.load(fh)
    return {}


def save_state(st):
    with open(STATE, "w") as fh:
        json.dump(st, fh, indent=2)


def summary(md):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as fh:
            fh.write(md + "\n")


def check_result(st, name, status, detail):
    st.setdefault("checks", []).append({"name": name, "status": status, "detail": detail})
    save_state(st)
    print(f"{status}: {name} - {detail}")
    return 0 if status != "FAIL" else 1


# --------------------------------------------------------------------------- parsing
def read(path):
    with open(path) as fh:
        return fh.read()


def definitions(text):
    """[(verb, kind, schema, name)] for objects a file creates/alters."""
    return [(re.sub(r"\s+", " ", v.upper()), re.sub(r"\s+", " ", k.upper()), s.upper(), n.upper())
            for v, k, s, n in DEF_RE.findall(text)]


def order_key(path):
    for i, prefix in enumerate(DEPLOY_ORDER):
        if path.startswith(prefix):
            return (i, path)
    return (len(DEPLOY_ORDER), path)


def strip_comments(text):
    return re.sub(r"--[^\n]*", "", text)


# --------------------------------------------------------------------------- PR steps
def pr_schema(pr):
    return f"{CI_DB}.PR_{pr}"


def render_for_pr(text, pr, defined):
    """Build the PR's objects in AIRLINE_CI.PR_<n>; everything else is read from prod."""
    def repl(m):
        if (m.group(1).upper(), m.group(2).upper()) in defined:
            return f"{pr_schema(pr)}.{m.group(2)}"
        return m.group(0)
    out = REF_RE.sub(repl, text)
    out = re.sub(r"^\s*USE\s+ROLE\s+[^;]+;\s*$", "", out, flags=re.I | re.M)
    out = re.sub(r"\bWAREHOUSE\s*=\s*" + PROD_WH + r"\b", f"WAREHOUSE = {CI_WH}", out, flags=re.I)
    out = re.sub(r"\bUSE\s+WAREHOUSE\s+" + PROD_WH + r"\b", f"USE WAREHOUSE {CI_WH}", out, flags=re.I)
    # Validate the definition without computing it: no initial refresh in CI.
    if re.search(r"\bDYNAMIC\s+TABLE\b", out, re.I):
        if re.search(r"\bINITIALIZE\s*=", out, re.I):
            out = re.sub(r"\bINITIALIZE\s*=\s*\w+", "INITIALIZE = ON_SCHEDULE", out, flags=re.I)
        else:
            out = re.sub(r"(\bTARGET_LAG\s*=\s*'[^']*')", r"\1\n  INITIALIZE = ON_SCHEDULE", out,
                         count=1, flags=re.I)
    # Guard: CI may read prod but must only ever write inside AIRLINE_CI.
    if WRITE_TO_PROD_RE.search(strip_comments(out)):
        raise SqlError("refusing to run: rendered SQL would write to AIRLINE_PROD")
    return out


def cmd_pr_plan(a):
    files = [f for f in changed_files(a.base, a.head)
             if f.startswith("sql/") and f.endswith(".sql") and not f.startswith(PR_SKIP_PREFIXES)
             and os.path.exists(f)]
    files.sort(key=order_key)
    objects = []
    for f in files:
        for _, kind, s, n in definitions(read(f)):
            objects.append({"file": f, "kind": kind, "schema": s, "name": n})
    st = {"pr": a.pr, "files": files, "objects": objects, "checks": []}
    save_state(st)
    if not files:
        print("No pipeline SQL changed - nothing to validate in Snowflake.")
        summary("### Plan\nNo pipeline SQL changed.")
        return 0
    print(f"Validating {len(objects)} object(s) from {len(files)} file(s) in {pr_schema(a.pr)}:")
    for o in objects:
        print(f"  {o['kind'].lower():14} {o['schema']}.{o['name']}  ({o['file']})")
    summary("### Plan\n" + "\n".join(f"- `{o['schema'].lower()}.{o['name'].lower()}` "
                                      f"({o['kind'].lower()}) from `{o['file']}`" for o in objects))
    return 0


def cmd_pr_validate(a):
    st = load_state()
    if not st.get("files"):
        return 0
    defined = {(o["schema"], o["name"]) for o in st["objects"]}
    tag = f"gh:pr:{a.pr}"
    sf(f"CREATE OR REPLACE SCHEMA {pr_schema(a.pr)} "
       f"COMMENT = 'PR #{a.pr} validation (dropped at the end of each CI run)'")
    print(f"Created {pr_schema(a.pr)}")
    failed = []
    for f in st["files"]:
        try:
            sql = render_for_pr(read(f), a.pr, defined)
            sf(f"USE WAREHOUSE {CI_WH};\nALTER SESSION SET QUERY_TAG = '{tag}:{f}';\n{sql}")
            print(f"  built {f}")
        except SqlError as e:
            failed.append(f"`{f}`: {e}")
            print(f"  FAILED {f}: {e}")
    if failed:
        return check_result(st, "Build", "FAIL", "; ".join(failed))
    return check_result(st, "Build", "PASS",
                        f"{len(st['files'])} file(s) built against prod inputs (read-only)")


def cmd_pr_check_dt(a):
    st = load_state()
    dts = [o for o in st.get("objects", []) if o["kind"] == "DYNAMIC TABLE"]
    if not dts:
        return check_result(st, "Refresh mode", "SKIP", "no dynamic tables changed") if st.get("files") else 0
    if not any(c["name"] == "Build" and c["status"] == "PASS" for c in st.get("checks", [])):
        return check_result(st, "Refresh mode", "SKIP", "build failed")
    res = sf(f"SHOW DYNAMIC TABLES IN SCHEMA {pr_schema(st['pr'])}")
    wanted = {o["name"] for o in dts}
    found = {r["name"]: r for r in (res[-1] if res else []) if r["name"] in wanted}
    bad, good = [], []
    for o in dts:
        r = found.get(o["name"])
        if not r:
            bad.append(f"`{o['name'].lower()}` not found")
        elif r["refresh_mode"] != "INCREMENTAL" or (r.get("refresh_mode_reason") or "").strip():
            bad.append(f"`{o['name'].lower()}` is {r['refresh_mode']} ({r.get('refresh_mode_reason') or 'no reason'})")
        else:
            good.append(f"`{o['name'].lower()}` INCREMENTAL")
    if found:   # never let a CI copy start refreshing on a schedule
        sf(";\n".join(f"ALTER DYNAMIC TABLE {pr_schema(st['pr'])}.{n} SUSPEND" for n in found) + ";")
    if bad:
        return check_result(st, "Refresh mode", "FAIL", "; ".join(bad))
    return check_result(st, "Refresh mode", "PASS", ", ".join(good))


def cmd_pr_check_docs(a):
    st = load_state()
    objs = [o for o in st.get("objects", []) if o["kind"] in DOCUMENTED_KINDS]
    if not objs:
        return check_result(st, "Documentation", "SKIP", "no tables or views changed") if st.get("files") else 0
    if not any(c["name"] == "Build" and c["status"] == "PASS" for c in st.get("checks", [])):
        return check_result(st, "Documentation", "SKIP", "build failed")
    schema = f"PR_{st['pr']}"
    names = ", ".join(lit(o["name"]) for o in objs)
    rows = sf(f"SELECT t.table_name, t.comment AS table_comment, c.column_name, c.comment AS column_comment "
              f"FROM {CI_DB}.INFORMATION_SCHEMA.TABLES t "
              f"JOIN {CI_DB}.INFORMATION_SCHEMA.COLUMNS c "
              f"  ON c.table_schema = t.table_schema AND c.table_name = t.table_name "
              f"WHERE t.table_schema = {lit(schema)} AND t.table_name IN ({names}) "
              f"ORDER BY t.table_name, c.ordinal_position")
    rows = rows[-1] if rows else []
    problems, documented, total = [], 0, 0
    for o in objs:
        mine = [r for r in rows if r["TABLE_NAME"] == o["name"]]
        if not mine:
            continue
        missing = [r["COLUMN_NAME"].lower() for r in mine if not (r["COLUMN_COMMENT"] or "").strip()]
        total += len(mine)
        documented += len(mine) - len(missing)
        if not (mine[0]["TABLE_COMMENT"] or "").strip():
            problems.append(f"`{o['name'].lower()}`: no table comment")
        if missing:
            problems.append(f"`{o['name'].lower()}`: {len(missing)}/{len(mine)} columns undocumented "
                            f"({', '.join(missing)})")
    if problems:
        return check_result(st, "Documentation", "FAIL", "; ".join(problems))
    return check_result(st, "Documentation", "PASS", f"table + {documented}/{total} columns documented")


def cmd_pr_report(a):
    st = load_state()
    checks = st.get("checks", [])
    if not st.get("files"):
        checks = [{"name": "Snowflake checks", "status": "SKIP", "detail": "no pipeline SQL changed"}]
    if st.get("files") and not checks:
        checks = [{"name": "Build", "status": "FAIL", "detail": "validation did not run (see the job log)"}]
    failed = [c for c in checks if c["status"] == "FAIL"]
    verdict = "FAILED" if failed else "PASSED"
    lines = [COMMENT_MARKER, f"## CI {verdict} for `{a.head[:7]}`", ""]
    if st.get("files"):
        lines.append(f"Built in `{pr_schema(st['pr'])}` as the read-only CI role, reading prod inputs; "
                     f"dynamic tables created without an initial refresh. The schema is dropped at the "
                     f"end of every run.")
        lines.append("")
    lines += ["| Check | Result | Details |", "|---|---|---|"]
    for c in checks:
        lines.append(f"| {c['name']} | **{c['status']}** | {c['detail'].replace('|', '/')} |")
    lines.append("")
    lines.append("Data parity is not re-run here: it is proven in the developer sandbox before the PR "
                 "(see the commit message).")
    if failed:
        lines.append("")
        lines.append("Fix the failing check and push to this branch; CI re-runs automatically.")
    body = "\n".join(lines)
    summary(body)
    print(body)
    if os.environ.get("GITHUB_ACTIONS") or os.environ.get("CI_POST_COMMENT"):
        slug = repo_slug()
        existing = gh_api(f"repos/{slug}/issues/{a.pr}/comments", "--paginate") or []
        mine = [c for c in existing if COMMENT_MARKER in (c.get("body") or "")]
        if mine:
            gh_api("-X", "PATCH", f"repos/{slug}/issues/comments/{mine[-1]['id']}", "-f", f"body={body}")
        else:
            gh_api("-X", "POST", f"repos/{slug}/issues/{a.pr}/comments", "-f", f"body={body}")
    return 1 if failed else 0


def cmd_pr_cleanup(a):
    sf(f"DROP SCHEMA IF EXISTS {pr_schema(a.pr)}")
    print(f"Dropped {pr_schema(a.pr)}")
    return 0


# --------------------------------------------------------------------------- prod deploy
def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def run_id():
    return f"{os.environ.get('GITHUB_RUN_ID', 'local')}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"


def log_entry(st, file_path, action, status, tag, message, start):
    st.setdefault("log", []).append(dict(
        deploy_id=run_id(), git_sha=st["sha"], actor=st["actor"], file_path=file_path, action=action,
        status=status, query_tag=tag, message=message[:3900], started_at=start, finished_at=now_iso()))
    save_state(st)


def existing_prod_objects(objs):
    if not objs:
        return set()
    preds = " OR ".join(f"(table_schema = {lit(s)} AND table_name = {lit(n)})" for s, n in objs)
    res = sf(f"SELECT table_schema, table_name FROM {PROD_DB}.INFORMATION_SCHEMA.TABLES WHERE {preds}")
    return {(r["TABLE_SCHEMA"], r["TABLE_NAME"]) for r in (res[-1] if res else [])}


def cmd_deploy(a):
    sha = a.after
    if a.before and a.before != "0" * 40:
        files = changed_files(a.before, sha)
    else:
        files = git("ls-files", "sql").splitlines()
    files = sorted((f for f in files if f.endswith(".sql") and f.startswith("sql/")
                    and not f.startswith(PROD_SKIP_PREFIXES) and os.path.exists(f)), key=order_key)
    objs = sorted({(s, n) for f in files for _, _, s, n in definitions(read(f))})
    kinds = {(s, n): k for f in files for _, k, s, n in definitions(read(f))}
    st = {"sha": sha, "actor": os.environ.get("GITHUB_ACTOR", os.environ.get("USER", "local")),
          "files": files, "objects": [list(o) for o in objs],
          "kinds": {f"{s}.{n}": k for (s, n), k in kinds.items()},
          "pre_existing": [list(o) for o in existing_prod_objects(objs)], "applied": [], "log": []}
    save_state(st)
    print(f"Deploying {len(files)} file(s) at {sha[:7]}")
    if not files:
        st["status"] = "NOTHING"
        save_state(st)
        print("No deployable SQL changes.")
        return 0
    for f in files:
        tag = f"gh:prod:{sha[:12]}:{run_id()}:{f}"
        start = now_iso()
        try:
            sf(f"ALTER SESSION SET QUERY_TAG = '{tag}';\n{read(f)}")
            st["applied"].append(f)
            log_entry(st, f, "DEPLOY", "SUCCESS", tag, "", start)
            print(f"  applied {f}  (query tag {tag})")
        except SqlError as e:
            log_entry(st, f, "DEPLOY", "FAILED", tag, str(e), start)
            print(f"  FAILED {f}: {e}")
            rollback(st)
            st["status"] = "ROLLED_BACK"
            save_state(st)
            return 1
    st["status"] = "DEPLOYED"
    save_state(st)
    return 0


def cmd_smoke(a):
    st = load_state()
    if st.get("status") != "DEPLOYED":
        print(f"Skipped (deploy status: {st.get('status', 'unknown')})")
        return 0
    fails, start = [], now_iso()
    for s, n in st["objects"]:
        t = sf(f"SELECT table_type, row_count FROM {PROD_DB}.INFORMATION_SCHEMA.TABLES "
               f"WHERE table_schema = {lit(s)} AND table_name = {lit(n)}")
        t = t[-1] if t else []
        if not t:
            fails.append(f"{s}.{n} does not exist")
            continue
        ok = f"{s}.{n} exists"
        if s == "CURATED":
            if not (t[0]["ROW_COUNT"] or 0) > 0:
                fails.append(f"{s}.{n} has no rows")
            else:
                ok += f", {t[0]['ROW_COUNT']:,} rows"
        if st["kinds"].get(f"{s}.{n}") == "DYNAMIC TABLE":
            d = sf(f"SHOW DYNAMIC TABLES LIKE {lit(n)} IN SCHEMA {PROD_DB}.{s}")
            d = d[-1] if d else []
            if d and d[0]["refresh_mode"] != "INCREMENTAL":
                fails.append(f"{n} refresh_mode is {d[0]['refresh_mode']}")
            elif d:
                ok += ", INCREMENTAL"
        print(f"  {ok}")
    if a.force_failure:
        fails.append("rollback drill: smoke failure forced by workflow input")
    tag = f"gh:prod:{st['sha'][:12]}:{run_id()}:smoke"
    log_entry(st, "(all changed objects)", "SMOKE_TEST", "FAILED" if fails else "SUCCESS", tag,
              "; ".join(fails), start)
    if fails:
        print("Smoke test FAILED: " + "; ".join(fails))
        rollback(st)
        st["status"] = "ROLLED_BACK"
        save_state(st)
        return 1
    st["status"] = "HEALTHY"
    save_state(st)
    print("Smoke test passed")
    return 0


def rollback(st):
    """New objects are dropped; changed objects are re-applied from the prod-last-good tag."""
    tag = f"gh:prod:{st['sha'][:12]}:{run_id()}:rollback"
    pre = {tuple(o) for o in st["pre_existing"]}
    for s, n in st["objects"]:
        if (s, n) in pre:
            continue
        kind = st["kinds"].get(f"{s}.{n}", "TABLE")
        start = now_iso()
        try:
            sf(f"ALTER SESSION SET QUERY_TAG = '{tag}';\nDROP {kind} IF EXISTS {PROD_DB}.{s}.{n}")
            log_entry(st, f"{s}.{n}", "ROLLBACK", "SUCCESS", tag, f"dropped new {kind.lower()}", start)
            print(f"  rollback: dropped new {kind.lower()} {s}.{n}")
        except SqlError as e:
            log_entry(st, f"{s}.{n}", "ROLLBACK", "FAILED", tag, str(e), start)
    for f in st["applied"]:
        if not ({(s, n) for _, _, s, n in definitions(read(f))} & pre):
            continue
        start = now_iso()
        try:
            sf(f"ALTER SESSION SET QUERY_TAG = '{tag}';\n{git('show', f'prod-last-good:{f}')}")
            status, msg = "SUCCESS", "re-applied from prod-last-good"
        except (subprocess.CalledProcessError, SqlError) as e:
            status, msg = "FAILED", f"could not restore from prod-last-good: {e}"
        log_entry(st, f, "ROLLBACK", status, tag, msg, start)
        print(f"  rollback: {f}: {msg}")


def cmd_record(a):
    st = load_state()
    if not st.get("log"):
        print("Nothing to record.")
        return 0
    vals = ",\n".join(
        "(" + ", ".join(lit(e[k]) for k in ("deploy_id", "git_sha", "actor", "file_path", "action",
                                              "status", "query_tag", "message")) +
        f", {lit(e['started_at'])}::TIMESTAMP_LTZ, {lit(e['finished_at'])}::TIMESTAMP_LTZ)"
        for e in st["log"])
    sf(f"INSERT INTO {PROD_DB}.OPS.DEPLOY_LOG (deploy_id, git_sha, actor, file_path, action, status, "
       f"query_tag, message, started_at, finished_at) VALUES\n{vals}")
    print(f"Wrote {len(st['log'])} row(s) to {PROD_DB}.OPS.DEPLOY_LOG (deploy_id {run_id()})")
    md = ["| File / object | Action | Status |", "|---|---|---|"] + \
         [f"| `{e['file_path']}` | {e['action']} | {e['status']} |" for e in st["log"]]
    summary("### Deploy log\n" + "\n".join(md))
    if st.get("status") == "HEALTHY" and os.environ.get("GITHUB_ACTIONS"):
        slug = repo_slug()
        try:
            gh_api("-X", "PATCH", f"repos/{slug}/git/refs/tags/prod-last-good", "-f", f"sha={st['sha']}",
                   "-F", "force=true")
        except RuntimeError:
            gh_api("-X", "POST", f"repos/{slug}/git/refs", "-f", "ref=refs/tags/prod-last-good",
                   "-f", f"sha={st['sha']}")
        print(f"prod-last-good -> {st['sha'][:7]}")
    return 0 if st.get("status") in ("HEALTHY", "NOTHING") else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pr-plan"); p.add_argument("--pr", required=True)
    p.add_argument("--base", required=True); p.add_argument("--head", required=True)
    p = sub.add_parser("pr-validate"); p.add_argument("--pr", required=True)
    sub.add_parser("pr-check-dt")
    sub.add_parser("pr-check-docs")
    p = sub.add_parser("pr-report"); p.add_argument("--pr", required=True); p.add_argument("--head", default="HEAD")
    p = sub.add_parser("pr-cleanup"); p.add_argument("--pr", required=True)
    p = sub.add_parser("deploy"); p.add_argument("--before", default=""); p.add_argument("--after", default="HEAD")
    p = sub.add_parser("smoke"); p.add_argument("--force-failure", action="store_true")
    sub.add_parser("record")
    a = ap.parse_args()
    for attr in ("after", "head"):
        if getattr(a, attr, None) == "HEAD":
            setattr(a, attr, git("rev-parse", "HEAD").strip())
    try:
        return {"pr-plan": cmd_pr_plan, "pr-validate": cmd_pr_validate, "pr-check-dt": cmd_pr_check_dt,
                "pr-check-docs": cmd_pr_check_docs, "pr-report": cmd_pr_report,
                "pr-cleanup": cmd_pr_cleanup, "deploy": cmd_deploy, "smoke": cmd_smoke,
                "record": cmd_record}[a.cmd](a)
    except SqlError as e:
        print(f"Snowflake error: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
