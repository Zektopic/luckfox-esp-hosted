"""Back up (part of) the SPI flash of an ESP chip in small chunks.

On this PC the ESP32-C6's built-in USB-Serial/JTAG (COM4) could not do one
long read:
  * `esptool read_flash 0 0x400000` (flasher stub) stalled at ~4 %,
  * stub reads of 256 KB chunks failed with "Corrupt data, expected 0x1000 bytes",
  * a 904 KB ROM-loader read (--no-stub) died with "Packet content transfer stopped".
64 KB ROM-loader reads worked (~1.2 KB/s), so this reads the flash in chunks,
retries each chunk with a timeout, and joins them into one file.

Usage (any Python that has esptool installed, e.g. the ESP-IDF venv):
    python backup_flash.py --port COM4 --out backups/esp32c6.bin                 # whole 4 MB, stub
    python backup_flash.py --port COM4 --no-stub --chunk 0x10000 \
        --start 0x10000 --size 0xE2000 --out backups/app0.bin                    # one region, ROM

Restore later with:
    python -m esptool --port COM4 write_flash <start> <file>
"""

import argparse
import os
import subprocess
import sys
import tempfile


def read_chunk(port, addr, size, path, timeout, no_stub):
    cmd = [sys.executable, "-m", "esptool", "--port", port]
    if no_stub:
        cmd.append("--no-stub")
    cmd += ["read_flash", "--no-progress", hex(addr), hex(size), path]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "timeout"
    ok = res.returncode == 0 and os.path.exists(path) and os.path.getsize(path) == size
    return ok, (res.stdout + res.stderr).strip().splitlines()[-1:] or ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--start", default="0x0", help="first address to read (default 0)")
    ap.add_argument("--size", default="0x400000", help="bytes to read (default 4 MB)")
    ap.add_argument("--chunk", default="0x40000", help="chunk size (default 256 KB)")
    ap.add_argument("--no-stub", action="store_true",
                    help="use the ROM loader: slow (~1.2 KB/s) but works when the stub drops bytes")
    ap.add_argument("--retries", type=int, default=4)
    ap.add_argument("--timeout", type=int, default=120, help="seconds per chunk")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    start, total, chunk = int(args.start, 0), int(args.size, 0), int(args.chunk, 0)
    end = start + total
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp, open(args.out + ".part", "wb") as out:
        for addr in range(start, end, chunk):
            size = min(chunk, end - addr)
            part = os.path.join(tmp, f"{addr:08x}.bin")
            for attempt in range(1, args.retries + 1):
                ok, msg = read_chunk(args.port, addr, size, part, args.timeout, args.no_stub)
                if ok:
                    break
                print(f"  0x{addr:06x}: attempt {attempt} failed ({msg})", flush=True)
            else:
                sys.exit(f"giving up at 0x{addr:06x}")
            with open(part, "rb") as f:
                out.write(f.read())
            print(f"0x{addr + size:06x} / 0x{end:06x} done", flush=True)

    os.replace(args.out + ".part", args.out)
    print(f"wrote {args.out} ({os.path.getsize(args.out)} bytes)")


if __name__ == "__main__":
    main()
