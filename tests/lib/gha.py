#!/usr/bin/env python3
"""A small, local stand-in for GitHub Actions, for this repo's tests only.

Two jobs:

  compare   Works out which steps a reusable workflow + its composite actions
            would run for a given set of caller inputs ("effective steps":
            name, uses, with, env, run, shell, ...), with every ${{ }} that
            depends only on inputs rendered, at two git refs, and diffs them.
            Used for the deploy-type equivalence tests (standard == main,
            atomic == #5's branch).

  run-workflow / run-action
            Executes a workflow's jobs, or one action, on this machine:
            `run:` steps go to bash exactly as Actions would (bash -eo
            pipefail), composite actions under pie/.github/actions/ are
            expanded from the checkout, add-ssh-config/add-ssh-pass are
            skipped (they would write a real SSH config), and any other
            third-party action is skipped. ssh, scp, rsync, curl, wp, mv...
            are expected to be stubbed on PATH (tests/lib/stubs), so nothing
            leaves this machine.

It implements the parts of the expression language this repo uses: literals,
property access, ! == != < <= > >= && ||, contains/startsWith/endsWith/format/
join/toJSON/fromJSON and the status functions. Anything it can't decide
statically (env.*, github.*, secrets.* in compare mode) is kept as a symbol and
rendered as its own `${{ ... }}` text, so both sides of a comparison render it
identically.

Not part of the product. Written by Tess from the brief.
"""
import argparse
import difflib
import json
import math
import os
import re
import subprocess
import sys
import tempfile

import yaml

STUB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stubs")
NOOP_ACTIONS = {"add-ssh-config", "add-ssh-pass"}
PIE_ACTION_RE = re.compile(r"^pie/\.github/actions/([A-Za-z0-9_.-]+)@(.+)$")
VALIDATION_STEP_RE = re.compile(r"deploy[- _]?type", re.I)


class Undecidable(Exception):
    pass


class ExprError(Exception):
    pass


# --------------------------------------------------------------------------
# Expressions
# --------------------------------------------------------------------------

class Sym:
    """A value only known at run time. Renders as its own expression text."""

    def __init__(self, text):
        self.text = text

    def __repr__(self):
        return "Sym(%s)" % self.text

    def get(self, name):
        return Sym("%s.%s" % (self.text, name))


class SymDict(dict):
    """A context whose unknown keys become symbols (compare mode)."""

    def __init__(self, prefix, *a, **kw):
        super().__init__(*a, **kw)
        self.prefix = prefix

    def get(self, key, default=None):
        if key in self:
            return self[key]
        return Sym("%s.%s" % (self.prefix, key))


TOKEN_RE = re.compile(r"""
    (?P<ws>\s+)
  | (?P<num>\d+(?:\.\d+)?)
  | (?P<str>'(?:[^']|'')*')
  | (?P<op>==|!=|<=|>=|&&|\|\||<|>|!|\(|\)|\[|\]|,|\.|\*)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_-]*)
""", re.X)


def tokenize(src):
    pos, out = 0, []
    while pos < len(src):
        m = TOKEN_RE.match(src, pos)
        if not m:
            raise ExprError("cannot parse expression at %r in %r" % (src[pos:], src))
        pos = m.end()
        kind = m.lastgroup
        if kind == "ws":
            continue
        val = m.group(kind)
        if kind == "str":
            val = val[1:-1].replace("''", "'")
        out.append((kind, val))
    out.append(("end", None))
    return out


class Parser:
    def __init__(self, src):
        self.toks = tokenize(src)
        self.i = 0
        self.src = src

    def peek(self):
        return self.toks[self.i]

    def take(self, kind=None, val=None):
        t = self.toks[self.i]
        if kind and t[0] != kind or val is not None and t[1] != val:
            raise ExprError("expected %s %s, got %r in %r" % (kind, val, t, self.src))
        self.i += 1
        return t

    def is_op(self, *vals):
        t = self.peek()
        return t[0] == "op" and t[1] in vals

    def parse(self):
        node = self.or_()
        self.take("end")
        return node

    def or_(self):
        node = self.and_()
        while self.is_op("||"):
            self.take()
            node = ("or", node, self.and_())
        return node

    def and_(self):
        node = self.eq()
        while self.is_op("&&"):
            self.take()
            node = ("and", node, self.eq())
        return node

    def eq(self):
        node = self.rel()
        while self.is_op("==", "!="):
            op = self.take()[1]
            node = (op, node, self.rel())
        return node

    def rel(self):
        node = self.unary()
        while self.is_op("<", "<=", ">", ">="):
            op = self.take()[1]
            node = (op, node, self.unary())
        return node

    def unary(self):
        if self.is_op("!"):
            self.take()
            return ("not", self.unary())
        return self.postfix()

    def postfix(self):
        node = self.primary()
        while True:
            if self.is_op("."):
                self.take()
                t = self.take()
                if t[0] not in ("ident", "num") and t[1] != "*":
                    raise ExprError("bad property in %r" % self.src)
                node = ("prop", node, t[1])
            elif self.is_op("["):
                self.take()
                idx = self.or_()
                self.take("op", "]")
                node = ("index", node, idx)
            else:
                return node

    def primary(self):
        t = self.take()
        if t[0] == "num":
            return ("lit", float(t[1]) if "." in t[1] else int(t[1]))
        if t[0] == "str":
            return ("lit", t[1])
        if t[0] == "op" and t[1] == "(":
            node = self.or_()
            self.take("op", ")")
            return node
        if t[0] == "ident":
            if t[1] == "true":
                return ("lit", True)
            if t[1] == "false":
                return ("lit", False)
            if t[1] == "null":
                return ("lit", None)
            if self.is_op("("):
                self.take()
                args = []
                if not self.is_op(")"):
                    args.append(self.or_())
                    while self.is_op(","):
                        self.take()
                        args.append(self.or_())
                self.take("op", ")")
                return ("call", t[1], args)
            return ("ctx", t[1])
        raise ExprError("unexpected %r in %r" % (t, self.src))


