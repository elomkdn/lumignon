#!/usr/bin/env python3
"""Lumignon's backend: talks to the Claude Code, Codex and OpenCode CLIs.

The QML side calls it through Plasma's executable data engine:
  usage                             print quotas and local token stats as JSON
  ask ID AGENT MODEL SESSION TEXT   start a detached worker; the answer goes to answer.json
  stop                              stop the running worker
  ping [--force]                    refresh Claude's quota with a minimal Haiku request
  terminal AGENT [SESSION]          open the agent in a terminal

Errors and activities are written as codes ({"code": ...}, {"kind": ...}) so that
the interface can translate them.
"""
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from datetime import date, datetime, timedelta
from pathlib import Path

HOME = Path.home()
CACHE = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "lumignon"
USAGE = CACHE / "usage.json"        # Claude quota
CODEX_STATE = CACHE / "codex.json"  # Codex limit and plan
ANSWER = CACHE / "answer.json"
TOKENS = CACHE / "tokens.json"
STDERR = CACHE / "agent-stderr.log"
CLAUDE_PROJECTS = Path(os.environ.get("CLAUDE_CONFIG_DIR", HOME / ".claude")) / "projects"
CODEX_SESSIONS = Path(os.environ.get("CODEX_HOME", HOME / ".codex")) / "sessions"
OPENCODE_DB = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local/share")) / "opencode" / "opencode.db"

AGENTS = ("claude", "codex", "opencode")
AUTO_PING_EVERY = 300  # seconds between two automatic Claude quota refreshes
FORCED_PING_EVERY = 15
CLAUDE_MODELS = {"", "haiku", "sonnet", "opus"}
SESSION_FORMATS = {
    "claude": re.compile(r"^[0-9a-fA-F-]{36}$"),
    "codex": re.compile(r"^[0-9a-fA-F-]{36}$"),
    "opencode": re.compile(r"^ses_[A-Za-z0-9]{8,64}$"),
}
CLAUDE_TOOLS = "Read,Glob,Grep,WebSearch"  # read-only: the widget cannot change anything
# OpenCode's own "plan" agent still runs shell commands and fetches pages: the widget
# defines its own agent, which can only read, list, search files and search the web.
OPENCODE_AGENT = {
    "mode": "primary",
    "description": "Read-only agent of the Lumignon widget",
    "permission": {
        "*": "deny",
        "read": {"*": "allow", "*.env": "deny", "*.env.*": "deny"},
        "glob": "allow", "grep": "allow", "list": "allow", "websearch": "allow",
    },
}
CLAUDE_PROMPT = (
    "You are answering inside a small desktop widget: be brief and direct, use simple "
    "Markdown without headings, and reply in the user's language. You can read files "
    "and search the web, but not change anything or run commands. If the request needs "
    "that, say so and suggest the widget's terminal button."
)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def write_json(path, data):
    CACHE.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=CACHE, prefix=path.name)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)


def claude_env():
    """Environment in which Claude Code can only use the claude.ai subscription."""
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("CLAUDE_CODE_") or key in (
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
            "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT",
        ):
            del env[key]
    return env


def agent_bin(agent):
    return shutil.which(agent) or str(HOME / ".local/bin" / agent)


def spawn_self(*args, stdin=None):
    return subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), *args],
        stdin=stdin, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def local_day(stamp):
    if isinstance(stamp, (int, float)):
        return datetime.fromtimestamp(stamp).date().isoformat()
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone().date().isoformat()


def last_7_days(per_day):
    today = date.today()
    return [per_day.get((today - timedelta(days=i)).isoformat(), 0) for i in range(6, -1, -1)]


def scan_appended(path, entry, on_line):
    """Feed on_line with what was appended to a JSON-lines file since the last scan."""
    size = path.stat().st_size
    if size < entry.get("offset", 0):
        entry.clear()
    with open(path, "rb") as f:
        f.seek(entry.get("offset", 0))
        offset = f.tell()
        for raw in f:
            if not raw.endswith(b"\n"):
                break  # line still being written: read it next time
            offset += len(raw)
            on_line(raw, entry)
    entry["offset"] = offset


