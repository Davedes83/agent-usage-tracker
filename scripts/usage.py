#!/usr/bin/env python3
"""Agent Usage Tracker collector.

Reads local OpenCode usage (cost + tokens per reply, attributed to the model
and provider that actually served it) and the OpenRouter account/key usage, and
emits one JSON document on stdout for the Omarchy bar widget. Read-only: never
writes to the OpenCode database.

Windows: "today" is local calendar midnight-to-now; "week" and "month" are
rolling 7- and 30-day windows ending now; "all" is the full history.

Output shape (as consumed by Model.js / Panel.qml):
{
  "generated_at": <int ms>,
  "windows": {
    "today": {cost, input, output, reasoning, cache_read, cache_write, sessions},
    "week":  {...}, "month": {...}, "all": {...}
  },
  "providers": [{id, name, cost, input, output, sessions}],   # all time (compat)
  "providers_today": [{id, name, cost, input, output, sessions}],
  "providers_by_window": {
    "today": [...], "week": [...], "month": [...], "all": [...]
  },
  "models": {"today": [...], "week": [...], "month": [...], "all": [...]},
  "recent": [{id, title, model, provider, cost, input, output, updated}],
  "openrouter": {ok, usage, daily, weekly, monthly, credits_total,
                 credits_used, free_used, free_limit, budget, error}
}
"""

import datetime
import json
import os
import sqlite3
import sys
import time
import urllib.request
import urllib.error

HOME = os.path.expanduser("~")
OC_DB = os.path.join(HOME, ".local/share/opencode/opencode.db")
ENV_CONF = os.path.join(HOME, ".config/environment.d/openrouter.conf")

CACHE_BASE = os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache")
OR_CACHE = os.path.join(CACHE_BASE, "omarchy", "davedes.agent-usage-tracker-openrouter.json")
OR_TTL = 90  # seconds

PROVIDER_NAMES = {
    "opencode": "OpenCode",
    "openrouter": "OpenRouter",
    "google": "Google",
    "groq": "Groq",
    "ollama": "Ollama",
    "github-copilot": "Copilot",
    "openai": "OpenAI",
    "anthropic": "Anthropic",
    "deepseek": "DeepSeek",
}


def provider_name(pid):
    if not pid:
        return "Unknown"
    return PROVIDER_NAMES.get(pid, pid.replace("-", " ").title())


