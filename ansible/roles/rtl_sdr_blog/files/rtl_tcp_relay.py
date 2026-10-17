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

使い方: rtl_tcp_relay.py <待受アドレス> <待受ポート> <rtl_tcp のアドレス> <rtl_tcp のポート>
"""
import asyncio
import sys

UPSTREAM_WAIT = 4.0  # jr-radio の「IQ が 5 秒届かない」に収まるように
header = None  # 最後に rtl_tcp から受け取ったヘッダー
busy = False


async def pump(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
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
            pump(client_reader, up_writer), pump(up_reader, client_writer)
        )
    except (TimeoutError, asyncio.TimeoutError, asyncio.IncompleteReadError) as e:
        print(f"{peer}: {e or 'rtl_tcp がヘッダーを返さない'}", flush=True)
    finally:
        client_writer.close()
        if up_writer:
            up_writer.close()
        busy = False
        print(f"{peer}: 切断", flush=True)


async def main():
    listen_host, listen_port, up_host, up_port = sys.argv[1:5]
    upstream = (up_host, int(up_port))
    server = await asyncio.start_server(
        lambda r, w: handle(r, w, upstream), listen_host, int(listen_port)
    )
    print(f"{listen_host}:{listen_port} -> {up_host}:{up_port}", flush=True)
    async with server:
        await server.serve_forever()


asyncio.run(main())