def scan_tree(root, cache, on_line):
    """Incrementally scan every recent .jsonl under root. Returns the last activity time."""
    limit = time.time() - 8 * 86400
    last_activity = 0
    seen = {}
    if root.is_dir():
        for path in root.rglob("*.jsonl"):
            try:
                stat = path.stat()
            except OSError:
                continue
            last_activity = max(last_activity, stat.st_mtime)
            if stat.st_mtime < limit:
                continue
            key = str(path)
            entry = cache.get(key, {})
            if entry.get("mtime") != stat.st_mtime or entry.get("size") != stat.st_size:
                try:
                    scan_appended(path, entry, on_line)
                except OSError:
                    continue
                entry.update(mtime=stat.st_mtime, size=stat.st_size)
            seen[key] = entry
    cache.clear()
    cache.update(seen)
    return last_activity


# ---- Claude ---------------------------------------------------------------------

def record_rate_limit(info):
    windows = info.get("unifiedWindows") or {}
    if not windows:
        return
    usage = read_json(USAGE, {})
    for name in ("five_hour", "seven_day"):
        if name in windows:
            usage[name] = windows[name]
    usage["updatedAt"] = time.time()
    write_json(USAGE, usage)


def touch_usage():
    usage = read_json(USAGE, {})
    if usage:
        usage["updatedAt"] = time.time()
        write_json(USAGE, usage)


