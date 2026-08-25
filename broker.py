#!/usr/bin/env python3
"""Host-side LLM broker: secrets stay here, never enter the sandbox."""

from __future__ import annotations

import argparse
import hmac
import json
import os
import socketserver
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any
from urllib.parse import urljoin, urlparse

# Request body from sandbox clients (agent prompts / tool payloads).
MAX_REQUEST_BYTES = 8 * 1024 * 1024
# Upstream error bodies fully buffered for redaction; success streams in chunks.
MAX_UPSTREAM_ERROR_BYTES = 256 * 1024
MAX_UPSTREAM_STREAM_BYTES = 32 * 1024 * 1024
MAX_CONCURRENT_CONNECTIONS = 8
REQUEST_TIMEOUT_SEC = 300.0
IDLE_HEADER_TIMEOUT_SEC = 30.0
STREAM_CHUNK = 8192

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
    "authorization",
    "x-api-key",
    "x-goog-api-key",
    "api-key",
}

PROVIDERS: dict[str, dict[str, Any]] = {
    "xai": {
        "upstream": "https://api.x.ai/v1",
        "style": "openai",
        "env": ("XAI_API_KEY", "GROK_API_KEY"),
    },
    "openai": {
        "upstream": "https://api.openai.com/v1",
        "style": "openai",
        "env": ("OPENAI_API_KEY",),
    },
    "anthropic": {
        "upstream": "https://api.anthropic.com",
        "style": "anthropic",
        "env": ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_API_KEY"),
    },
    "google": {
        "upstream": "https://generativelanguage.googleapis.com/v1beta/openai",
        "style": "openai",
        "env": ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_API_KEY"),
    },
    "openrouter": {
        "upstream": "https://openrouter.ai/api/v1",
        "style": "openai",
        "env": ("OPENROUTER_API_KEY",),
    },
    "groq": {
        "upstream": "https://api.groq.com/openai/v1",
        "style": "openai",
        "env": ("GROQ_API_KEY",),
    },
    "mistral": {
        "upstream": "https://api.mistral.ai/v1",
        "style": "openai",
        "env": ("MISTRAL_API_KEY",),
    },
    "deepseek": {
        "upstream": "https://api.deepseek.com",
        "style": "openai",
        "env": ("DEEPSEEK_API_KEY",),
    },
    "cerebras": {
        "upstream": "https://api.cerebras.ai/v1",
        "style": "openai",
        "env": ("CEREBRAS_API_KEY",),
    },
    "together": {
        "upstream": "https://api.together.xyz/v1",
        "style": "openai",
        "env": ("TOGETHER_API_KEY",),
    },
    "fireworks": {
        "upstream": "https://api.fireworks.ai/inference/v1",
        "style": "openai",
        "env": ("FIREWORKS_API_KEY",),
    },
}

PROVIDER_ALIASES = {
    "gemini": "google",
    "grok": "xai",
    "claude": "anthropic",
}

NON_CHAT = ("imagine", "video", "image", "tts", "whisper", "embed")


def home() -> Path:
    return Path.home()


def die(msg: str, code: int = 1) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def is_chat_model(model: str | None) -> bool:
    if not model:
        return False
    lower = model.lower()
    return not any(part in lower for part in NON_CHAT)


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def token_from_auth_entry(entry: Any) -> str | None:
    if isinstance(entry, str) and entry:
        return entry
    if not isinstance(entry, dict):
        return None
    for key in ("key", "apiKey", "api_key", "access", "access_token", "token"):
        val = entry.get(key)
        if isinstance(val, str) and val:
            return val
    return None


def opencode_auth() -> dict[str, Any]:
    data = read_json(home() / ".local/share/opencode/auth.json")
    return data if isinstance(data, dict) else {}


def last_opencode_model() -> tuple[str, str] | None:
    state = read_json(home() / ".local/state/opencode/model.json")
    if isinstance(state, dict):
        recent = state.get("recent")
        if isinstance(recent, list):
            for item in recent:
                if not isinstance(item, dict):
                    continue
                provider = item.get("providerID") or item.get("provider")
                model = item.get("modelID") or item.get("id")
                if isinstance(provider, str) and isinstance(model, str) and is_chat_model(model):
                    return provider, model
        provider = state.get("providerID")
        model = state.get("modelID")
        if isinstance(provider, str) and isinstance(model, str) and is_chat_model(model):
            return provider, model

    db = home() / ".local/share/opencode/opencode.db"
    if db.is_file():
        try:
            import sqlite3

            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            row = con.execute(
                "SELECT model FROM session WHERE model IS NOT NULL AND model != '' "
                "ORDER BY time_updated DESC LIMIT 8"
            ).fetchall()
            con.close()
        except Exception:
            row = []
        for (raw,) in row:
            try:
                parsed = json.loads(raw)
            except (TypeError, json.JSONDecodeError):
                continue
            if not isinstance(parsed, dict):
                continue
            provider = parsed.get("providerID") or parsed.get("provider")
            model = parsed.get("id") or parsed.get("modelID")
            if isinstance(provider, str) and isinstance(model, str) and is_chat_model(model):
                return provider, model

    cfg = read_json(home() / ".config/opencode/opencode.json")
    if isinstance(cfg, dict):
        model = cfg.get("model")
        if isinstance(model, str) and "/" in model:
            provider, name = model.split("/", 1)
            if is_chat_model(name):
                return provider, name
    return None