def read_env_conf(path, name):
    """Parse NAME=value from environment.d files (which may not be in our env)."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("export "):
                    line = line[7:].strip()
                if line.startswith(name + "="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return None


def get_key():
    return os.environ.get("OPENROUTER_API_KEY") or read_env_conf(ENV_CONF, "OPENROUTER_API_KEY")


def empty_window():
    return {
        "cost": 0.0,
        "input": 0,
        "output": 0,
        "reasoning": 0,
        "cache_read": 0,
        "cache_write": 0,
        "sessions": 0,
    }


def add_to_window(win, row):
    """Add one reply's tokens and cost to a window total.

    The session count is filled in by aggregate(): a reply belongs to a
    session, and one session can have many replies in a window.
    """
    win["cost"] += row["cost"]
    win["input"] += row["input"]
    win["output"] += row["output"]
    win["reasoning"] += row["reasoning"]
    win["cache_read"] += row["cache_read"]
    win["cache_write"] += row["cache_write"]


def load_sessions():
    """Read every session row once. Returns [] if the DB is unavailable."""
    if not os.path.exists(OC_DB):
        return []

    uri = "file:%s?mode=ro" % OC_DB
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=1.5)
    except sqlite3.Error:
        try:
            conn = sqlite3.connect(OC_DB, timeout=1.5)
        except sqlite3.Error:
            return []

    rows = []
    try:
        # Read-only, and wait out a concurrent writer instead of bailing with
        # SQLITE_BUSY the moment OpenCode saves a message.
        conn.execute("PRAGMA query_only = ON")
        conn.execute("PRAGMA busy_timeout = 3000")
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            """
            SELECT id, title, model, cost, parent_id,
                   tokens_input, tokens_output, tokens_reasoning,
                   tokens_cache_read, tokens_cache_write,
                   time_created, time_updated
            FROM session_v2
            """
        )
        for r in cur:
            model_raw = r["model"] or ""
            model_id = ""
            provider_id = ""
            try:
                meta = json.loads(model_raw) if model_raw else {}
                model_id = str(meta.get("id") or "")
                provider_id = str(meta.get("providerID") or "")
            except (ValueError, TypeError):
                model_id = model_raw
            rows.append(
                {
                    "id": r["id"],
                    "parent_id": r["parent_id"],
                    "title": (r["title"] or "").strip(),
                    "model": model_id,
                    "provider": provider_id,
                    "cost": float(r["cost"] or 0.0),
                    "input": int(r["tokens_input"] or 0),
                    "output": int(r["tokens_output"] or 0),
                    "reasoning": int(r["tokens_reasoning"] or 0),
                    "cache_read": int(r["tokens_cache_read"] or 0),
                    "cache_write": int(r["tokens_cache_write"] or 0),
                    "created": int(r["time_created"] or 0),
                    "updated": int(r["time_updated"] or 0),
                }
            )
    except sqlite3.Error:
        return []
    finally:
        conn.close()
    return rows


def load_messages(sessions):
    """Every assistant reply, per model, from both opencode message stores.

    V2's session_message is read first, then the original message store,
    deduplicated by message id, so a migrated reply is counted once. A fork's
    copies of its source session's replies are skipped: they were spent in the
    source, not in the copy. Each store is read independently and whatever
    could be read is merged, so a failure in one store (a missing table, a
    corrupt page) degrades to the other's rows instead of dropping per-model
    attribution entirely. Returns [] only when neither store yields a row.
    """
    if not os.path.exists(OC_DB):
        return []

    try:
        conn = sqlite3.connect("file:%s?mode=ro" % OC_DB, uri=True, timeout=1.5)
    except sqlite3.Error:
        return []

    # The session row's model is one value for a whole session, so it is only a
    # fallback for replies that name no model of their own.
    fallback = {s["id"]: (s["provider"], s["model"]) for s in sessions}

    rows = []
    seen = set()

    def take(r, before):
        key = str(r["id"])
        if key in seen:
            return
        cost = float(r["cost"] or 0.0)
        inp = int(r["input"] or 0)
        out = int(r["output"] or 0)
        reason = int(r["reasoning"] or 0)
        cache_read = int(r["cache_read"] or 0)
        cache_write = int(r["cache_write"] or 0)
        # A failed or empty reply spent nothing: it must not count as a session.
        if cost <= 0.0 and not (inp or out or reason or cache_read or cache_write):
            return
        ts = int(r["msg_time"] or r["time_created"] or 0)
        if before and ts and ts < before:
            return
        session_provider, session_model = fallback.get(r["session_id"], ("", ""))
        seen.add(key)
        rows.append(
            {
                "session": r["session_id"],
                "provider": r["provider"] or session_provider or "unknown",
                "model": r["model"] or session_model or "",
                "cost": cost,
                "input": inp,
                "output": out,
                "reasoning": reason,
                "cache_read": cache_read,
                "cache_write": cache_write,
                "ts": ts,
            }
        )

    fields = """
        json_extract(data, '$.time.created') AS msg_time,
        json_extract(data, '$.cost') AS cost,
        json_extract(data, '$.tokens.input') AS input,
        json_extract(data, '$.tokens.output') AS output,
        json_extract(data, '$.tokens.reasoning') AS reasoning,
        json_extract(data, '$.tokens.cache.read') AS cache_read,
        json_extract(data, '$.tokens.cache.write') AS cache_write,
    """

    try:
        # Read-only, and wait out a concurrent writer instead of bailing with
        # SQLITE_BUSY the moment OpenCode saves a message.
        conn.execute("PRAGMA query_only = ON")
        conn.execute("PRAGMA busy_timeout = 3000")
        conn.row_factory = sqlite3.Row

        # A fork copies its source's messages under new ids, each keeping its
        # original time; only the rows at or after the fork are its own.
        # Applying that to every session would drop old replies whose session
        # row was created later than the messages it holds, so it is keyed on
        # forks alone. Read in the same pass as the v2 rows below.
        forked_at = {}
        try:
            for r in conn.execute(
                "SELECT id, time_created, fork_session_id FROM session_v2"
            ):
                if r["fork_session_id"]:
                    forked_at[r["id"]] = int(r["time_created"] or 0)
        except sqlite3.Error:
            pass

        try:
            for r in conn.execute(
                """
                SELECT id, session_id, time_created,
                       """ + fields + """
                       json_extract(data, '$.model.providerID') AS provider,
                       json_extract(data, '$.model.id') AS model
                FROM session_message
                WHERE type IN ('assistant', 'compaction') AND json_valid(data)
                """
            ):
                before = forked_at.get(r["session_id"], 0)
                if before and int(r["time_created"] or 0) < before:
                    continue
                take(r, 0)
        except sqlite3.Error:
            pass

        try:
            for r in conn.execute(
                """
                SELECT id, session_id, time_created,
                       """ + fields + """
                       json_extract(data, '$.providerID') AS provider,
                       json_extract(data, '$.modelID') AS model
                FROM message
                WHERE json_valid(data) AND json_extract(data, '$.role') = 'assistant'
                """
            ):
                take(r, forked_at.get(r["session_id"], 0))
        except sqlite3.Error:
            pass
    finally:
        conn.close()

    return rows


def messages_from_sessions(sessions):
    """Session rows as pseudo-replies, for a DB without readable message stores."""
    rows = []
    for s in sessions:
        if s["cost"] <= 0.0 and not (
            s["input"] or s["output"] or s["reasoning"]
            or s["cache_read"] or s["cache_write"]
        ):
            continue
        rows.append(
            {
                "session": s["id"],
                "provider": s["provider"] or "unknown",
                "model": s["model"],
                "cost": s["cost"],
                "input": s["input"],
                "output": s["output"],
                "reasoning": s["reasoning"],
                "cache_read": s["cache_read"],
                "cache_write": s["cache_write"],
                "ts": s["updated"] or s["created"],
            }
        )
    return rows


def aggregate(sessions, messages):
    now = time.time() * 1000.0
    midnight = (
        datetime.datetime.now()
        .replace(hour=0, minute=0, second=0, microsecond=0)
        .timestamp()
        * 1000.0
    )

    windows = {
        "today": (midnight, empty_window()),
        "week": (now - 7 * 86400 * 1000.0, empty_window()),
        "month": (now - 30 * 86400 * 1000.0, empty_window()),
        "all": (0.0, empty_window()),
    }

    # A subagent's session is billed like any other, but it is not a
    # conversation the user started: it stays out of the session count and out
    # of the recent list.
    child_sessions = {s["id"] for s in sessions if s["parent_id"]}

    providers_per_window = {key: {} for key in windows}
    models_per_window = {key: {} for key in windows}
    provider_sessions = {key: {} for key in windows}
    model_sessions = {key: {} for key in windows}
    sessions_per_window = {key: set() for key in windows}

    for m in messages:
        stamp = m["ts"]
        pid = m["provider"] or "unknown"

        for key, (start, win) in windows.items():
            if stamp < start:
                continue
            add_to_window(win, m)
            if m["session"] not in child_sessions:
                sessions_per_window[key].add(m["session"])

            prow = providers_per_window[key].setdefault(
                pid, {"id": pid, "name": provider_name(pid), "cost": 0.0,
                      "input": 0, "output": 0, "sessions": 0}
            )
            prow["cost"] += m["cost"]
            prow["input"] += m["input"]
            prow["output"] += m["output"]
            if m["session"] not in child_sessions:
                provider_sessions[key].setdefault(pid, set()).add(m["session"])

            if m["model"]:
                mrow = models_per_window[key].setdefault(
                    (pid, m["model"]),
                    {"id": m["model"], "provider": provider_name(pid), "cost": 0.0,
                     "input": 0, "output": 0, "sessions": 0},
                )
                mrow["cost"] += m["cost"]
                mrow["input"] += m["input"]
                mrow["output"] += m["output"]
                if m["session"] not in child_sessions:
                    model_sessions[key].setdefault((pid, m["model"]), set()).add(
                        m["session"]
                    )

    def sort_rows(d):
        return sorted(d.values(), key=lambda r: (r["cost"], r["input"]), reverse=True)

    out_windows = {}
    for key, (_start, win) in windows.items():
        win["sessions"] = len(sessions_per_window[key])
        win["cost"] = round(win["cost"], 6)
        out_windows[key] = win

    providers_by_window = {}
    for key, pwin in providers_per_window.items():
        for pid, row in pwin.items():
            row["sessions"] = len(provider_sessions[key].get(pid, ()))
        rows = sort_rows(pwin)
        for row in rows:
            row["cost"] = round(row["cost"], 6)
        providers_by_window[key] = rows

    # Kept for compatibility with the documented shape: the panel reads
    # providers_by_window, older builds of the panel read these two.
    providers = providers_by_window["all"]
    providers_today_rows = providers_by_window["today"]

    models_per_window_out = {}
    for key, mwin in models_per_window.items():
        for mk, row in mwin.items():
            row["sessions"] = len(model_sessions[key].get(mk, ()))
        rows = sort_rows(mwin)[:6]
        for row in rows:
            row["cost"] = round(row["cost"], 6)
        models_per_window_out[key] = rows

    # Recent sessions are built from the attributed replies, not the session
    # rows: a session's row cost/model can lag the messages that actually
    # spent the money, and the recent list must agree with the window totals.
    recent_by_session = {}
    for m in messages:
        if m["session"] in child_sessions:
            continue
        acc = recent_by_session.get(m["session"])
        if acc is None:
            acc = recent_by_session[m["session"]] = {
                "cost": 0.0,
                "input": 0,
                "output": 0,
                "reasoning": 0,
                "ts": 0,
                "model": m["model"],
                "provider": m["provider"],
            }
        acc["cost"] += m["cost"]
        acc["input"] += m["input"]
        acc["output"] += m["output"]
        acc["reasoning"] += m["reasoning"]
        if m["ts"] > acc["ts"]:
            acc["ts"] = m["ts"]
            # The model that served the latest reply is the session's model.
            if m["model"]:
                acc["model"] = m["model"]
            if m["provider"]:
                acc["provider"] = m["provider"]

    session_meta = {s["id"]: s for s in sessions}
    recent_sorted = sorted(
        recent_by_session.items(),
        key=lambda kv: kv[1]["ts"],
        reverse=True,
    )[:8]
    recent = []
    for sid, acc in recent_sorted:
        meta = session_meta.get(sid) or {}
        recent.append(
            {
                "id": sid,
                "title": (meta.get("title") or "")[:80],
                "model": acc["model"],
                "provider": provider_name(acc["provider"]),
                "cost": round(acc["cost"], 6),
                "input": acc["input"],
                "output": acc["output"],
                "reasoning": acc["reasoning"],
                "updated": acc["ts"] or meta.get("updated") or meta.get("created"),
            }
        )

    return (
        out_windows,
        providers,
        providers_today_rows,
        providers_by_window,
        models_per_window_out,
        recent,
    )


def _http_get(url, headers, timeout=8, max_retries=2):
    for attempt in range(max_retries + 1):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            # 429 is the only rate-limit signal worth retrying; other 4xx/5xx
            # are terminal for this key/endpoint.
            if e.code == 429 and attempt < max_retries:
                time.sleep(2 ** attempt)  # backoff
                continue
            raise
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            # Network blip or a non-JSON body (proxy/captive portal): retry,
            # then give up and let the caller record the error.
            if attempt < max_retries:
                time.sleep(1)
                continue
            raise
    return None


def fetch_openrouter():
    result = {
        "ok": False,
        "usage": 0.0,
        "daily": 0.0,
        "weekly": 0.0,
        "monthly": 0.0,
        "credits_total": 0.0,
        "credits_used": 0.0,
        "free_used": 0,
        "free_limit": 0,
        "budget_limit": 0.0,
        "budget_spend": 0.0,
        "budget_remaining": 0.0,
        "resets_at": "",
        "error": None,
    }

    # Serve from cache when fresh; the bar polls far more often than the
    # account changes, and OpenRouter rate-limits by key. Only a *complete*
    # payload is cached (see below), so a hit always has both key and credits.
    try:
        with open(OR_CACHE, "r", encoding="utf-8") as fh:
            cached = json.load(fh)
        if time.time() - float(cached.get("ts", 0)) < OR_TTL:
            data = cached.get("data") or {}
            if cached.get("complete") and data.get("credits_total"):
                data["ok"] = True
                data["error"] = None
                return data
    except (OSError, ValueError):
        pass

    key = get_key()
    if not key:
        result["error"] = "No OPENROUTER_API_KEY"
        return result

    headers = {"Authorization": "Bearer " + key, "Accept": "application/json"}

    try:
        payload = _http_get("https://openrouter.ai/api/v1/auth/key", headers)
        if not payload:
            result["error"] = "Empty response from /auth/key"
            return result
        data = payload.get("data", {})
        result.update(
            ok=True,
            usage=float(data.get("usage") or 0.0),
            daily=float(data.get("usage_daily") or 0.0),
            weekly=float(data.get("usage_weekly") or 0.0),
            monthly=float(data.get("usage_monthly") or 0.0),
        )
        free = data.get("free_model_daily_requests") or {}
        result["free_used"] = int(free.get("used") or 0)
        result["free_limit"] = int(free.get("limit") or 0)

        budget = data.get("effective_budget") or {}
        if budget:
            result["budget_limit"] = float(budget.get("limit_usd") or 0.0)
            result["budget_spend"] = float(budget.get("spend_usd") or 0.0)
            result["budget_remaining"] = float(budget.get("remaining_usd") or 0.0)
            result["resets_at"] = str(budget.get("resets_at") or "")
        else:
            budgets = data.get("budgets") or []
            if budgets:
                b = budgets[0]
                result["budget_limit"] = float(b.get("limit_usd") or 0.0)
                result["budget_spend"] = float(b.get("spend_usd") or 0.0)
                result["budget_remaining"] = float(b.get("remaining_usd") or 0.0)
                result["resets_at"] = str(b.get("resets_at") or "")
    except Exception as exc:  # noqa: BLE001 - never break the bar on a network hiccup
        result["error"] = str(exc)
        return result

    credits_ok = False
    try:
        credits = _http_get("https://openrouter.ai/api/v1/credits", headers)
        if credits:
            cdata = credits.get("data", {})
            result["credits_total"] = float(cdata.get("total_credits") or 0.0)
            result["credits_used"] = float(cdata.get("total_usage") or 0.0)
            credits_ok = result["credits_total"] > 0.0
    except Exception:
        pass

    # Only a fully-resolved payload (key + credits) is worth caching: caching
    # a half-failed run would serve ok=True with zero credits for the TTL.
    if credits_ok:
        try:
            os.makedirs(os.path.dirname(OR_CACHE), exist_ok=True)
            tmp = OR_CACHE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump({"ts": time.time(), "complete": True, "data": result}, fh)
            os.replace(tmp, OR_CACHE)
        except OSError:
            pass

    return result


def main():
    sessions = load_sessions()
    messages = load_messages(sessions) or messages_from_sessions(sessions)
    windows, providers, providers_today, providers_by_window, models, recent = aggregate(
        sessions, messages
    )
    openrouter = fetch_openrouter()

    sys.stdout.write(
        json.dumps(
            {
                "generated_at": int(time.time() * 1000),
                "windows": windows,
                "providers": providers,
                "providers_today": providers_today,
                "providers_by_window": providers_by_window,
                "models": models,
                "recent": recent,
                "openrouter": openrouter,
            },
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()