#!/usr/bin/python3
"""rtl_tcp の前段の中継。

rtl_tcp は、前のクライアントの後始末（スレッドの終了待ち）が済むまで次の接続を accept しない。
そのため、切断の直後につなぎ直すとヘッダー（RTL0、12 バイト）が届くまで 0〜3 秒以上かかる
（2026-10-17、10 回中 1 回が 3 秒を超えた）。jr-radio はヘッダーを 3 秒しか待たず、その後は
「IQ が 5 秒届かない」で失敗する。そこで、前回のヘッダーを覚えておいてすぐに返し、
裏の rtl_tcp には接続できるまで待ってからつなぐ。クライアントの設定コマンドは TCP のバッファに
たまり、つながってから届く。

rtl_tcp は同時に 1 クライアントだけなので、2 本目の同時接続はすぐに閉じる（待たせると
相手には偽のヘッダーのあとに無音が続く）。

IQ の保存（復調の比較用）: SIGUSR1 で、流れている IQ を CAPTURE_SECONDS 秒だけ
$STATE_DIRECTORY/iq-<UTC>.cu8 にそのまま書く（rtl_tcp の形式。I, Q の順に符号なし 8 ビット）。
同名の .json に、ヘッダーと、そのときの設定（周波数、サンプルレート、ゲインなど）と、
保存中にクライアントが送った設定コマンドを書く。SIGUSR2 で途中で止める。
クライアントが切れたら止める（つなぎ直すと設定が変わりうるので、1 ファイル = 1 接続）。
空きが FREE_MIN_BYTES を割りそうなら始めない・止める。受信内容なので LXC の外へ出さない
（電波法 59 条）。

使い方: rtl_tcp_relay.py <待受アドレス> <待受ポート> <rtl_tcp のアドレス> <rtl_tcp のポート>
"""
import asyncio
import datetime
import json
import os
import shutil
import signal
import struct
import sys

UPSTREAM_WAIT = 4.0  # jr-radio の「IQ が 5 秒届かない」に収まるように
CAPTURE_SECONDS = float(os.environ.get("CAPTURE_SECONDS", "300"))
FREE_MIN_BYTES = 512 * 1024 * 1024  # rootfs は 3.9 GB。ほかの用途のために残す
# rtl_tcp のコマンド（1 バイトの種類 + ビッグエンディアン 4 バイト）。名前は JSON 用
COMMANDS = {
    0x01: "frequency_hz",
    0x02: "sample_rate",
    0x03: "gain_mode_manual",
    0x04: "gain_tenth_db",
    0x05: "ppm",
    0x06: "if_gain",
    0x07: "test_mode",
    0x08: "agc_mode",
    0x09: "direct_sampling",
    0x0A: "offset_tuning",
    0x0D: "gain_index",
    0x0E: "bias_tee",
}
header = None  # 最後に rtl_tcp から受け取ったヘッダー
busy = False
settings = {}  # クライアントが最後に送った設定。rtl_tcp はデバイスを開いたままなので接続をまたいで残る
capture = None  # 保存中の Capture


def now():
    return datetime.datetime.now(datetime.timezone.utc)


class Capture:
    def __init__(self, directory):
        self.started = now()
        stem = os.path.join(directory, "iq-" + self.started.strftime("%Y%m%dT%H%M%SZ"))
        self.data_path = stem + ".cu8"
        self.meta_path = stem + ".json"
        self.file = open(self.data_path, "xb")
        self.bytes = 0
        self.settings = dict(settings)
        self.commands = []  # 保存中に届いたコマンド。byte は .cu8 の中の位置
        self.stopped = None
        self.reason = None
        self.write_meta()

    def write_meta(self):
        meta = {
            "format": "cu8 (rtl_tcp: I, Q, unsigned 8-bit, (x - 127.5) / 128)",
            "header_hex": header.hex() if header else None,
            "tuner_type": struct.unpack(">I", header[4:8])[0] if header else None,
            "started_at": self.started.isoformat(),
            "stopped_at": self.stopped.isoformat() if self.stopped else None,
            "stop_reason": self.reason,
            "bytes": self.bytes,
            "samples": self.bytes // 2,
            "settings_at_start": self.settings,
            "commands": self.commands,
        }
        temporary = self.meta_path + ".tmp"
        with open(temporary, "w") as f:
            json.dump(meta, f, ensure_ascii=False, indent=1)
        os.replace(temporary, self.meta_path)

    def stop(self, reason):
        global capture
        if capture is self:
            capture = None
        self.file.close()
        self.stopped = now()
        self.reason = reason
        self.write_meta()
        seconds = (self.stopped - self.started).total_seconds()
        print(f"IQ の保存を終了（{reason}）: {self.data_path} {self.bytes} バイト {seconds:.1f} 秒", flush=True)