def last_agent_model(agent: str) -> tuple[str, str] | None:
    if agent == "opencode":
        return last_opencode_model()
    if agent == "grok":
        cfg = home() / ".grok/config.toml"
        if cfg.is_file():
            try:
                text = cfg.read_text()
            except OSError:
                text = ""
            for pattern in (
                r'(?m)^\s*fork_secondary_model\s*=\s*"([^"]+)"',
                r'(?m)^\s*model\s*=\s*"([^"]+)"',
            ):
                import re

                m = re.search(pattern, text)
                if m and is_chat_model(m.group(1)):
                    return "xai", m.group(1)
        return "xai", "grok-4.6"
    if agent == "claude":
        return "anthropic", "claude-sonnet-4-5"
    if agent == "gemini":
        return "google", "gemini-2.5-pro"
    if agent == "codex":
        cfg = home() / ".codex/config.toml"
        if cfg.is_file():
            import re

            m = re.search(r'(?m)^\s*model\s*=\s*"([^"]+)"', cfg.read_text())
            if m and is_chat_model(m.group(1)):
                return "openai", m.group(1)
        return "openai", "gpt-5"
    if agent in {"pi", "omp"}:
        for rel in (".pi/agent/settings.json", ".omp/agent/settings.json"):
            data = read_json(home() / rel)
            if not isinstance(data, dict):
                continue
            for key in ("model", "defaultModel", "lastModel"):
                val = data.get(key)
                if isinstance(val, str) and val:
                    if "/" in val:
                        provider, name = val.split("/", 1)
                        if is_chat_model(name):
                            return provider, name
                    if is_chat_model(val):
                        return "anthropic", val
    return None


def env_token(names: tuple[str, ...]) -> str | None:
    for name in names:
        val = os.environ.get(name)
        if isinstance(val, str) and val.strip():
            return val.strip()
    return None


def file_token(paths: list[Path], keys: tuple[str, ...]) -> str | None:
    for path in paths:
        data = read_json(path)
        if data is None:
            continue
        token = token_from_auth_entry(data)
        if token:
            return token
        if isinstance(data, dict):
            for key in keys:
                token = token_from_auth_entry(data.get(key))
                if token:
                    return token
    return None


def resolve_provider(name: str) -> str:
    name = name.lower()
    return PROVIDER_ALIASES.get(name, name)


def credential_for(provider: str) -> str | None:
    spec = PROVIDERS[provider]
    auth = opencode_auth()
    token = token_from_auth_entry(auth.get(provider))
    if token:
        return token
    if provider == "google":
        token = token_from_auth_entry(auth.get("gemini"))
        if token:
            return token
    if provider == "xai":
        token = file_token([home() / ".grok/auth.json"], ("access", "apiKey", "key"))
        if token:
            return token
    if provider == "anthropic":
        token = file_token(
            [
                home() / ".claude/.credentials.json",
                home() / ".config/claude/.credentials.json",
            ],
            ("claudeAiOauth", "accessToken", "access_token"),
        )
        if token:
            return token
    if provider == "openai":
        token = file_token([home() / ".codex/auth.json"], ("access_token", "api_key", "key"))
        if token:
            return token
    return env_token(spec["env"])


def pick_route(agent: str, requested_model: str | None) -> dict[str, Any]:
    provider = None
    model = None
    if requested_model and "/" in requested_model:
        provider, model = requested_model.split("/", 1)
    elif requested_model:
        model = requested_model

    guessed = last_agent_model(agent)
    if guessed:
        if not provider:
            provider = guessed[0]
        if not model or not is_chat_model(model):
            model = guessed[1]

    if provider:
        provider = resolve_provider(provider)

    if provider not in PROVIDERS or not credential_for(provider):
        auth_keys = [resolve_provider(k) for k in opencode_auth()]
        for candidate in auth_keys + list(PROVIDERS):
            if candidate in PROVIDERS and credential_for(candidate):
                provider = candidate
                if not model or resolve_provider((guessed or ("", ""))[0]) != candidate:
                    model = model if guessed and resolve_provider(guessed[0]) == candidate else "default"
                break

    if provider not in PROVIDERS:
        die("No supported LLM provider credentials found on the host.")
    token = credential_for(provider)
    if not token:
        die(f"No host credentials for provider {provider}.")
    if not model or not is_chat_model(model):
        model = "default"

    spec = dict(PROVIDERS[provider])
    if agent == "gemini" and provider == "google":
        spec["upstream"] = "https://generativelanguage.googleapis.com"
        spec["style"] = "google"
    parsed = urlparse(spec["upstream"])
    if parsed.scheme != "https" or not parsed.hostname:
        die("Refusing non-HTTPS upstream.")
    return {
        "provider": provider,
        "model": model,
        "style": spec["style"],
        "upstream": spec["upstream"],
        "upstream_host": parsed.hostname,
        "token": token,
    }