def truthy(v):
    if isinstance(v, Sym):
        raise Undecidable(v.text)
    if v is None or v is False:
        return False
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return v != 0 and not (isinstance(v, float) and math.isnan(v))
    if isinstance(v, str):
        return v != ""
    return True


def to_number(v):
    if v is None:
        return 0
    if isinstance(v, bool):
        return 1 if v else 0
    if isinstance(v, (int, float)):
        return v
    if isinstance(v, str):
        s = v.strip()
        if s == "":
            return 0
        try:
            if re.fullmatch(r"0x[0-9a-fA-F]+", s):
                return int(s, 16)
            return float(s)
        except ValueError:
            return float("nan")
    return float("nan")


def loose_eq(a, b):
    if isinstance(a, Sym) or isinstance(b, Sym):
        raise Undecidable("comparison with run-time value")
    if type(a) is type(b) or (isinstance(a, (int, float)) and isinstance(b, (int, float))
                              and not isinstance(a, bool) and not isinstance(b, bool)):
        if isinstance(a, str):
            return a.lower() == b.lower()
        if isinstance(a, (dict, list)):
            return a is b
        return a == b
    if isinstance(a, (dict, list)) or isinstance(b, (dict, list)):
        return False
    na, nb = to_number(a), to_number(b)
    if isinstance(na, float) and math.isnan(na) or isinstance(nb, float) and math.isnan(nb):
        return False
    return na == nb


def compare(op, a, b):
    if isinstance(a, Sym) or isinstance(b, Sym):
        raise Undecidable("comparison with run-time value")
    if isinstance(a, str) and isinstance(b, str):
        a, b = a.lower(), b.lower()
    else:
        a, b = to_number(a), to_number(b)
        if any(isinstance(x, float) and math.isnan(x) for x in (a, b)):
            return False
    return {"<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b}[op]


def to_str(v):
    if isinstance(v, Sym):
        return "${{ %s }}" % v.text
    if v is None:
        return ""
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, float):
        if v.is_integer():
            return str(int(v))
        return repr(v)
    if isinstance(v, int):
        return str(v)
    if isinstance(v, (dict, list)):
        return json.dumps(v)
    return str(v)


def get_prop(obj, name):
    if isinstance(obj, Sym):
        return obj.get(name)
    if isinstance(obj, SymDict):
        return obj.get(name)
    if isinstance(obj, dict):
        if name in obj:
            return obj[name]
        for k in obj:  # contexts are case-insensitive
            if isinstance(k, str) and k.lower() == str(name).lower():
                return obj[k]
        return None
    if isinstance(obj, list):
        try:
            return obj[int(name)]
        except (ValueError, IndexError):
            return None
    return None


def evaluate(node, ctx):
    kind = node[0]
    if kind == "lit":
        return node[1]
    if kind == "ctx":
        name = node[1]
        if name not in ctx:
            raise ExprError("unknown context %r" % name)
        return ctx[name]
    if kind == "prop":
        return get_prop(evaluate(node[1], ctx), node[2])
    if kind == "index":
        return get_prop(evaluate(node[1], ctx), to_str(evaluate(node[2], ctx)))
    if kind == "not":
        return not truthy(evaluate(node[1], ctx))
    if kind == "and":
        left = evaluate(node[1], ctx)
        return left if not truthy(left) else evaluate(node[2], ctx)
    if kind == "or":
        left = evaluate(node[1], ctx)
        return left if truthy(left) else evaluate(node[2], ctx)
    if kind == "==":
        return loose_eq(evaluate(node[1], ctx), evaluate(node[2], ctx))
    if kind == "!=":
        return not loose_eq(evaluate(node[1], ctx), evaluate(node[2], ctx))
    if kind in ("<", "<=", ">", ">="):
        return compare(kind, evaluate(node[1], ctx), evaluate(node[2], ctx))
    if kind == "call":
        return call(node[1], [evaluate(a, ctx) for a in node[2]], ctx)
    raise ExprError("bad node %r" % (node,))