def start_capture():
    global capture
    if capture:
        print(f"IQ はすでに保存中: {capture.data_path}", flush=True)
        return
    if not busy:
        print("クライアントがつながっていないので IQ を保存しない", flush=True)
        return
    directory = os.environ.get("STATE_DIRECTORY")
    if not directory:
        print("STATE_DIRECTORY がないので IQ を保存しない", flush=True)
        return
    rate = settings.get("sample_rate", 2_400_000)
    need = FREE_MIN_BYTES + int(2 * rate * CAPTURE_SECONDS)
    free = shutil.disk_usage(directory).free
    if free < need:
        print(f"空きが足りないので IQ を保存しない（空き {free} バイト、必要 {need} バイト）", flush=True)
        return
    capture = Capture(directory)
    asyncio.get_running_loop().call_later(CAPTURE_SECONDS, stop_capture, capture, "時間")
    print(f"IQ の保存を開始（{CAPTURE_SECONDS:.0f} 秒）: {capture.data_path} 設定 {settings}", flush=True)


def stop_capture(target=None, reason="SIGUSR2"):
    if capture and (target is None or target is capture):
        capture.stop(reason)


async def pump_iq(reader, writer):
    """rtl_tcp → クライアント。保存中は同じバイト列をファイルにも書く。"""
    try:
        while data := await reader.read(65536):
            writer.write(data)
            if capture:
                try:
                    capture.file.write(data)
                    capture.bytes += len(data)
                except OSError as e:
                    capture.stop(f"書き込みエラー: {e}")
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        writer.close()


async def pump_commands(reader, writer):
    """クライアント → rtl_tcp。5 バイト単位のコマンドを読んで、設定として覚えておく。"""
    pending = b""
    try:
        while data := await reader.read(65536):
            writer.write(data)
            pending += data
            while len(pending) >= 5:
                kind, value = struct.unpack(">BI", pending[:5])
                pending = pending[5:]
                name = COMMANDS.get(kind, f"command_{kind:#04x}")
                # ppm と IF ゲインは rtl_tcp の中で int として扱われる
                if kind in (0x05, 0x06) and value >= 1 << 31:
                    value -= 1 << 32
                settings[name] = value
                if capture:
                    capture.commands.append({"byte": capture.bytes, "name": name, "value": value})
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        writer.close()


async def connect_upstream(host, port):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + UPSTREAM_WAIT
    while True:
        remaining = deadline - loop.time()
        if remaining <= 0:
            raise TimeoutError("rtl_tcp に接続できません")
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(host, port), remaining
            )
            upstream_header = await asyncio.wait_for(
                reader.readexactly(12), max(deadline - loop.time(), 0.1)
            )
            return reader, writer, upstream_header
        except (ConnectionError, OSError):
            await asyncio.sleep(0.2)


async def handle(client_reader, client_writer, upstream):
    global header, busy
    peer = client_writer.get_extra_info("peername")
    if busy:
        print(f"{peer}: 別のクライアントが使用中なので閉じる", flush=True)
        client_writer.close()
        return
    busy = True
    up_writer = None
    try:
        sent = header is not None
        if sent:
            client_writer.write(header)
            await client_writer.drain()
        up_reader, up_writer, upstream_header = await connect_upstream(*upstream)
        if not sent:
            client_writer.write(upstream_header)
            await client_writer.drain()
        elif upstream_header != header:
            print(f"{peer}: ヘッダーが変わった（ドングルの交換？）。次の接続から新しいものを返す", flush=True)
        header = upstream_header
        print(f"{peer}: 接続", flush=True)
        await asyncio.gather(
            pump_commands(client_reader, up_writer), pump_iq(up_reader, client_writer)
        )
    except (TimeoutError, asyncio.TimeoutError, asyncio.IncompleteReadError) as e:
        print(f"{peer}: {e or 'rtl_tcp がヘッダーを返さない'}", flush=True)
    finally:
        client_writer.close()
        if up_writer:
            up_writer.close()
        busy = False
        stop_capture(reason="切断")
        print(f"{peer}: 切断", flush=True)


async def main():
    listen_host, listen_port, up_host, up_port = sys.argv[1:5]
    upstream = (up_host, int(up_port))
    loop = asyncio.get_running_loop()
    loop.add_signal_handler(signal.SIGUSR1, start_capture)
    loop.add_signal_handler(signal.SIGUSR2, stop_capture)
    server = await asyncio.start_server(
        lambda r, w: handle(r, w, upstream), listen_host, int(listen_port)
    )
    print(f"{listen_host}:{listen_port} -> {up_host}:{up_port}", flush=True)
    async with server:
        await server.serve_forever()


asyncio.run(main())