MODEL_API_SUFFIXES = (
    "/chat/completions",
    "/completions",
    "/responses",
    "/messages",
    "/messages/count_tokens",
)


def is_model_api(url: str) -> bool:
    path = urlparse(url).path.rstrip("/")
    if path.endswith(":generateContent") or path.endswith(":streamGenerateContent"):
        return True
    return any(path == suf or path.endswith(suf) for suf in MODEL_API_SUFFIXES)


def auth_headers(style: str, token: str) -> dict[str, str]:
    if style == "anthropic":
        return {
            "x-api-key": token,
            "anthropic-version": "2023-06-01",
            "authorization": f"Bearer {token}",
        }
    if style == "google":
        return {
            "x-goog-api-key": token,
            "authorization": f"Bearer {token}",
        }
    return {"authorization": f"Bearer {token}"}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:
        return None


UPSTREAM = urllib.request.build_opener(NoRedirect)


def join_upstream(upstream: str, path: str) -> str:
    base = upstream.rstrip("/") + "/"
    rel = path or "/"
    if rel.startswith("/"):
        rel = rel[1:]
    up = urlparse(upstream)
    up_path = up.path.rstrip("/")
    if up_path.endswith("/v1") and (rel == "v1" or rel.startswith("v1/")):
        rel = rel[3:].lstrip("/")
    return urljoin(base, rel)


def sanitize_error(text: str, token: str) -> str:
    if token and token in text:
        text = text.replace(token, "[redacted]")
    return text[:2000]


def parse_content_length(raw: str | None, limit: int) -> int | None:
    """Return body size, 0 if absent, or None if invalid/oversized."""
    if raw is None or raw == "":
        return 0
    if not raw.isdigit():
        return None
    try:
        length = int(raw)
    except ValueError:
        return None
    if length < 0 or length > limit:
        return None
    return length


def read_limited(fp: Any, limit: int) -> bytes:
    """Read at most limit bytes; raise ValueError if the body is larger."""
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = fp.read(STREAM_CHUNK)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise ValueError("body exceeds limit")
        chunks.append(chunk)
    return b"".join(chunks)


