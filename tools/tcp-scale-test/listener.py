#!/usr/bin/env python3
# ACCEPT-class listener: accepts and immediately closes. One socket bound to
# 0.0.0.0:9101 answers for every fleet address - the whole accept class costs
# one process.
import asyncio

async def handle(reader, writer):
    writer.close()

async def main():
    srv = await asyncio.start_server(handle, '0.0.0.0', 9101, backlog=4096)
    async with srv:
        await srv.serve_forever()

asyncio.run(main())