def call(name, args, ctx):
    n = name.lower()
    status = ctx.get("__status__", "success")
    if n == "success":
        return status == "success"
    if n == "failure":
        return status == "failure"
    if n == "always":
        return True
    if n == "cancelled":
        return False
    if any(isinstance(a, Sym) for a in args):
        if n == "format":
            return Sym("format(...)")
        raise Undecidable("%s() of a run-time value" % name)
    if n == "contains":
        hay, needle = args
        if isinstance(hay, list):
            return any(loose_eq(x, needle) for x in hay)
        return to_str(needle).lower() in to_str(hay).lower()
    if n == "startswith":
        return to_str(args[0]).lower().startswith(to_str(args[1]).lower())
    if n == "endswith":
        return to_str(args[0]).lower().endswith(to_str(args[1]).lower())
    if n == "format":
        fmt = to_str(args[0])
        return re.sub(r"\{(\d+)\}", lambda m: to_str(args[1 + int(m.group(1))]), fmt)
    if n == "join":
        sep = to_str(args[1]) if len(args) > 1 else ","
        return sep.join(to_str(x) for x in args[0]) if isinstance(args[0], list) else to_str(args[0])
    if n == "tojson":
        return json.dumps(args[0], indent=2)
    if n == "fromjson":
        return json.loads(to_str(args[0]))
    if n == "hashfiles":
        return Sym("hashFiles(...)")
    raise ExprError("unsupported function %s()" % name)


EXPR_RE = re.compile(r"\$\{\{(.*?)\}\}", re.S)


def eval_expr(src, ctx):
    return evaluate(Parser(src.strip()).parse(), ctx)


def render(value, ctx):
    """Render a YAML scalar the way Actions does: ${{ }} replaced in strings."""
    if value is None:
        return None
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return to_str(value)
    if isinstance(value, str):
        m = EXPR_RE.fullmatch(value.strip())
        if m and value.strip() == value:
            return to_str(eval_expr(m.group(1), ctx))
        return EXPR_RE.sub(lambda mm: to_str(eval_expr(mm.group(1), ctx)), value)
    if isinstance(value, dict):
        return {k: render(v, ctx) for k, v in value.items()}
    if isinstance(value, list):
        return [render(v, ctx) for v in value]
    return value


STATUS_FN_RE = re.compile(r"\b(success|failure|always|cancelled)\s*\(", re.I)


def eval_if(cond, ctx):
    """True if a step/job with this `if:` runs, given ctx['__status__']."""
    if cond is None:
        cond = "success()"
    if isinstance(cond, bool):
        return cond and ctx.get("__status__", "success") == "success"
    s = str(cond).strip()
    m = EXPR_RE.fullmatch(s)
    if m:
        s = m.group(1).strip()
    val = truthy(eval_expr(s, ctx))
    if not STATUS_FN_RE.search(s):
        val = val and ctx.get("__status__", "success") == "success"
    return val


# --------------------------------------------------------------------------
# Loading workflows and actions
# --------------------------------------------------------------------------

class Source:
    """Files at a git ref (ref given) or in the working tree (ref None)."""

    def __init__(self, repo, ref=None):
        self.repo = repo
        self.ref = ref

    def read(self, path):
        if self.ref is None:
            full = os.path.join(self.repo, path)
            if not os.path.exists(full):
                return None
            with open(full, encoding="utf-8") as fh:
                return fh.read()
        res = subprocess.run(["git", "-C", self.repo, "show", "%s:%s" % (self.ref, path)],
                             capture_output=True, text=True)
        if res.returncode != 0:
            return None
        return res.stdout

    def load_yaml(self, path):
        text = self.read(path)
        if text is None:
            raise FileNotFoundError("%s not found at %s" % (path, self.ref or "working tree"))
        return yaml.safe_load(text)

    def action(self, name):
        for fn in ("action.yml", "action.yaml"):
            path = "actions/%s/%s" % (name, fn)
            if self.read(path) is not None:
                return self.load_yaml(path), "actions/%s" % name
        raise FileNotFoundError("action %s not found at %s" % (name, self.ref or "working tree"))


def workflow_call_inputs(wf):
    on = wf.get("on", wf.get(True))
    if not isinstance(on, dict):
        return {}
    wc = on.get("workflow_call") or {}
    return wc.get("inputs") or {}


