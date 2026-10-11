#!/usr/bin/env bash
# Luckfox Pico SDK helper, runs on the Linux build PC (ssh luckfox-build), inside Docker.
#
# Layout on the build PC:
#   ~/luckfox/luckfox-pico        LuckfoxTECH/luckfox-pico (shallow clone)
#   ~/luckfox/esp-hosted-linux    espressif/esp-hosted-linux @ 172a719 (same as the C6 firmware)
#   ~/luckfox/logs/               build logs
# Inside the container, ~/luckfox is mounted at /luckfox.
#
# Usage (on the build PC):
#   ~/luckfox/lf.sh up                    # create/start the long-lived "luckfox-sdk" container
#   ~/luckfox/lf.sh board                 # select Pico Pro/Max, SPI-NAND, Buildroot (no interactive lunch)
#   ~/luckfox/lf.sh build <name> <args>   # run "./build.sh <args>" detached, log to logs/<name>.log
#   ~/luckfox/lf.sh run <cmd...>          # run a command in the SDK root inside the container (foreground)
#   ~/luckfox/lf.sh status <name>         # tail a build log / show if it's still running
#   ~/luckfox/lf.sh fixperms              # give files created by the root container back to the host user
#
# Uses Luckfox's official image luckfoxtech/luckfox_pico:1.0 (Ubuntu 22.04.3, runs as root),
# because the build PC is Pop!_OS 24.04 and the SDK expects 22.04.
set -euo pipefail

IMAGE=luckfoxtech/luckfox_pico:1.0
NAME=luckfox-sdk
HOST_DIR=$HOME/luckfox
SDK=/luckfox/luckfox-pico
BOARD_CFG=project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk
HOST_UID=$(id -u)
HOST_GID=$(id -g)

cmd=${1:-}
shift || true

case "$cmd" in
up)
    if ! docker container inspect "$NAME" >/dev/null 2>&1; then
        docker run -d --name "$NAME" --privileged \
            -v "$HOST_DIR":/luckfox -w "$SDK" "$IMAGE" sleep infinity
    fi
    docker start "$NAME" >/dev/null
    docker exec "$NAME" sh -c 'echo "container up: $(. /etc/os-release; echo $PRETTY_NAME)"'
    ;;
board)
    # Same as the "lunch" menu does: a relative symlink .BoardConfig.mk -> the board config.
    docker exec -w "$SDK" "$NAME" sh -c "ln -rfs $BOARD_CFG .BoardConfig.mk && ls -l .BoardConfig.mk"
    ;;
build)
    name=$1; shift
    log=/luckfox/logs/$name.log
    docker exec -d -w "$SDK" "$NAME" bash -c \
        "{ date; echo '+ ./build.sh $*'; ./build.sh $*; rc=\$?; date; echo EXIT=\$rc; } > $log 2>&1; chown -R $HOST_UID:$HOST_GID /luckfox"
    echo "started ./build.sh $* -> ~/luckfox/logs/$name.log"
    ;;
run)
    docker exec -w "$SDK" "$NAME" bash -c "$*"
    ;;
status)
    log=$HOST_DIR/logs/$1.log
    tail -n 5 "$log"
    if grep -q '^EXIT=' "$log"; then echo "[finished]"; else echo "[running]"; fi
    ;;
fixperms)
    docker exec "$NAME" chown -R "$HOST_UID:$HOST_GID" /luckfox
    ;;
*)
    sed -n '2,25p' "$0"
    exit 1
    ;;
esac
