"""LLM-jp-4.1 (llm-jp-harmony-v1) 用の OpenAI 互換プロキシ。

LM Studio の /v1/chat/completions は LLM-jp-4.1 を gpt-oss 用の PEG パーサーで読もうとして
500 (does not match the expected peg-native format) になる。原因は LLM-jp-4.1 の tokenizer が
special token の直後に空白を decode すること (`<|channel|> analysis<|message|> ...`)。
upstream の専用パーサー (ggml-org/llama.cpp#29667) は未マージ。

そこで chat template をここで自前展開して LM Studio の生の /v1/completions に流し、
返ってきた Harmony 出力を空白を許容してパースし、reasoning_content / content に分けて返す。
tool calling は非対応（tools は無視する）。標準ライブラリのみ。
"""

import datetime
import http.client
import json
import os
import re
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

UPSTREAM = urlsplit(os.environ.get("UPSTREAM", "http://lmstudio.ai.svc.cluster.local:1234"))
# Open WebUI に見せるモデル ID → LM Studio 側のモデル ID。"見せるID=upstreamID" を ; 区切り。
# 見せる ID は LM Studio 直のものと被らないよう別名にする
MODELS = dict(
    pair.split("=", 1) for pair in os.environ.get(
        "MODELS", "llm-jp-4.1-32b-a3b-thinking-proxy=llm-jp-4.1-32b-a3b-thinking").split(";")
    if "=" in pair)
API_KEY = os.environ.get("API_KEY", "")
TZ = datetime.timezone(datetime.timedelta(hours=9))

# Open WebUI へ流すパラメータ（それ以外は捨てる）
PASSTHROUGH = ("temperature", "top_p", "top_k", "min_p", "max_tokens", "seed",
               "frequency_penalty", "presence_penalty", "repeat_penalty")


def text_of(content):
    if content is None:
        return ""
    if isinstance(content, list):  # multimodal parts
        return "".join(p.get("text", "") for p in content if isinstance(p, dict))
    return str(content)


def strip_reasoning(s):
    # Open WebUI が履歴に思考ブロックを埋めて返してきた場合に落とす（CoT は過去ターンに入れない）
    s = re.sub(r"<details type=\"reasoning\".*?</details>", "", s, flags=re.S)
    s = re.sub(r"<think>.*?</think>", "", s, flags=re.S)
    return s.strip()


def render(messages, reasoning_effort):
    """chat_template.jinja (llm-jp-harmony-v1) を tools なしで再現する。"""
    today = datetime.datetime.now(TZ).strftime("%Y-%m-%d")
    out = ["<|start|>system<|message|>"
           "You are LLM-jp-4, a large language model trained by LLM-jp.\n"
           "Knowledge cutoff: 2025-12\n"
           f"Current date: {today}\n\n"
           f"Reasoning: {reasoning_effort}\n\n"
           "# Valid channels: analysis, commentary, final. Channel must be included for every message."
           "<|end|>"]
    msgs = list(messages)
    if msgs and msgs[0].get("role") in ("system", "developer"):
        dev = text_of(msgs.pop(0).get("content"))
        if dev:
            out.append(f"<|start|>developer<|message|># Instructions\n\n{dev}\n\n<|end|>")
    for m in msgs:
        role = m.get("role")
        if role == "user":
            out.append(f"<|start|>user<|message|>{text_of(m.get('content'))}<|end|>")
        elif role == "assistant":
            c = strip_reasoning(text_of(m.get("content")))
            if c:
                out.append(f"<|start|>assistant<|channel|>final<|message|>{c}<|end|>")
        # tool / その他のロールは非対応なので落とす
    out.append("<|start|>assistant")
    return "".join(out)


TAG = re.compile(r"<\|(start|end|return|call|channel|message|constrain)\|>")


class HarmonyParser:
    """ストリームで届く Harmony 出力を (channel, text) の差分に分解する。

    special token の後の空白（LLM-jp-4.1 の tokenizer 由来）はすべて許容する。
    """

    def __init__(self):
        self.buf = ""
        self.state = "header"   # header: <|message|> 待ち / body: 本文中 / done
        self.header = ""
        self.channel = None
        self.body_started = False

    def feed(self, text):
        self.buf += text
        events = []
        while self.buf and self.state != "done":
            if self.state == "header":
                i = self.buf.find("<|message|>")
                if i < 0:
                    # ヘッダーが来ないまま本文っぽいものが続く場合は final 扱いにする
                    if len(self.buf) > 200:
                        self.channel, self.state, self.body_started = "final", "body", True
                        continue
                    break
                self.header += self.buf[:i]
                self.buf = self.buf[i + len("<|message|>"):]
                m = re.search(r"<\|channel\|>\s*(\w+)", self.header)
                self.channel = m.group(1) if m else "final"
                self.header = ""
                self.state, self.body_started = "body", False
            else:
                m = TAG.search(self.buf)
                if m:
                    chunk, tag = self.buf[:m.start()], m.group(1)
                    self.buf = self.buf[m.end():]
                else:
                    # タグの途中で切れているかもしれない末尾は保留
                    j = self.buf.rfind("<")
                    hold = j >= 0 and len(self.buf) - j < 16
                    chunk = self.buf[:j] if hold else self.buf
                    self.buf = self.buf[j:] if hold else ""
                    tag = None
                if not self.body_started and chunk:
                    chunk = chunk.lstrip(" ")
                    if chunk:
                        self.body_started = True
                if chunk:
                    events.append((self.channel, chunk))
                if tag is None:
                    break
                if tag in ("return", "call"):
                    self.state = "done"
                elif tag in ("end", "start"):
                    self.state = "header"
                    if tag == "start":
                        self.header = "<|start|>"
                else:  # 本文中に突然 channel 等 → ヘッダーとして読み直す
                    self.state, self.header = "header", f"<|{tag}|>"
        return events

    def flush(self):
        if self.state == "body" and self.buf and not TAG.match(self.buf):
            ev = [(self.channel, self.buf)]
            self.buf = ""
            return ev
        return []