def cmd_ping(force):
    usage = read_json(USAGE, {})
    wait = FORCED_PING_EVERY if force else AUTO_PING_EVERY
    if time.time() - usage.get("lastPing", 0) < wait:
        return
    usage["lastPing"] = time.time()
    write_json(USAGE, usage)
    cmd = [
        agent_bin("claude"), "-p", "--model", "haiku", "--no-session-persistence",
        "--output-format", "stream-json", "--verbose", "--tools", "",
        "--system-prompt", "Reply: ok", "--setting-sources", "",
        "--strict-mcp-config", "--disable-slash-commands",
    ]
    try:
        out = subprocess.run(
            cmd, input="ok", capture_output=True, text=True, timeout=60,
            env=claude_env(), cwd=CACHE,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return
    for line in out.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") == "system" and event.get("apiKeySource", "none") != "none":
            return
        if event.get("type") == "rate_limit_event":
            record_rate_limit(event.get("rate_limit_info") or {})


def claude_plan(usage):
    """Subscription name, refreshed once a day."""
    if usage.get("plan") and time.time() - usage.get("planAt", 0) < 86400:
        return usage["plan"]
    try:
        out = subprocess.run(
            [agent_bin("claude"), "auth", "status", "--json"], capture_output=True,
            text=True, timeout=15, env=claude_env(), cwd=CACHE,
        ).stdout
        plan = json.loads(out).get("subscriptionType") or ""
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return usage.get("plan", "")
    fresh = read_json(USAGE, {})
    fresh.update(plan=plan, planAt=time.time())
    write_json(USAGE, fresh)
    return plan


def claude_line(raw, entry):
    if b'"usage"' not in raw or b'"assistant"' not in raw:
        return
    try:
        record = json.loads(raw)
    except ValueError:
        return
    if record.get("type") != "assistant":
        return
    message = record.get("message") or {}
    usage = message.get("usage")
    if not usage or not record.get("timestamp") or not message.get("id"):
        return
    entry.setdefault("messages", {})[message["id"]] = [
        local_day(record["timestamp"]),
        (usage.get("input_tokens") or 0)
        + (usage.get("cache_creation_input_tokens") or 0)
        + (usage.get("output_tokens") or 0),
    ]


def claude_usage(cache, running):
    files = cache.setdefault("claude", {})
    last_activity = scan_tree(CLAUDE_PROJECTS, files, claude_line)
    # A resumed or forked session repeats messages: count each id once.
    messages = {}
    for entry in files.values():
        messages.update(entry.get("messages", {}))
    per_day = {}
    for day, count in messages.values():
        per_day[day] = per_day.get(day, 0) + count

    usage = read_json(USAGE, {})
    # Only refresh after real activity: a request could otherwise open a new
    # 5-hour window while Claude is not being used at all.
    if (
        not running
        and last_activity > usage.get("updatedAt", 0) + 20
        and time.time() - usage.get("lastPing", 0) >= AUTO_PING_EVERY
    ):
        spawn_self("ping")

    windows = []
    for name, minutes in (("five_hour", 300), ("seven_day", 10080)):
        w = usage.get(name)
        if w:
            windows.append({"minutes": minutes, "length": minutes * 60,
                            "utilization": w.get("utilization", 0),
                            "resetsAt": w.get("resetsAt", 0), "status": w.get("status", "")})
    return {
        "plan": claude_plan(usage), "windows": windows, "days": last_7_days(per_day),
        "lastActivity": last_activity, "updatedAt": usage.get("updatedAt", 0),
    }


# ---- Codex ----------------------------------------------------------------------

def codex_line(raw, entry):
    if b'"token_count"' not in raw:
        return
    try:
        record = json.loads(raw)
    except ValueError:
        return
    payload = record.get("payload") or {}
    stamp = record.get("timestamp")
    if payload.get("type") != "token_count" or not stamp:
        return
    last = (payload.get("info") or {}).get("last_token_usage") or {}
    if last:
        day = local_day(stamp)
        days = entry.setdefault("days", {})
        days[day] = days.get(day, 0) + max(0, (last.get("input_tokens") or 0)
                                           - (last.get("cached_input_tokens") or 0)) \
            + (last.get("output_tokens") or 0)
    limits = payload.get("rate_limits") or {}
    if limits.get("primary") or limits.get("secondary"):
        entry["limits"] = {"at": stamp, "primary": limits.get("primary"),
                           "secondary": limits.get("secondary")}


def codex_window(w, stamp):
    at = datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    reset = w.get("resets_at")
    if isinstance(reset, str):
        try:
            reset = datetime.fromisoformat(reset.replace("Z", "+00:00")).timestamp()
        except ValueError:
            reset = 0
    if not reset and w.get("resets_in_seconds") is not None:
        reset = at + w["resets_in_seconds"]
    used = (w.get("used_percent") or 0) / 100
    minutes = w.get("window_minutes") or 0
    return {"minutes": minutes, "length": minutes * 60, "utilization": used,
            "resetsAt": reset or 0, "status": "rejected" if used >= 1 else "allowed"}


def parse_codex_limit(message):
    """'… try again at Nov 23rd, 2026 6:38 AM.' -> timestamp, or None."""
    found = re.search(r"try again at (.+?)\.?\s*$", message or "")
    if not found:
        return None
    text = re.sub(r"(\d+)(st|nd|rd|th)", r"\1", found.group(1).strip())
    for pattern in ("%b %d, %Y %I:%M %p", "%B %d, %Y %I:%M %p"):
        try:
            return datetime.strptime(text, pattern).timestamp()
        except ValueError:
            continue
    return None


def codex_login():
    try:
        out = subprocess.run([agent_bin("codex"), "login", "status"], capture_output=True,
                             text=True, timeout=15, cwd=CACHE)
        return out.stdout + out.stderr
    except (OSError, subprocess.TimeoutExpired):
        return ""


def codex_plan(state):
    if state.get("plan") is not None and time.time() - state.get("planAt", 0) < 86400:
        return state["plan"]
    text = codex_login()
    if not text:
        return state.get("plan", "")  # Codex did not answer: try again next time
    plan = "ChatGPT" if "ChatGPT" in text else ""
    fresh = read_json(CODEX_STATE, {})
    fresh.update(plan=plan, planAt=time.time())
    write_json(CODEX_STATE, fresh)
    return plan


def codex_usage(cache):
    files = cache.setdefault("codex", {})
    last_activity = scan_tree(CODEX_SESSIONS, files, codex_line)
    per_day = {}
    newest = None
    for entry in files.values():
        for day, count in entry.get("days", {}).items():
            per_day[day] = per_day.get(day, 0) + count
        limits = entry.get("limits")
        if limits and (newest is None or limits["at"] > newest["at"]):
            newest = limits
    windows = []
    if newest:
        for key in ("primary", "secondary"):
            if newest.get(key):
                windows.append(codex_window(newest[key], newest["at"]))
    state = read_json(CODEX_STATE, {})
    until = state.get("limitedUntil") or 0
    if until > time.time() and not any(w["status"] == "rejected" for w in windows):
        windows.insert(0, {"limit": True, "minutes": 0, "length": 0, "utilization": 1,
                           "resetsAt": until, "status": "rejected"})
    return {"plan": codex_plan(state), "windows": windows, "days": last_7_days(per_day),
            "lastActivity": last_activity}


# ---- OpenCode -------------------------------------------------------------------

def opencode_usage():
    per_day, cost_today, last_activity = {}, 0.0, 0
    try:
        db = sqlite3.connect(f"file:{OPENCODE_DB}?mode=ro", uri=True, timeout=2)
        try:
            since = (time.time() - 8 * 86400) * 1000
            last = db.execute("select max(time_created) from session_message").fetchone()[0]
            last_activity = (last or 0) / 1000
            today = date.today().isoformat()
            rows = db.execute(
                "select time_created, data from session_message where type = 'assistant' and time_created >= ?",
                (since,))
            for created, data in rows:
                try:
                    message = json.loads(data)
                except ValueError:
                    continue
                tokens = message.get("tokens") or {}
                count = (tokens.get("input") or 0) + (tokens.get("output") or 0) \
                    + (tokens.get("reasoning") or 0) + ((tokens.get("cache") or {}).get("write") or 0)
                day = local_day(created / 1000)
                per_day[day] = per_day.get(day, 0) + count
                if day == today:
                    cost_today += message.get("cost") or 0
        finally:
            db.close()
    except sqlite3.Error:
        pass
    return {"plan": "", "windows": [], "days": last_7_days(per_day),
            "lastActivity": last_activity, "costToday": round(cost_today, 4)}


# ---- Usage command ----------------------------------------------------------------

def worker_alive(pid):
    try:
        cmdline = Path(f"/proc/{int(pid)}/cmdline").read_bytes()
    except (OSError, TypeError, ValueError):
        return False
    return b"lumignon_backend.py" in cmdline and b"worker" in cmdline


def cmd_usage():
    answer = read_json(ANSWER, {})
    running = answer.get("status") == "running"
    if running and not worker_alive(answer.get("pid")):
        answer.update(status="error", error={"code": "worker_died"})
        write_json(ANSWER, answer)
        running = False

    cache = read_json(TOKENS, {})
    agents = {}
    for agent in AGENTS:
        installed = bool(shutil.which(agent))
        data = {"installed": installed}
        if installed:
            try:
                if agent == "claude":
                    data.update(claude_usage(cache, running))
                elif agent == "codex":
                    data.update(codex_usage(cache))
                else:
                    data.update(opencode_usage())
            except Exception as err:  # one broken agent must not hide the others
                data.update(windows=[], days=[0] * 7, lastActivity=0, error=str(err))
        agents[agent] = data
    write_json(TOKENS, cache)
    print(json.dumps({"agents": agents, "now": time.time()}))


# ---- Asking an agent --------------------------------------------------------------

def cmd_ask(request_id, agent, model, session, question):
    if (
        agent not in AGENTS
        or (model and (agent != "claude" or model not in CLAUDE_MODELS))
        or (session and not SESSION_FORMATS[agent].match(session))
    ):
        sys.exit("invalid arguments")
    answer = read_json(ANSWER, {})
    if answer.get("status") == "running" and worker_alive(answer.get("pid")):
        sys.exit("already running")
    # The worker waits for its stdin: this state is on disk before it starts writing.
    worker = spawn_self("worker", request_id, agent, model, session, stdin=subprocess.PIPE)
    write_json(ANSWER, {"id": request_id, "agent": agent, "status": "running", "text": "",
                        "activity": None, "session": session, "pid": worker.pid})
    worker.stdin.write(question.encode("utf-8"))
    worker.stdin.close()


CURRENT = {"proc": None, "stopped": False}


def on_term(*_):
    CURRENT["stopped"] = True
    if CURRENT["proc"]:
        CURRENT["proc"].terminate()


def run_stream(cmd, state, on_event, stdin_text=None, env=None):
    """Run a CLI printing JSON lines, feeding each event to on_event.

    on_event returns an error to cancel the run. Returns (exit code, stderr, cancel error)."""
    CACHE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(STDERR, "w+", encoding="utf-8") as errors:
        proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=errors, text=True, encoding="utf-8",
            env=env or os.environ.copy(), cwd=HOME,
        )
        CURRENT["proc"] = proc
        if stdin_text is not None:
            proc.stdin.write(stdin_text)
            proc.stdin.close()
        cancel = None
        last_write = 0.0
        for line in proc.stdout:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            cancel = on_event(event)
            if cancel:
                proc.terminate()
                break
            now = time.monotonic()
            if now - last_write > 0.1:
                write_json(ANSWER, state)
                last_write = now
        proc.wait()
        errors.seek(0)
        return proc.returncode, errors.read(), cancel