def typed_input(spec, value):
    kind = (spec or {}).get("type", "string")
    if value is None:
        return None
    if kind == "number":
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return value
        n = to_number(value)
        return int(n) if isinstance(n, float) and n.is_integer() else n
    if kind == "boolean":
        if isinstance(value, bool):
            return value
        return str(value).lower() == "true"
    return to_str(value) if not isinstance(value, str) else value


def resolve_workflow_inputs(wf, given, allow_unknown=False):
    specs = workflow_call_inputs(wf)
    out = {}
    for name, spec in specs.items():
        spec = spec or {}
        if name in given:
            out[name] = typed_input(spec, given[name])
        elif "default" in spec:
            out[name] = typed_input(spec, spec["default"])
        elif spec.get("required"):
            raise ExprError("required input %r not given" % name)
        else:
            out[name] = "" if spec.get("type", "string") == "string" else None
    unknown = set(given) - set(specs)
    if unknown and not allow_unknown:
        raise ExprError("inputs not declared by the workflow: %s" % ", ".join(sorted(unknown)))
    return out


def resolve_action_inputs(action, given):
    specs = action.get("inputs") or {}
    out = {}
    for name, spec in specs.items():
        spec = spec or {}
        if name in given and given[name] is not None:
            out[name] = to_str(given[name])
        elif "default" in spec:
            out[name] = to_str(spec["default"])
        else:
            out[name] = ""
    for name in given:  # undeclared inputs are passed (Actions only warns)
        if name not in out:
            out[name] = to_str(given[name])
    return out


def step_display_name(step, ctx):
    if "name" in step:
        return render(step["name"], ctx)
    if "uses" in step:
        return "Run " + step["uses"]
    first = str(step.get("run", "")).strip().splitlines()
    return "Run " + (first[0] if first else "")


def normalise_uses(uses):
    m = PIE_ACTION_RE.match(uses or "")
    if m:
        return "pie/.github/actions/%s@<ref>" % m.group(1)
    return uses


# --------------------------------------------------------------------------
# compare: effective steps
# --------------------------------------------------------------------------

def compare_ctx(inputs):
    return {
        "inputs": inputs,
        "env": SymDict("env"),
        "github": SymDict("github"),
        "secrets": SymDict("secrets"),
        "steps": SymDict("steps"),
        "needs": SymDict("needs"),
        "runner": SymDict("runner"),
        "vars": SymDict("vars"),
        "job": SymDict("job"),
        "matrix": {},
        "strategy": {},
        "__status__": "success",
    }


def effective_steps(src, steps, ctx, prefix, out, stripped):
    for step in steps or []:
        try:
            runs = eval_if(step.get("if"), ctx)
        except Undecidable as exc:
            raise ExprError("%s: `if: %s` depends on a run-time value (%s)"
                            % (prefix + step_display_name(step, ctx), step.get("if"), exc))
        if not runs:
            continue
        name = step_display_name(step, ctx)
        rec = {"step": prefix + name}
        for key in ("id", "shell", "working-directory", "continue-on-error", "timeout-minutes"):
            if key in step:
                rec[key] = render(step[key], ctx)
        if "env" in step:
            rec["env"] = render(step["env"], ctx)
        if "run" in step:
            rec["run"] = render(step["run"], ctx)
        # Only a plain `run:` step can be the validation step: a `uses:` step
        # with such a name is expanded and compared like any other.
        if "uses" not in step and VALIDATION_STEP_RE.search(name):
            stripped.append(rec)
            continue
        if "uses" in step:
            rec["uses"] = normalise_uses(step["uses"])
            with_vals = render(step.get("with") or {}, ctx)
            m = PIE_ACTION_RE.match(step["uses"])
            if m:
                with_vals = {k: v for k, v in with_vals.items() if k != "deploy-type"}
            rec["with"] = with_vals
            out.append(rec)
            if m:
                action, _ = src.action(m.group(1))
                given = render(step.get("with") or {}, ctx)
                ainputs = resolve_action_inputs(action, given)
                actx = compare_ctx(ainputs)
                runs_block = action.get("runs") or {}
                if runs_block.get("using") == "composite":
                    effective_steps(src, runs_block.get("steps"), actx,
                                    prefix + m.group(1) + " > ", out, stripped)
            continue
        out.append(rec)


def extract(src, workflow_path, caller_with, allow_unknown):
    wf = src.load_yaml(workflow_path)
    inputs = resolve_workflow_inputs(wf, caller_with, allow_unknown)
    ctx = compare_ctx(inputs)
    result, stripped = [], []
    for job_id in sorted(wf.get("jobs") or {}):
        job = wf["jobs"][job_id]
        if not eval_if(job.get("if"), ctx):
            continue
        header = {"job": job_id}
        for key in ("runs-on", "needs", "env", "outputs", "uses", "with", "strategy",
                    "concurrency", "timeout-minutes", "continue-on-error"):
            if key in job:
                header[key] = render(job[key], ctx)
        result.append(header)
        effective_steps(src, job.get("steps"), ctx, job_id + " > ", result, stripped)
    return result, stripped