class Broker(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = IDLE_HEADER_TIMEOUT_SEC
    route: dict[str, Any] = {}
    gate_token: str = ""

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(IDLE_HEADER_TIMEOUT_SEC)

    def _authorized(self) -> bool:
        if not self.gate_token:
            return False
        auth = self.headers.get("Authorization", "")
        key = self.headers.get("x-api-key", "")
        got = ""
        if auth.lower().startswith("bearer "):
            got = auth[7:].strip()
        elif key:
            got = key.strip()
        if not got:
            return False
        return hmac.compare_digest(got, self.gate_token)

    def _reject(self, code: int, message: str) -> None:
        payload = json.dumps({"error": message}).encode()
        try:
            self.send_response(code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.send_header("connection", "close")
            self.end_headers()
            self.wfile.write(payload)
        except Exception:
            pass
        self.close_connection = True

    def do_GET(self) -> None:
        if urlparse(self.path).path in {"/health", "/"}:
            body = json.dumps(
                {
                    "ok": True,
                    "provider": self.route["provider"],
                    "model": self.route["model"],
                }
            ).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._forward()

    def do_POST(self) -> None:
        self._forward()

    def do_PUT(self) -> None:
        self._forward()

    def do_DELETE(self) -> None:
        self._forward()

    def _read_body(self) -> bytes | None:
        te = self.headers.get("Transfer-Encoding", "")
        if te and te.lower() not in ("", "identity"):
            self._reject(400, "chunked transfer encoding not allowed")
            return None
        length = parse_content_length(self.headers.get("Content-Length"), MAX_REQUEST_BYTES)
        if length is None:
            self._reject(413 if (self.headers.get("Content-Length") or "").isdigit() else 400, "invalid or oversized content-length")
            return None
        if length == 0:
            return b""
        try:
            data = self.rfile.read(length)
        except Exception:
            self._reject(400, "failed to read request body")
            return None
        if len(data) != length:
            self._reject(400, "incomplete request body")
            return None
        return data

    def _forward(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path in {"/health", "/"}:
            self.do_GET()
            return
        if not self._authorized():
            self.send_error(401, "invalid broker token")
            return
        dest = join_upstream(self.route["upstream"], parsed.path)
        dest_host = urlparse(dest).hostname
        if dest_host != self.route["upstream_host"]:
            self.send_error(403, "refusing unexpected upstream host")
            return
        if parsed.query:
            dest = dest + "?" + parsed.query

        headers: dict[str, str] = {}
        if is_model_api(dest):
            headers.update(auth_headers(self.route["style"], self.route["token"]))
        for key, value in self.headers.items():
            low = key.lower()
            if low in HOP_BY_HOP:
                continue
            headers[low] = value
        if "content-type" not in headers:
            headers["content-type"] = "application/json"

        body = self._read_body()
        if body is None:
            return
        # Drop client Content-Length; urllib sets it from data=.
        headers.pop("content-length", None)

        req = urllib.request.Request(dest, data=body or None, method=self.command, headers=headers)
        try:
            resp = UPSTREAM.open(req, timeout=REQUEST_TIMEOUT_SEC)
        except urllib.error.HTTPError as exc:
            try:
                raw = read_limited(exc, MAX_UPSTREAM_ERROR_BYTES)
            except ValueError:
                try:
                    exc.close()
                except Exception:
                    pass
                self._reject(502, "upstream error body too large")
                return
            payload = sanitize_error(raw.decode("utf-8", "replace"), self.route["token"]).encode()
            self.send_response(exc.code)
            self.send_header("content-type", exc.headers.get("content-type", "application/json"))
            self.send_header("content-length", str(len(payload)))
            self.send_header("connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            return
        except Exception as exc:
            payload = json.dumps({"error": "upstream failed", "detail": type(exc).__name__}).encode()
            self.send_response(502)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.send_header("connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            return

        with resp:
            # Reject advertised oversized success bodies before streaming.
            up_len = parse_content_length(resp.headers.get("Content-Length"), MAX_UPSTREAM_STREAM_BYTES)
            if resp.headers.get("Content-Length") and up_len is None:
                self._reject(502, "upstream response too large")
                return
            self.send_response(resp.status)
            for key, value in resp.headers.items():
                if key.lower() in HOP_BY_HOP or key.lower() == "content-length":
                    continue
                self.send_header(key, value)
            self.send_header("connection", "close")
            self.end_headers()
            total = 0
            while True:
                chunk = resp.read(STREAM_CHUNK)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_UPSTREAM_STREAM_BYTES:
                    self.close_connection = True
                    return
                self.wfile.write(chunk)
                self.wfile.flush()


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True
    block_on_close = False
    request_queue_size = MAX_CONCURRENT_CONNECTIONS
    timeout = IDLE_HEADER_TIMEOUT_SEC

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._conn_sem = threading.BoundedSemaphore(MAX_CONCURRENT_CONNECTIONS)

    def process_request(self, request: Any, client_address: Any) -> None:
        if not self._conn_sem.acquire(blocking=False):
            try:
                request.close()
            except Exception:
                pass
            return
        t = threading.Thread(
            target=self._process_request_gated,
            args=(request, client_address),
            daemon=self.daemon_threads,
        )
        t.start()

    def _process_request_gated(self, request: Any, client_address: Any) -> None:
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)
            self._conn_sem.release()


def public_route(route: dict[str, Any]) -> dict[str, Any]:
    return {
        "provider": route["provider"],
        "model": route["model"],
        "style": route["style"],
        "upstream_host": route["upstream_host"],
    }


def serve(ready_file: Path, route: dict[str, Any], gate_token: str) -> None:
    Broker.route = route
    Broker.gate_token = gate_token
    server = ThreadingTCPServer(("127.0.0.1", 0), Broker)
    port = int(server.server_address[1])
    info = public_route(route)
    info["port"] = port
    ready_file.write_text(json.dumps(info) + "\n")
    os.chmod(ready_file, 0o600)
    try:
        server.serve_forever()
    finally:
        server.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="AUR scan LLM broker")
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--agent", default="opencode")
    parser.add_argument("--model", default="")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    route = pick_route(args.agent, args.model or None)
    if args.check:
        json.dump(public_route(route), sys.stdout)
        sys.stdout.write("\n")
        return
    gate = os.environ.get("AUR_SCAN_BROKER_TOKEN", "")
    if len(gate) < 16:
        die("AUR_SCAN_BROKER_TOKEN is missing or too short.")
    serve(Path(args.ready_file), route, gate)


if __name__ == "__main__":
    main()
