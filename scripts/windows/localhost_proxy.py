#!/usr/bin/env python3
import argparse
import asyncio
import contextlib
import socket


def target_is_reachable(host: str, port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(1.0)
        try:
            sock.connect((host, port))
        except OSError:
            return False
        return True


async def pipe_stream(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    finally:
        with contextlib.suppress(Exception):
            writer.close()
            await writer.wait_closed()


async def handle_client(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    target_host: str,
    target_port: int,
) -> None:
    try:
        target_reader, target_writer = await asyncio.open_connection(target_host, target_port)
    except Exception:
        with contextlib.suppress(Exception):
            client_writer.close()
            await client_writer.wait_closed()
        return

    await asyncio.gather(
        pipe_stream(client_reader, target_writer),
        pipe_stream(target_reader, client_writer),
        return_exceptions=True,
    )


async def watchdog(server: asyncio.AbstractServer, target_host: str, target_port: int) -> None:
    missed_checks = 0
    while True:
        await asyncio.sleep(2)
        if target_is_reachable(target_host, target_port):
            missed_checks = 0
            continue

        missed_checks += 1
        if missed_checks < 2:
            continue

        server.close()
        await server.wait_closed()
        break


async def main() -> None:
    parser = argparse.ArgumentParser(description="Forward localhost traffic to a target host and port.")
    parser.add_argument("--listen-host", required=True)
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", type=int, required=True)
    args = parser.parse_args()

    server = await asyncio.start_server(
        lambda reader, writer: handle_client(reader, writer, args.target_host, args.target_port),
        host=args.listen_host,
        port=args.listen_port,
    )

    async with server:
        monitor_task = asyncio.create_task(watchdog(server, args.target_host, args.target_port))
        try:
            await server.serve_forever()
        except asyncio.CancelledError:
            raise
        except RuntimeError:
            pass
        finally:
            monitor_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await monitor_task


if __name__ == "__main__":
    asyncio.run(main())