def run_pure(rec, scenario_dir, rsyncignore):
    """Run a step's rendered `run:` alone, with every external command stubbed.

    Returns what it did: exit code, stdout, what it wrote to GITHUB_ENV/OUTPUT,
    and any stubbed command it called."""
    work = tempfile.mkdtemp(dir=scenario_dir)
    if rsyncignore:
        with open(os.path.join(work, ".rsyncignore"), "w") as fh:
            fh.write("node_modules\n")
    files = {k: os.path.join(work, ".." + k) for k in ("GITHUB_ENV", "GITHUB_OUTPUT")}
    for f in files.values():
        open(f, "w").close()
    log = os.path.join(work, "..stub.log")
    open(log, "w").close()
    env = {"PATH": STUB_DIR + os.pathsep + os.environ.get("PATH", ""), "HOME": work,
           "STUB_LOG": log, "STUB_REMOTE_HOME": work, "LANG": "C"}
    env.update(files)
    for k, v in (rec.get("env") or {}).items():
        env[k] = v
    script = os.path.join(work, "..step.sh")
    with open(script, "w") as fh:
        fh.write(rec.get("run", ""))
    res = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", script],
                         cwd=work, env=env, capture_output=True, text=True)
    read = lambda p: open(p).read()
    return {"exit": res.returncode, "stdout": res.stdout,
            "GITHUB_ENV": read(files["GITHUB_ENV"]), "GITHUB_OUTPUT": read(files["GITHUB_OUTPUT"]),
            "stub_calls": read(log)}


def same_effect(a, b, tmp):
    """Two steps whose only difference is the `run:` text, compared by effect."""
    if {k: v for k, v in a.items() if k != "run"} != {k: v for k, v in b.items() if k != "run"}:
        return False
    for ignore in (False, True):
        ra, rb = run_pure(a, tmp, ignore), run_pure(b, tmp, ignore)
        if ra["stub_calls"] or rb["stub_calls"]:
            return False  # talks to the outside world: only identical text will do
        if ra != rb:
            return False
    return True


def dump(steps):
    return json.dumps(steps, indent=2, sort_keys=True).splitlines()


def cmd_compare(args):
    with open(args.callers) as fh:
        callers = yaml.safe_load(fh)["callers"]
    if args.only:
        callers = [c for c in callers if c["id"] in args.only]
    base = Source(args.repo, args.base_ref)
    head = Source(args.repo, None if args.head_ref in (None, "WORKTREE") else args.head_ref)
    failures = 0
    tmp = tempfile.mkdtemp(prefix="gha-compare.")
    for caller in callers:
        given = dict(caller.get("with") or {})
        base_with = dict(given)
        head_with = dict(given)
        if args.deploy_type is not None:
            head_with["deploy-type"] = args.deploy_type
        label = "%s [deploy-type: %s]" % (caller["id"], args.deploy_type or "(not passed)")
        try:
            b_steps, _ = extract(base, args.workflow, base_with, allow_unknown=False)
            h_steps, h_stripped = extract(head, args.workflow, head_with, allow_unknown=False)
        except (ExprError, FileNotFoundError) as exc:
            print("FAIL %s: %s" % (label, exc))
            failures += 1
            continue
        problems = []
        if b_steps != h_steps:
            ok = len(b_steps) == len(h_steps) and args.effect_equal_run
            if ok:
                for a, b in zip(b_steps, h_steps):
                    if a == b:
                        continue
                    if not ("run" in a and "run" in b and same_effect(a, b, tmp)):
                        ok = False
                        break
            if not ok:
                diff = difflib.unified_diff(dump(b_steps), dump(h_steps),
                                            "%s (%s)" % (args.workflow, args.base_ref),
                                            "%s (%s)" % (args.workflow, args.head_ref or "working tree"),
                                            lineterm="", n=4)
                problems.append("effective steps differ:\n" + "\n".join(diff))
        # The deploy-type validation step is the one allowed addition. It must
        # be there, and for a valid value it must do nothing observable.
        if args.expect_validation and not h_stripped:
            problems.append("no deploy-type validation step ran (a step whose name contains 'deploy-type')")
        if len(h_stripped) > 1:
            problems.append("more than one step was set aside as the validation step (only one is allowed): %s"
                            % ", ".join(r["step"] for r in h_stripped))
        for rec in h_stripped:
            for ignore in (False, True):
                r = run_pure(rec, tmp, ignore)
                if r["exit"] != 0 or r["GITHUB_ENV"] or r["GITHUB_OUTPUT"] or r["stub_calls"]:
                    problems.append("validation step %r is not a no-op for %r: %s"
                                    % (rec["step"], args.deploy_type or "(default)", json.dumps(r)))
                    break
        if problems:
            failures += 1
            print("FAIL %s" % label)
            for p in problems:
                print("  " + p.replace("\n", "\n  "))
        else:
            extra = " (ignored validation step: %s)" % ", ".join(r["step"] for r in h_stripped) if h_stripped else ""
            print("ok   %s: %d effective steps match %s%s" % (label, len(b_steps), args.base_ref, extra))
    return 1 if failures else 0