def upstream_conn():
    port = UPSTREAM.port or 80
    return http.client.HTTPConnection(UPSTREAM.hostname, port, timeout=600)


def stream_completion(req):
    """upstream /v1/completions を叩いて (channel, text) と usage/finish を yield する。"""
    effort = req.get("reasoning_effort") or "medium"
    if effort not in ("low", "medium", "high"):
        effort = "medium"
    upstream_model = MODELS.get(req.get("model"))
    if upstream_model is None:
        raise ValueError(f"unknown model: {req.get('model')!r}")
    body = {"model": upstream_model, "prompt": render(req.get("messages", []), effort),
            "stream": True, "stop": ["<|return|>", "<|call|>"]}
    for k in PASSTHROUGH:
        if req.get(k) is not None:
            body[k] = req[k]
    if req.get("max_completion_tokens") and "max_tokens" not in body:
        body["max_tokens"] = req["max_completion_tokens"]
    conn = upstream_conn()
    conn.request("POST", "/v1/completions", json.dumps(body),
                 {"Content-Type": "application/json"})
    resp = conn.getresponse()
    if resp.status != 200:
        raise RuntimeError(f"upstream {resp.status}: {resp.read()[:500].decode(errors='replace')}")
    parser = HarmonyParser()
    for raw in resp:
        line = raw.decode("utf-8", errors="replace").strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        j = json.loads(data)
        if "error" in j:
            raise RuntimeError(f"upstream error: {j['error']}")
        ch = (j.get("choices") or [{}])[0]
        for ev in parser.feed(ch.get("text") or ""):
            yield ("delta",) + ev
        if ch.get("finish_reason"):
            yield ("finish", ch["finish_reason"])
        if j.get("usage"):
            yield ("usage", j["usage"])
    for ev in parser.flush():
        yield ("delta",) + ev
    conn.close()


def field(channel):
    return "content" if channel == "final" else "reasoning_content"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def send_json(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def authorized(self):
        if API_KEY and self.headers.get("Authorization") != f"Bearer {API_KEY}":
            self.send_json(401, {"error": {"message": "unauthorized"}})
            return False
        return True

    def do_GET(self):
        if self.path.rstrip("/") in ("/healthz",):
            return self.send_json(200, {"ok": True})
        if not self.authorized():
            return
        if self.path.rstrip("/") == "/v1/models":
            return self.send_json(200, {"object": "list", "data": [
                {"id": m, "object": "model", "owned_by": "llm-jp"} for m in MODELS]})
        self.send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if not self.authorized():
            return
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self.send_json(404, {"error": {"message": "not found"}})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except Exception as e:
            return self.send_json(400, {"error": {"message": f"bad json: {e}"}})
        cid = "chatcmpl-" + uuid.uuid4().hex[:24]
        created = int(time.time())
        if req.get("model") not in MODELS:
            return self.send_json(404, {"error": {"message": f"unknown model: {req.get('model')!r}"}})
        if req.get("stream"):
            self.stream(req, cid, created)
        else:
            self.blocking(req, cid, created)

    def blocking(self, req, cid, created):
        acc = {"content": "", "reasoning_content": ""}
        finish, usage = "stop", None
        try:
            for ev in stream_completion(req):
                if ev[0] == "delta":
                    acc[field(ev[1])] += ev[2]
                elif ev[0] == "finish":
                    finish = ev[1]
                elif ev[0] == "usage":
                    usage = ev[1]
        except Exception as e:
            return self.send_json(502, {"error": {"message": str(e), "type": "upstream_error"}})
        msg = {"role": "assistant", "content": acc["content"].rstrip()}
        if acc["reasoning_content"]:
            msg["reasoning_content"] = acc["reasoning_content"].rstrip()
        out = {"id": cid, "object": "chat.completion", "created": created, "model": req.get("model"),
               "choices": [{"index": 0, "message": msg, "finish_reason": finish}]}
        if usage:
            out["usage"] = usage
        self.send_json(200, out)

    def stream(self, req, cid, created):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def send(obj):
            b = f"data: {json.dumps(obj, ensure_ascii=False)}\n\n".encode()
            self.wfile.write(f"{len(b):x}\r\n".encode() + b + b"\r\n")
            self.wfile.flush()

        def chunk(delta, finish=None, usage=None):
            o = {"id": cid, "object": "chat.completion.chunk", "created": created,
                 "model": req.get("model"),
                 "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            if usage:
                o["usage"] = usage
            return o

        finish, usage = "stop", None
        try:
            send(chunk({"role": "assistant"}))
            for ev in stream_completion(req):
                if ev[0] == "delta":
                    send(chunk({field(ev[1]): ev[2]}))
                elif ev[0] == "finish":
                    finish = ev[1]
                elif ev[0] == "usage":
                    usage = ev[1]
            send(chunk({}, finish, usage))
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:
            try:
                send({"error": {"message": str(e), "type": "upstream_error"}})
            except OSError:
                return
        try:
            b = b"data: [DONE]\n\n"
            self.wfile.write(f"{len(b):x}\r\n".encode() + b + b"\r\n0\r\n\r\n")
            self.wfile.flush()
        except OSError:
            pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8000"))
    print(f"llmjp-proxy :{port} -> {UPSTREAM.geturl()} {MODELS}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
