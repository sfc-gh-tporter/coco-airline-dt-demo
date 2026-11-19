#!/usr/bin/env python3
"""DBT-Actions/scripts/ci/dbt_ci.py - CI/CD steps for the dbt dynamic table DAG (stdlib only).

Every Snowflake call goes through the Snowflake CLI:
  - GitHub Actions: `-x` temporary connection from SNOWFLAKE_* env vars; the
    snowflakedb/snowflake-actions@v3 step (use-oidc: true) supplies the OIDC token.
  - Local runs:     SNOWFLAKE_CONNECTION_NAME=<name> (plus SNOWFLAKE_ROLE / SNOWFLAKE_WAREHOUSE).
Run from DBT-Actions/ (the workflows set working-directory). Steps share results through a JSON
state file ($DBT_CI_STATE, default ./dbt_ci_state.json).

Pull request (CI identity, role AIRLINE_DBT_CI_RL):
  clone        --db DB        zero-copy clone of prod via the guarded ops.sp_clone_for_ci proc
  deploy       --db DB        deploy the PR's dbt project object into DB
  slice        --db DB        blast radius: models changed vs prod's last run + all downstream
  baseline     --db DB        snapshot the slice (parity baseline) before it is rebuilt
  build        --db DB        dbt build of the slice only (--full-refresh recreates it), tests in DAG order
  parity       --db DB        rebuilt slice vs baseline: rows, existing values, still INCREMENTAL
  report       --pr N --head SHA   sticky PR comment + job summary; fails if any check did
  cleanup      --db DB        drop the PR database

Prod deploy (deploy identity, role AIRLINE_DBT_DEPLOY_RL, behind the dbt-prod approval):
  deploy       --db AIRLINE_DBT_PROD --prod   update the prod dbt project object
  slice        --db AIRLINE_DBT_PROD --prod   models changed since the last successful prod run
  build        --db AIRLINE_DBT_PROD --prod   recreate only that slice (Snowflake-managed refresh)
  smoke        --db AIRLINE_DBT_PROD          slice DTs exist, ACTIVE, INCREMENTAL, have rows
  record                                      OPS.DEPLOY_LOG rows; move dbt-prod-last-good
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import time

PROD_DB = "AIRLINE_DBT_PROD"
PROD_PROJECT = f"{PROD_DB}.DBT.AIRLINE_DBT_PROD_PROJECT"
DBT_SOURCE = "dbt/airline"
DBT_VERSION = "1.12.3"
PKG_EAI = "AIRLINE_DBT_PKG_EAI"
LAST_GOOD_TAG = "dbt-prod-last-good"
COMMENT_MARKER = "<!-- coco-dbt-ci-report -->"
STATE = os.environ.get("DBT_CI_STATE", "dbt_ci_state.json")
PR_DB_RE = re.compile(r"^AIRLINE_DBT_(PR_\d+|DEV(_[A-Z0-9_]+)?)$")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m|\[[0-9;]*m")

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


def _clean_error(text):
    text = ANSI_RE.sub("", text)
    lines = [l.strip(" │╭╮╰╯─") for l in text.splitlines()]
    msg = re.sub(r"\s+", " ", " ".join(l for l in lines if l and l != "Error")).strip()
    msg = re.sub(r"^\d{6} \([0-9A-Z]{5}\): [0-9a-f-]{36}: ", "", msg)
    return msg[:2000]


def sf(sql):
    """Run statements in ONE session; return the rows of the last statement."""
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
    if data and isinstance(data[0], list):
        data = data[-1]
    return data


def lit(s):
    return "'" + str(s).replace("\\", "\\\\").replace("'", "''") + "'"


def tagged(tag, sql):
    return f"ALTER SESSION SET QUERY_TAG = {lit(tag)};\n{sql}"


def run_tag(step):
    run = f"{os.environ.get('GITHUB_RUN_ID', 'local')}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
    kind = "prod" if os.environ.get("DBT_CI_PROD") else f"pr:{os.environ.get('PR', 'local')}"
    sha = (os.environ.get("HEAD_SHA") or os.environ.get("GITHUB_SHA") or git("rev-parse", "HEAD").strip())[:12]
    return f"gh:dbt:{kind}:{sha}:{run}:{step}"


def dbt(db, args, step, imports_state=False):
    """EXECUTE DBT PROJECT in DB; returns (ok, clean stdout or error text)."""
    project = PROD_PROJECT if db == PROD_DB else f"{db}.DBT.AIRLINE_DBT_PR_PROJECT"
    target = "prod" if db == PROD_DB else "ci"
    env = [f"'DBT_QUERY_TAG' = {lit(run_tag(step))}"]
    if db != PROD_DB:
        env.append(f"'DBT_TARGET_DATABASE' = {lit(db)}")
    sql = (f"EXECUTE DBT PROJECT {project}\n"
           f"  ARGS = {lit(f'{args} --target {target}')}\n"
           f"  ENV_VARS = ({', '.join(env)})")
    if imports_state:
        sql += f"\n  IMPORTS = (SYSTEM$DBT_GET_LAST_SUCCESSFUL_RUN_TARGET({lit(PROD_PROJECT)}) AS 'state')"
    try:
        rows = sf(tagged(run_tag(step), sql))
    except SqlError as e:
        return False, str(e)
    row = rows[0] if rows else {}
    out = ANSI_RE.sub("", str(row.get("STDOUT", "")))
    ok = str(row.get("0|1 SUCCESS", row.get("SUCCESS", True))).upper() not in ("FALSE", "0")
    return ok, out if ok else (str(row.get("EXCEPTION")) + " " + out)


# --------------------------------------------------------------------------- git / gh / state
def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, check=True).stdout


def gh_api(*a):
    p = subprocess.run(["gh", "api", *a], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip())
    return json.loads(p.stdout) if p.stdout.strip() else None


def repo_slug():
    return os.environ.get("GITHUB_REPOSITORY") or subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
        capture_output=True, text=True).stdout.strip()


def load_state():
    if os.path.exists(STATE):
        with open(STATE) as fh:
            return json.load(fh)
    return {"checks": [], "log": []}


def save_state(st):
    with open(STATE, "w") as fh:
        json.dump(st, fh, indent=2)


def summary(md):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as fh:
            fh.write(md + "\n")


def check(st, name, status, detail, secs=None, step=None):
    st.setdefault("checks", []).append({"name": name, "status": status, "detail": detail, "secs": secs})
    if step:
        st.setdefault("log", []).append({"step": step, "status": {"PASS": "SUCCESS", "FAIL": "FAILED"}.get(status, status),
                                         "message": detail[:3900], "query_tag": run_tag(step.lower()),
                                         "started_at": now_iso(-(secs or 0)), "finished_at": now_iso()})
    save_state(st)
    print(f"{status}: {name} - {detail}" + (f" ({secs:.0f}s)" if secs is not None else ""))
    return 0 if status != "FAIL" else 1


def now_iso(offset_s=0):
    return (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=offset_s)).isoformat()


def model_names():
    return {os.path.splitext(os.path.basename(p))[0] for p in glob.glob(f"{DBT_SOURCE}/models/**/*.sql", recursive=True)}


def guard_db(db):
    if db != PROD_DB and not PR_DB_RE.match(db.upper()):
        raise SystemExit(f"refusing to use database {db}: expected AIRLINE_DBT_PR_<n>")


# --------------------------------------------------------------------------- steps
def cmd_clone(a):
    guard_db(a.db)
    st = load_state()
    t = time.time()
    try:
        res = sf(tagged(run_tag("clone"), f"CALL {PROD_DB}.OPS.SP_CLONE_FOR_CI({lit(a.db)})"))
        msg = str(next(iter(res[0].values()))) if res else ""
    except SqlError as e:
        return check(st, "Clone prod", "FAIL", str(e), time.time() - t)
    if msg.startswith("refused"):
        return check(st, "Clone prod", "FAIL", msg, time.time() - t)
    return check(st, "Clone prod", "PASS", f"zero-copy clone `{a.db.lower()}` (suspended DTs, no compute)",
                 time.time() - t)


def cmd_deploy(a):
    guard_db(a.db)
    st = load_state()
    name = "AIRLINE_DBT_PROD_PROJECT" if a.prod else "AIRLINE_DBT_PR_PROJECT"
    cmd = ["snow", "dbt", "deploy", name, "--source", DBT_SOURCE, "--database", a.db, "--schema", "DBT",
           "--dbt-version", DBT_VERSION, "--external-access-integration", PKG_EAI, *conn_args()]
    if a.prod:
        cmd += ["--default-target", "prod"]
    t = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        return check(st, "Deploy dbt project", "FAIL", _clean_error(p.stderr or p.stdout), time.time() - t,
                     step="DEPLOY_PROJECT" if a.prod else None)
    return check(st, "Deploy dbt project", "PASS", f"`{a.db.lower()}.dbt.{name.lower()}` (dbt {DBT_VERSION}, deps installed)",
                 time.time() - t, step="DEPLOY_PROJECT" if a.prod else None)


def cmd_slice(a):
    st = load_state()
    t = time.time()
    ok, out = dbt(a.db, "ls --selector changed_slice --resource-type model --output name --state ./imports/state",
                  "slice", imports_state=True)
    if not ok:
        return check(st, "Blast radius", "FAIL", out, time.time() - t)
    known = model_names()
    found = [w for w in re.findall(r"[a-z_][a-z0-9_]*", out.split("macros", 1)[-1]) if w in known]
    st["slice"] = sorted(dict.fromkeys(found), key=found.index)
    save_state(st)
    if not st["slice"]:
        return check(st, "Blast radius", "SKIP", "no model changes vs prod's last run", time.time() - t)
    untouched = sorted(known - set(st["slice"]))
    detail = (f"{len(st['slice'])} of {len(known)} models: " + ", ".join(f"`{m}`" for m in st["slice"])
              + (f" (not rebuilt: {', '.join(untouched)})" if untouched else ""))
    return check(st, "Blast radius", "PASS", detail, time.time() - t)


def _models_arg(st):
    return '--args "{models: \'' + ",".join(st["slice"]) + '\'}"'


def cmd_baseline(a):
    st = load_state()
    if not st.get("slice"):
        return 0
    t = time.time()
    ok, out = dbt(a.db, f"run-operation snapshot_parity_baseline {_models_arg(st)}", "baseline")
    if not ok:
        return check(st, "Parity baseline", "FAIL", out, time.time() - t)
    return check(st, "Parity baseline", "PASS", f"zero-copy snapshot of {len(st['slice'])} model(s)", time.time() - t)


def cmd_build(a):
    st = load_state()
    if not st.get("slice"):
        return check(st, "Build slice", "SKIP", "nothing to build", 0, step="BUILD_SLICE" if a.prod else None)
    t = time.time()
    ok, out = dbt(a.db, "build --selector changed_slice --full-refresh --state ./imports/state", "build",
                  imports_state=True)
    secs = time.time() - t
    done = re.search(r"Done\. PASS=(\d+) WARN=(\d+) ERROR=(\d+) SKIP=(\d+)", out)
    bad = re.findall(r"\d+ of \d+ (?:FAIL|ERROR)[^\n\[]*?(?:test|model) ([\w.]+)", out)
    step = "BUILD_SLICE" if a.prod else None
    if not ok or (done and int(done.group(3)) > 0) or bad:
        detail = (f"failed: {', '.join(bad)}" if bad else out[:600])
        return check(st, "Build + test slice", "FAIL", detail, secs, step=step)
    tests = len(re.findall(r" of \d+ PASS ", out))
    detail = (f"{len(st['slice'])} model(s) recreated, {tests} test(s) passed"
              + (f" ({done.group(0)})" if done else ""))
    return check(st, "Build + test slice", "PASS", detail, secs, step=step)


def cmd_parity(a):
    st = load_state()
    if not st.get("slice"):
        return 0
    t = time.time()
    ok, out = dbt(a.db, f"run-operation assert_parity {_models_arg(st)}", "parity")
    rows = []
    for line in re.findall(r"PARITY\|[^\n]*?(?=\s+\d{2}:\d{2}:\d{2}|\s*$|\s+parity )", out):
        f = line.split("|")
        if len(f) >= 10:
            rows.append(dict(model=f[1], base=f[2], cur=f[3], only_base=f[4], only_cur=f[5], added=f[6],
                             mode=f[7], status=f[8], problems=f[9]))
    st["parity"] = rows
    save_state(st)
    if not ok:
        failed = [r["model"] for r in rows if r["status"] == "FAIL"]
        return check(st, "Parity", "FAIL", ("failed: " + ", ".join(failed)) if failed else out[:600], time.time() - t)
    return check(st, "Parity", "PASS", f"{len(rows)} model(s): row counts and existing columns unchanged, still INCREMENTAL",
                 time.time() - t)


def cmd_smoke(a):
    st = load_state()
    if not st.get("slice"):
        return check(st, "Smoke test", "SKIP", "no models deployed", 0, step="SMOKE_TEST")
    t = time.time()
    fails, ok = [], []
    rows = sf(tagged(run_tag("smoke"), f"SHOW DYNAMIC TABLES IN DATABASE {a.db}"))
    by_name = {r["name"].lower(): r for r in rows}
    for m in st["slice"]:
        r = by_name.get(m)
        if not r:
            fails.append(f"{m} missing")
        elif r["refresh_mode"] != "INCREMENTAL" or (r.get("refresh_mode_reason") or "").strip():
            fails.append(f"{m} is {r['refresh_mode']}")
        elif r["scheduling_state"] != "ACTIVE":
            fails.append(f"{m} is {r['scheduling_state']}")
        elif not int(r.get("rows") or 0):
            fails.append(f"{m} has no rows")
        else:
            ok.append(f"{m} ({int(r['rows']):,} rows)")
    if fails:
        return check(st, "Smoke test", "FAIL", "; ".join(fails), time.time() - t, step="SMOKE_TEST")
    return check(st, "Smoke test", "PASS", "ACTIVE + INCREMENTAL: " + ", ".join(ok), time.time() - t, step="SMOKE_TEST")


def cmd_report(a):
    st = load_state()
    checks = st.get("checks", [])
    failed = [c for c in checks if c["status"] == "FAIL"]
    verdict = "FAILED" if failed else "PASSED"
    total = sum(c.get("secs") or 0 for c in checks)
    lines = [COMMENT_MARKER, f"## dbt Slim CI {verdict} for `{a.head[:7]}`", ""]
    if st.get("slice"):
        lines += [f"**Blast radius:** {len(st['slice'])} model(s) rebuilt in a zero-copy clone of prod; "
                  f"everything upstream was reused, not recomputed.", "",
                  ", ".join(f"`{m}`" for m in st["slice"]), ""]
    lines += ["| Check | Result | Details | Time |", "|---|---|---|---|"]
    for c in checks:
        secs = f"{c['secs']:.0f}s" if c.get("secs") is not None else ""
        lines.append(f"| {c['name']} | **{c['status']}** | {c['detail'].replace('|', '/')} | {secs} |")
    if st.get("parity"):
        lines += ["", "### Parity vs prod (same snapshot)", "",
                  "| Model | Rows before | Rows after | Changed rows | New columns | Refresh mode | Result |",
                  "|---|---|---|---|---|---|---|"]
        for r in st["parity"]:
            changed = "-" if r["only_base"] == "-" else f"{r['only_base']} / {r['only_cur']}"
            lines.append(f"| `{r['model']}` | {r['base']} | {r['cur']} | {changed} | {r['added']} | {r['mode']} | "
                         f"**{r['status']}** |")
    lines += ["", f"Total {total:.0f}s. The PR database is dropped at the end of every run."]
    if failed:
        lines += ["", "Fix the failing check and push to this branch; CI re-runs automatically."]
    body = "\n".join(lines)
    summary(body)
    print(body)
    if os.environ.get("GITHUB_ACTIONS") and a.pr:
        slug = repo_slug()
        existing = gh_api(f"repos/{slug}/issues/{a.pr}/comments", "--paginate") or []
        mine = [c for c in existing if COMMENT_MARKER in (c.get("body") or "")]
        if mine:
            gh_api("-X", "PATCH", f"repos/{slug}/issues/comments/{mine[-1]['id']}", "-f", f"body={body}")
        else:
            gh_api("-X", "POST", f"repos/{slug}/issues/{a.pr}/comments", "-f", f"body={body}")
    return 1 if failed else 0


def cmd_cleanup(a):
    guard_db(a.db)
    if a.db == PROD_DB:
        raise SystemExit("refusing to drop prod")
    sf(tagged(run_tag("cleanup"), f"DROP DATABASE IF EXISTS {a.db}"))
    print(f"Dropped {a.db}")
    return 0


def cmd_record(a):
    st = load_state()
    log = st.get("log", [])
    if not log:
        print("Nothing to record.")
        return 0
    sha = os.environ.get("GITHUB_SHA") or git("rev-parse", "HEAD").strip()
    run = f"{os.environ.get('GITHUB_RUN_ID', 'local')}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
    actor = os.environ.get("GITHUB_ACTOR", os.environ.get("USER", "local"))
    models = " ".join(st.get("slice", []))
    vals = ",\n".join(
        f"({lit(run)}, {lit(sha)}, {lit(actor)}, {lit(e['step'])}, {lit(e['status'])}, {lit(models)}, "
        f"{lit(e['query_tag'])}, {lit(e['message'])}, {lit(e['started_at'])}::TIMESTAMP_LTZ, "
        f"{lit(e['finished_at'])}::TIMESTAMP_LTZ)" for e in log)
    sf(tagged(run_tag("record"), f"INSERT INTO {PROD_DB}.OPS.DEPLOY_LOG (deploy_id, git_sha, actor, step, status, models, "
                                 f"query_tag, message, started_at, finished_at) VALUES\n{vals}"))
    print(f"Wrote {len(log)} row(s) to {PROD_DB}.OPS.DEPLOY_LOG (deploy_id {run})")
    summary("### Deploy log\n| Step | Status | Details |\n|---|---|---|\n" +
            "\n".join(f"| {e['step']} | {e['status']} | {e['message'].replace('|', '/')} |" for e in log))
    healthy = all(e["status"] in ("SUCCESS", "SKIPPED") for e in log)
    if healthy and os.environ.get("GITHUB_ACTIONS"):
        slug = repo_slug()
        try:
            gh_api("-X", "PATCH", f"repos/{slug}/git/refs/tags/{LAST_GOOD_TAG}", "-f", f"sha={sha}", "-F", "force=true")
        except RuntimeError:
            gh_api("-X", "POST", f"repos/{slug}/git/refs", "-f", f"ref=refs/tags/{LAST_GOOD_TAG}", "-f", f"sha={sha}")
        print(f"{LAST_GOOD_TAG} -> {sha[:7]}")
    return 0 if healthy else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("clone", "deploy", "slice", "baseline", "build", "parity", "smoke", "cleanup"):
        p = sub.add_parser(name)
        p.add_argument("--db", required=True, type=str.upper)
        p.add_argument("--prod", action="store_true")
    p = sub.add_parser("report"); p.add_argument("--pr", default=""); p.add_argument("--head", default="HEAD")
    sub.add_parser("record")
    a = ap.parse_args()
    if getattr(a, "prod", False):
        os.environ["DBT_CI_PROD"] = "1"
        if a.db != PROD_DB:
            raise SystemExit("--prod requires --db AIRLINE_DBT_PROD")
    if getattr(a, "head", None) == "HEAD":
        a.head = git("rev-parse", "HEAD").strip()
    return {"clone": cmd_clone, "deploy": cmd_deploy, "slice": cmd_slice, "baseline": cmd_baseline,
            "build": cmd_build, "parity": cmd_parity, "smoke": cmd_smoke, "report": cmd_report,
            "cleanup": cmd_cleanup, "record": cmd_record}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