DEPLOY_WORKFLOW_RE = re.compile(r"^pie/\.github/\.github/workflows/deploy\.ya?ml@")


def cmd_collect_callers(args):
    """Every job in a folder of workflow files that calls deploy.yaml, as a
    callers file for `compare`. For running locally against real callers'
    inputs; the output isn't committed (it holds client hosts)."""
    callers = []
    for fn in sorted(os.listdir(args.dir)):
        if not fn.endswith((".yml", ".yaml")):
            continue
        try:
            with open(os.path.join(args.dir, fn), encoding="utf-8") as fh:
                wf = yaml.safe_load(fh)
        except yaml.YAMLError:
            continue
        if not isinstance(wf, dict):
            continue
        for jid, job in (wf.get("jobs") or {}).items():
            if isinstance(job, dict) and DEPLOY_WORKFLOW_RE.match(str(job.get("uses", ""))):
                callers.append({"id": "%s:%s" % (fn, jid), "from": fn, "with": job.get("with") or {}})
    with open(args.out, "w", encoding="utf-8") as fh:
        yaml.safe_dump({"callers": callers}, fh, sort_keys=False)
    print("collected %d deploy.yaml caller jobs from %s" % (len(callers), args.dir))
    return 0


def cmd_extract(args):
    with open(args.callers) as fh:
        callers = {c["id"]: c for c in yaml.safe_load(fh)["callers"]}
    given = dict(callers[args.caller].get("with") or {})
    if args.deploy_type is not None:
        given["deploy-type"] = args.deploy_type
    src = Source(args.repo, None if args.ref in (None, "WORKTREE") else args.ref)
    steps, stripped = extract(src, args.workflow, given, allow_unknown=True)
    print(json.dumps({"steps": steps, "validation_steps": stripped}, indent=2, sort_keys=True))
    return 0


# --------------------------------------------------------------------------
# run-workflow / run-action
# --------------------------------------------------------------------------

def parse_env_file(path):
    out = {}
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line:
            continue
        m = re.match(r"^([^=<]+)<<(.+)$", line)
        if m:
            key, delim, buf = m.group(1), m.group(2), []
            while i < len(lines) and lines[i] != delim:
                buf.append(lines[i])
                i += 1
            i += 1
            out[key] = "\n".join(buf)
        elif "=" in line:
            key, val = line.split("=", 1)
            out[key] = val
    return out


