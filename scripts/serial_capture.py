"""Reset an ESP32 on a USB-Serial/JTAG (or USB-UART) port and capture its boot log.

Non-interactive alternative to `idf.py monitor`, handy for scripts and for saving
the log to a file.

    python serial_capture.py --port COM4 --seconds 10 --out logs/boot.txt
    python serial_capture.py --port COM4 --no-reset --seconds 30   # just listen
"""

import argparse
import sys
import time

import serial


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--no-reset", action="store_true")
    ap.add_argument("--out")
    args = ap.parse_args()

    ser = serial.Serial()
    ser.port, ser.baudrate, ser.timeout = args.port, args.baud, 0.2
    # Open with DTR/RTS released so opening the port does not hold the chip in reset.
    ser.dtr = False
    ser.rts = False
    ser.open()

    if not args.no_reset:
        # Same as esptool's hard reset: RTS pulls EN low while DTR stays released.
        # Windows' usbser.sys only sends the new line state when DTR is written too,
        # so re-write DTR after each RTS change (esptool does the same), or the reset never arrives.
        ser.rts = True
        ser.dtr = ser.dtr
        time.sleep(0.2)
        ser.rts = False
        ser.dtr = ser.dtr

    buf = bytearray()
    end = time.time() + args.seconds
    while time.time() < end:
        chunk = ser.read(4096)
        if chunk:
            buf += chunk
            sys.stdout.write(chunk.decode("utf-8", "replace"))
            sys.stdout.flush()
    ser.close()

    if args.out:
        with open(args.out, "wb") as f:
            f.write(buf)
        print(f"\n[saved {len(buf)} bytes to {args.out}]")


if __name__ == "__main__":
    main()