def run_claude(state, question, model, session):
    cmd = [
        agent_bin("claude"), "-p", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--permission-mode", "default",
        "--tools", CLAUDE_TOOLS, "--allowed-tools", CLAUDE_TOOLS, "--strict-mcp-config",
        "--append-system-prompt", CLAUDE_PROMPT,
    ]
    if model:
        cmd += ["--model", model]
    if session:
        cmd += ["--resume", session]
    result = {}

    def on_event(event):
        kind = event.get("type")
        if kind == "system" and event.get("subtype") == "init":
            state["session"] = event.get("session_id") or session
            source = event.get("apiKeySource", "none")
            if source != "none":
                return {"code": "api_key", "detail": source}
        elif kind == "rate_limit_event":
            record_rate_limit(event.get("rate_limit_info") or {})
        elif kind == "stream_event" and not event.get("parent_tool_use_id"):
            inner = event.get("event") or {}
            if inner.get("type") == "content_block_start":
                if inner.get("content_block", {}).get("type") == "text" and state["text"]:
                    state["text"] += "\n\n"
            elif inner.get("type") == "content_block_delta":
                delta = inner.get("delta") or {}
                if delta.get("type") == "text_delta":
                    state["text"] += delta.get("text", "")
                    state["activity"] = None
        elif kind == "assistant" and not event.get("parent_tool_use_id"):
            for block in event.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    state["activity"] = tool_activity(block.get("name"), block.get("input") or {})
        elif kind == "result":
            result.update(event)
        return None

    code, errors, cancel = run_stream(cmd, state, on_event, stdin_text=question, env=claude_env())
    touch_usage()
    if cancel:
        return cancel
    if result and not result.get("is_error"):
        state["text"] = state["text"] or result.get("result") or ""
        state["session"] = result.get("session_id") or state["session"]
        return None
    return error_from_text(str(result.get("result") or errors))