class Runner:
    def __init__(self, repo, workspace, github, secrets, log_prefix="gha"):
        self.src = Source(repo, None)
        self.repo = repo
        self.workspace = workspace
        self.github = github
        self.secrets = secrets
        self.tmp = tempfile.mkdtemp(prefix="gha-run.", dir=os.environ.get("GHA_TMP"))
        self.log_prefix = log_prefix
        self.n = 0

    def say(self, msg):
        print("[%s] %s" % (self.log_prefix, msg), flush=True)

    def fresh_file(self, name):
        self.n += 1
        path = os.path.join(self.tmp, "%s.%d" % (name, self.n))
        open(path, "w").close()
        return path

    def base_env(self, job):
        env = dict(os.environ)
        env["PATH"] = os.pathsep.join(job["path_add"] + [STUB_DIR, os.environ.get("PATH", "")])
        env.update({
            "CI": "true", "GITHUB_ACTIONS": "true",
            "GITHUB_SHA": self.github.get("sha", ""),
            "GITHUB_RUN_ID": str(self.github.get("run_id", "")),
            "GITHUB_RUN_ATTEMPT": str(self.github.get("run_attempt", "1")),
            "GITHUB_REPOSITORY": self.github.get("repository", ""),
            "GITHUB_WORKSPACE": self.workspace,
            "GITHUB_ENV": job["env_file"], "GITHUB_PATH": job["path_file"],
            "RUNNER_TEMP": self.tmp, "RUNNER_OS": "Linux",
        })
        env.update(job["wf_env"])
        env.update(job["job_env"])
        env.update(job["env_vars"])
        return env

    def ctx(self, job, inputs, steps, extra_env, status, action_path=None):
        github = dict(self.github)
        github["workspace"] = self.workspace
        if action_path:
            github["action_path"] = action_path
        env = dict(job["wf_env"])
        env.update(job["job_env"])
        env.update(job["env_vars"])
        env.update(extra_env)
        return {"inputs": inputs, "secrets": self.secrets, "github": github, "env": env,
                "steps": steps, "needs": job["needs"], "matrix": {}, "strategy": {},
                "runner": {"os": "Linux", "temp": self.tmp}, "vars": {},
                "job": {"status": status}, "__status__": status}

    def run_steps(self, job, steps, inputs, action_path=None, depth=0):
        """Runs a list of steps. Returns (status, step results by id)."""
        status = "success"
        results = {}
        for step in steps or []:
            ctx = self.ctx(job, inputs, results, {}, status, action_path)
            name = step_display_name(step, ctx)
            if not eval_if(step.get("if"), ctx):
                self.say("%sskip  %s" % ("  " * depth, name))
                if "id" in step:
                    results[step["id"]] = {"outputs": {}, "outcome": "skipped", "conclusion": "skipped"}
                continue
            step_env = render(step.get("env") or {}, ctx)
            ctx = self.ctx(job, inputs, results, step_env, status, action_path)
            self.say("%sstep  %s" % ("  " * depth, name))
            outcome, outputs = self.run_step(job, step, ctx, step_env, action_path, depth)
            if outcome == "failure":
                self.say("%sFAIL  %s" % ("  " * depth, name))
            conclusion = outcome
            if outcome == "failure" and truthy(render(step.get("continue-on-error", False), ctx) == "true"):
                conclusion = "success"
            if "id" in step:
                results[step["id"]] = {"outputs": outputs, "outcome": outcome, "conclusion": conclusion}
            if conclusion == "failure":
                status = "failure"
        return status, results

    def run_step(self, job, step, ctx, step_env, action_path, depth):
        if "run" in step:
            script_text = render(step["run"], ctx)
            script = self.fresh_file("step.sh")
            with open(script, "w", encoding="utf-8") as fh:
                fh.write(script_text)
            out_file = self.fresh_file("GITHUB_OUTPUT")
            env = self.base_env(job)
            env.update({k: "" if v is None else v for k, v in step_env.items()})
            env["GITHUB_OUTPUT"] = out_file
            if action_path:
                env["GITHUB_ACTION_PATH"] = os.path.join(self.repo, action_path)
            cwd = self.workspace
            if "working-directory" in step:
                cwd = os.path.join(self.workspace, render(step["working-directory"], ctx))
            shell = render(step.get("shell", "bash"), ctx)
            if shell not in ("bash", None):
                raise ExprError("shell %r not supported by the test runner" % shell)
            sys.stdout.flush()
            res = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", script],
                                 cwd=cwd, env=env)
            job["env_vars"].update(parse_env_file(job["env_file"]))
            for line in open(job["path_file"]).read().splitlines():
                if line and line not in job["path_add"]:
                    job["path_add"].insert(0, line)
            return ("success" if res.returncode == 0 else "failure"), parse_env_file(out_file)
        uses = step.get("uses", "")
        m = PIE_ACTION_RE.match(uses)
        if not m:
            self.say("%s  (external action %s not run by the test runner)" % ("  " * depth, uses))
            return "success", {}
        name = m.group(1)
        if name in NOOP_ACTIONS:
            self.say("%s  (%s not run: it would write this machine's SSH config)" % ("  " * depth, name))
            return "success", {}
        action, path = self.src.action(name)
        given = render(step.get("with") or {}, ctx)
        ainputs = resolve_action_inputs(action, given)
        runs_block = action.get("runs") or {}
        if runs_block.get("using") != "composite":
            raise ExprError("action %s is not composite" % name)
        status, results = self.run_steps(job, runs_block.get("steps"), ainputs, path, depth + 1)
        outputs = {}
        actx = self.ctx(job, ainputs, results, {}, status, os.path.join(self.repo, path))
        for oname, spec in (action.get("outputs") or {}).items():
            outputs[oname] = render((spec or {}).get("value", ""), actx)
        return status, outputs

    def run_job(self, wf, job_id, job, inputs, needs):
        jobstate = {
            "env_file": self.fresh_file("GITHUB_ENV"), "path_file": self.fresh_file("GITHUB_PATH"),
            "env_vars": {}, "path_add": [], "needs": needs,
            "wf_env": render(wf.get("env") or {}, {"inputs": inputs, "github": self.github,
                                                    "secrets": self.secrets, "vars": {}}),
            "job_env": {},
        }
        jobstate["job_env"] = render(job.get("env") or {}, self.ctx(jobstate, inputs, {}, {}, "success"))
        status, results = self.run_steps(jobstate, job.get("steps"), inputs)
        outputs = {}
        octx = self.ctx(jobstate, inputs, results, {}, status)
        for oname, val in (job.get("outputs") or {}).items():
            outputs[oname] = render(val, octx)
        return status, outputs

    def run_workflow(self, wf, inputs):
        jobs = wf.get("jobs") or {}
        done, order = {}, []
        pending = list(jobs)
        while pending:
            progressed = False
            for jid in list(pending):
                needs = jobs[jid].get("needs") or []
                needs = [needs] if isinstance(needs, str) else needs
                if all(n in done for n in needs):
                    order.append(jid)
                    done[jid] = None
                    pending.remove(jid)
                    progressed = True
            if not progressed:
                raise ExprError("job needs cycle: %s" % pending)
        results = {}
        overall = 0
        for jid in order:
            job = jobs[jid]
            needs = job.get("needs") or []
            needs = [needs] if isinstance(needs, str) else needs
            needs_ctx = {n: results[n] for n in needs}
            upstream_ok = all(results[n]["result"] == "success" for n in needs)
            jctx = {"inputs": inputs, "github": self.github, "needs": needs_ctx, "vars": {},
                    "secrets": self.secrets, "__status__": "success" if upstream_ok else "failure"}
            if not eval_if(job.get("if"), jctx):
                self.say("job %s: skipped" % jid)
                results[jid] = {"result": "skipped", "outputs": {}}
                continue
            if "uses" in job:
                raise ExprError("job %s calls a reusable workflow; run it separately" % jid)
            self.say("job %s: start" % jid)
            status, outputs = self.run_job(wf, jid, job, inputs, needs_ctx)
            results[jid] = {"result": status, "outputs": outputs}
            self.say("job %s: %s" % (jid, status))
            if status != "success":
                overall = 1
        return overall, results