def run_codex(state, question, model, session):
    login = codex_login()
    if "ChatGPT" not in login:
        return {"code": "api_key"} if "API key" in login else {"code": "logged_out"}

    # Read-only sandbox, without network, and never ask for more
    cmd = [agent_bin("codex"), "exec", "--json", "-s", "read-only", "-c", 'approval_policy="never"',
           "--skip-git-repo-check"]
    cmd += ["resume", session, "-"] if session else ["-"]
    messages = {}
    failure = {}

    def on_event(event):
        kind = event.get("type")
        if kind == "thread.started":
            state["session"] = event.get("thread_id") or session
        elif kind in ("item.started", "item.updated", "item.completed"):
            item = event.get("item") or {}
            item_type = item.get("type") or item.get("item_type")
            if item_type in ("agent_message", "assistant_message"):
                messages[item.get("id")] = item.get("text") or ""
                state["text"] = "\n\n".join(t for t in messages.values() if t)
                state["activity"] = None
            elif item_type == "reasoning":
                state["activity"] = {"kind": "thinking"}
            elif item_type == "command_execution":
                state["activity"] = {"kind": "command", "detail": str(item.get("command", ""))[:40]}
            elif item_type == "web_search":
                state["activity"] = {"kind": "search", "detail": str(item.get("query", ""))[:50]}
        elif kind == "turn.failed":
            failure["message"] = (event.get("error") or {}).get("message", "")
        elif kind == "error":
            failure.setdefault("message", event.get("message", ""))
        return None

    code, errors, _ = run_stream(cmd, state, on_event, stdin_text=question)
    message = failure.get("message")
    if message or code != 0:
        message = message or errors
        until = parse_codex_limit(message)
        if until or "usage limit" in message.lower():
            codex_state = read_json(CODEX_STATE, {})
            codex_state.update(limitedUntil=until or 0)
            write_json(CODEX_STATE, codex_state)
            return {"code": "limit", "until": until or 0}
        return error_from_text(message)
    return None