def load_json_arg(value):
    if not value:
        return {}
    if value.startswith("@"):
        with open(value[1:]) as fh:
            return json.load(fh)
    return json.loads(value)


def cmd_run_workflow(args):
    runner = Runner(args.repo, args.workspace, load_json_arg(args.github), load_json_arg(args.secrets))
    wf = runner.src.load_yaml(args.workflow)
    inputs = resolve_workflow_inputs(wf, load_json_arg(args.inputs), args.allow_unknown_inputs)
    runner.say("workflow %s" % args.workflow)
    code, _ = runner.run_workflow(wf, inputs)
    runner.say("workflow %s: %s" % (args.workflow, "success" if code == 0 else "failure"))
    return code


def cmd_run_action(args):
    runner = Runner(args.repo, args.workspace, load_json_arg(args.github), load_json_arg(args.secrets))
    wf = {"jobs": {"action": {"steps": [{
        "name": "Run %s" % args.action,
        "uses": "pie/.github/actions/%s@test" % args.action,
        "with": load_json_arg(args.inputs)}]}}}
    code, _ = runner.run_workflow(wf, {})
    runner.say("action %s: %s" % (args.action, "success" if code == 0 else "failure"))
    return code


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("compare", help="diff effective steps between two refs for each caller")
    c.add_argument("--repo", required=True)
    c.add_argument("--workflow", default=".github/workflows/deploy.yaml")
    c.add_argument("--callers", required=True)
    c.add_argument("--only", nargs="*")
    c.add_argument("--base-ref", required=True)
    c.add_argument("--head-ref", default=None, help="git ref, or omit for the working tree")
    c.add_argument("--deploy-type", default=None, help="value passed as deploy-type on the head side")
    c.add_argument("--effect-equal-run", action="store_true",
                   help="accept a differing run: text when running both versions has the same effect")
    c.add_argument("--expect-validation", action="store_true",
                   help="fail unless the head side runs a deploy-type validation step")
    c.set_defaults(fn=cmd_compare)

    k = sub.add_parser("collect-callers", help="caller input sets from a folder of real callers' workflows")
    k.add_argument("--dir", required=True)
    k.add_argument("--out", required=True)
    k.set_defaults(fn=cmd_collect_callers)

    e = sub.add_parser("extract", help="print one caller's effective steps")
    e.add_argument("--repo", required=True)
    e.add_argument("--workflow", default=".github/workflows/deploy.yaml")
    e.add_argument("--callers", required=True)
    e.add_argument("--caller", required=True)
    e.add_argument("--ref", default=None)
    e.add_argument("--deploy-type", default=None)
    e.set_defaults(fn=cmd_extract)

    for name, fn in (("run-workflow", cmd_run_workflow), ("run-action", cmd_run_action)):
        r = sub.add_parser(name)
        r.add_argument("--repo", required=True)
        if name == "run-workflow":
            r.add_argument("--workflow", required=True)
            r.add_argument("--allow-unknown-inputs", action="store_true")
        else:
            r.add_argument("--action", required=True)
        r.add_argument("--workspace", required=True)
        r.add_argument("--inputs", default="{}")
        r.add_argument("--secrets", default='{"SSH_PRIVATE_KEY": "test-key-not-real"}')
        r.add_argument("--github", default="{}")
        r.set_defaults(fn=fn)

    args = p.parse_args()
    try:
        sys.exit(args.fn(args))
    except (ExprError, Undecidable) as exc:
        print("gha.py: %s" % exc, file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