def run_opencode(state, question, model, session):
    # A private server, so that the widget's agent definition applies
    cmd = [agent_bin("opencode"), "run", "--standalone", "--format", "json", "--agent", "lumignon"]
    if session:
        cmd += ["--session", session]
    env = os.environ.copy()
    try:
        config = json.loads(env.get("OPENCODE_CONFIG_CONTENT") or "{}")
    except ValueError:
        config = {}
    config.setdefault("agent", {})["lumignon"] = OPENCODE_AGENT
    env["OPENCODE_CONFIG_CONTENT"] = json.dumps(config)
    parts = {}
    failure = {}

    def on_event(event):
        kind = event.get("type")
        state["session"] = event.get("sessionID") or state["session"]
        part = event.get("part") or {}
        if kind == "text":
            parts[part.get("id")] = part.get("text") or ""
            state["text"] = "\n\n".join(t for t in parts.values() if t)
            state["activity"] = None
        elif kind == "tool_use":
            state["activity"] = tool_activity(part.get("tool"), (part.get("state") or {}).get("input") or {})
        elif kind == "reasoning":
            state["activity"] = {"kind": "thinking"}
        elif kind == "error":
            error = event.get("error") or {}
            failure["message"] = (error.get("data") or {}).get("message") or error.get("name") or ""
        return None

    code, errors, _ = run_stream(cmd, state, on_event, stdin_text=question, env=env)
    if failure or (code != 0 and not state["text"]):
        return error_from_text(failure.get("message") or errors)
    return None


def tool_activity(tool, data):
    tool = str(tool or "")
    low = tool.lower()
    if low == "read":
        path = data.get("file_path") or data.get("filePath") or ""
        return {"kind": "read", "detail": os.path.basename(str(path))}
    if low == "websearch":
        return {"kind": "search", "detail": str(data.get("query", ""))[:50]}
    if low == "webfetch":
        return {"kind": "fetch"}
    if low in ("glob", "grep", "list"):
        return {"kind": "files"}
    if low == "bash":
        return {"kind": "command"}
    return {"kind": "tool", "detail": tool}


def error_from_text(text):
    low = text.lower()
    if "not logged in" in low or "/login" in low or "authentication" in low:
        return {"code": "logged_out"}
    if "limit" in low and ("reach" in low or "hit" in low):
        return {"code": "limit", "until": 0}
    text = text.strip()
    return {"code": "raw", "detail": text[-400:]} if text else {"code": "empty"}


def cmd_worker(request_id, agent, model, session):
    question = sys.stdin.read()
    state = {"id": request_id, "agent": agent, "status": "running", "text": "", "activity": None,
             "session": session, "pid": os.getpid()}
    write_json(ANSWER, state)
    signal.signal(signal.SIGTERM, on_term)
    runner = {"claude": run_claude, "codex": run_codex, "opencode": run_opencode}[agent]
    try:
        error = runner(state, question, model, session)
    except OSError as err:
        error = {"code": "launch", "detail": str(err)}
    if CURRENT["stopped"]:
        state["status"] = "stopped"
    elif error:
        state.update(status="error", error=error)
    else:
        state["status"] = "done"
    state["activity"] = None
    write_json(ANSWER, state)


def cmd_stop():
    answer = read_json(ANSWER, {})
    if answer.get("status") == "running" and worker_alive(answer.get("pid")):
        os.kill(int(answer["pid"]), signal.SIGTERM)


def cmd_terminal(agent, session):
    if agent not in AGENTS:
        sys.exit("invalid agent")
    command = [agent_bin(agent)]
    if session and SESSION_FORMATS[agent].match(session):
        command += {"claude": ["--resume", session], "codex": ["resume", session],
                    "opencode": ["--session", session]}[agent]
    try:
        term = subprocess.run(
            ["kreadconfig6", "--group", "General", "--key", "TerminalApplication"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        term = ""
    term = term.split()[0] if term else "konsole"
    if not shutil.which(term):
        term = "konsole"
    subprocess.Popen(
        [term, "-e", *command], cwd=HOME,
        env=claude_env() if agent == "claude" else os.environ.copy(),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )


def main():
    CACHE.mkdir(mode=0o700, parents=True, exist_ok=True)  # also the agents' working directory
    CACHE.chmod(0o700)  # it holds the conversation
    args = sys.argv[1:]
    command = args[0] if args else ""
    if command == "usage":
        cmd_usage()
    elif command == "ask" and len(args) == 6:
        cmd_ask(*args[1:])
    elif command == "worker" and len(args) == 5:
        cmd_worker(*args[1:])
    elif command == "stop":
        cmd_stop()
    elif command == "ping":
        cmd_ping("--force" in args)
    elif command == "terminal" and len(args) >= 2:
        cmd_terminal(args[1], args[2] if len(args) > 2 else "")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
