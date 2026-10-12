#!/bin/sh
# ESP-Hosted Wi-Fi service for the Luckfox Pico Max (ESP32-C6 SuperMini over SDIO, header pins 21-27).
# Installed to /userdata/esp-hosted/esp-hosted.sh and started at boot by /etc/init.d/S45esp-hosted.
#
#   esp-hosted.sh start     bring Wi-Fi up (in the background) and keep a watchdog running
#   esp-hosted.sh stop      stop wpa_supplicant and unload esp32_sdio (the C6 restarts, so the next boot is clean)
#   esp-hosted.sh restart
#   esp-hosted.sh status
#
# Files in /userdata/esp-hosted/: esp32_sdio.ko, wpa_supplicant.conf (WPA hash only), esp-hosted.log
# DHCP is done by the stock dhcpcd (manager mode, all interfaces). NTP by the stock S49ntp.

DIR=/userdata/esp-hosted
KO=/oem/usr/ko
CONF=$DIR/wpa_supplicant.conf
LOG=$DIR/esp-hosted.log
HOST=ff9a0000.mmc
DRV=/sys/bus/platform/drivers/dwmmc_rockchip
WATCHDOG_PID=/var/run/esp-hosted-watchdog.pid
CHECK_EVERY=10          # seconds between watchdog checks
# SDIO bus clock in whole MHz (driver parameter "clockspeed"; the Device Tree allows up to 10).
# If CRC errors (-84) show up while the radio is busy, check the wiring first: on 2026-10-12 SDIO
# wires routed near the C6's antenna made Wi-Fi drop every 20-60 s even at 2 MHz; moving them away
# fixed it at 10 MHz. A lower clock (e.g. 2 = ~7 Mbit/s raw) is only a stopgap.
SDIO_MHZ=10

log() {
    echo "$(date '+%F %T') $*" >> "$LOG"
    echo "esp-hosted: $*"
}

# keep the log small (it lives on flash)
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 262144 ] && mv -f "$LOG" "$LOG.1"

iface()        { ls /sys/class/net 2>/dev/null | grep -m1 '^wlan'; }
sdio_present() { grep -q 'SDIO_ID=0092:6666' /sys/bus/sdio/devices/*/uevent 2>/dev/null; }
rescan_sdio()  { echo $HOST > $DRV/unbind 2>/dev/null; sleep 1; echo $HOST > $DRV/bind 2>/dev/null; sleep 2; }

apply_sysctls() {
    # eth0 and wlan0 can sit on the same subnet: only answer ARP for an address on the interface that owns it
    echo 1 > /proc/sys/net/ipv4/conf/all/arp_ignore
    echo 2 > /proc/sys/net/ipv4/conf/all/arp_announce
}

load_modules() {
    for m in cfg80211 libaes ecc ecdh_generic bluetooth; do
        grep -q "^$m " /proc/modules || insmod $KO/$m.ko || return 1
    done
    grep -q '^esp32_sdio ' /proc/modules || insmod $DIR/esp32_sdio.ko radio_service=none clockspeed=$SDIO_MHZ
}

BASELINE=/var/run/esp-hosted.loaded-at
# kernel timestamp (s since boot) of the newest "recover failed" line, 0 if none
last_recover_failure() {
    dmesg | sed -n 's/^\[ *\([0-9]*\)\.[0-9]*\] .*Transport recovery: recover failed.*/\1/p' | tail -1 | grep . || echo 0
}
mark_transport_ok() { cut -d. -f1 /proc/uptime > $BASELINE; }
transport_dead() {
    # a "recover failed" line newer than the last driver (re)load = the driver is stuck in its recovery
    # loop after an SDIO error it couldn't fix (it retries every 5 s, so the line stays fresh).
    # Compare timestamps, not counts: the dmesg ring is small and old lines rotate out.
    [ "$(last_recover_failure)" -gt "$(cat $BASELINE 2> /dev/null || echo 0)" ]
}

start_supplicant() {
    IF=$(iface)
    [ -n "$IF" ] || return 1
    ip link set "$IF" up
    if ! pidof wpa_supplicant > /dev/null; then
        # Buildroot's 2.10 in /usr/sbin (/usr/bin/wpa_supplicant is Rockchip's old 2.6).
        # This build has no syslog (-s) support: log to RAM (/var) instead.
        /usr/sbin/wpa_supplicant -B -t -f /var/log/wpa_supplicant-$IF.log -D nl80211 -i "$IF" \
            -c "$CONF" -P /var/run/wpa_supplicant-$IF.pid
        sleep 1
    fi
    pidof wpa_supplicant > /dev/null
}

bring_up() {
    apply_sysctls
    for attempt in 1 2 3 4 5; do
        # Unloading esp32_sdio (stop/restart/recovery) makes the C6 restart its firmware, so a card
        # Linux still remembers is stale: always re-detect it before loading the driver.
        grep -q '^esp32_sdio ' /proc/modules || { sleep 1; rescan_sdio; }
        if ! sdio_present; then
            log "attempt $attempt: no ESP32-C6 on SDIO (is it powered and wired?)"
            sleep 5; continue
        fi
        grep -q '^esp32_sdio ' /proc/modules || mark_transport_ok
        load_modules
        i=0; while [ -z "$(iface)" ] && [ $i -lt 15 ]; do sleep 1; i=$((i+1)); done
        if [ -n "$(iface)" ] && ! transport_dead; then
            start_supplicant && { log "up on $(iface) (attempt $attempt)"; return 0; }
        fi
        log "attempt $attempt failed, reloading driver"
        bring_down quiet
        sleep 2; rescan_sdio
    done
    log "giving up for now, the watchdog will retry"
    return 1
}

bring_down() {
    killall wpa_supplicant 2> /dev/null
    rmmod esp32_sdio 2> /dev/null      # sends CLOSE_DATA_PATH: the C6 restarts its firmware
    [ "$1" = quiet ] || log "down"
}

watchdog() {
    while sleep $CHECK_EVERY; do
        IF=$(iface)
        if [ -z "$IF" ] || transport_dead; then
            log "watchdog: interface missing or transport dead, recovering"
            bring_down quiet; sleep 2; rescan_sdio; bring_up
        elif ! pidof wpa_supplicant > /dev/null; then
            log "watchdog: wpa_supplicant not running, restarting it"
            start_supplicant
        fi
    done
}

case "$1" in
start)
    bring_up
    if [ ! -f $WATCHDOG_PID ] || ! kill -0 "$(cat $WATCHDOG_PID)" 2> /dev/null; then
        watchdog < /dev/null > /dev/null 2>&1 &
        echo $! > $WATCHDOG_PID
    fi
    ;;
stop)
    [ -f $WATCHDOG_PID ] && kill "$(cat $WATCHDOG_PID)" 2> /dev/null
    rm -f $WATCHDOG_PID
    bring_down
    ;;
restart)
    "$0" stop; sleep 2; "$0" start
    ;;
status)
    IF=$(iface)
    echo "sdio: $(sdio_present && echo 'ESP32-C6 present' || echo 'none')"
    echo "driver: $(grep -q '^esp32_sdio ' /proc/modules && echo "loaded, clockspeed=$(cat /sys/module/esp32_sdio/parameters/clockspeed) MHz" || echo 'not loaded')"
    echo "interface: ${IF:-none}"
    [ -n "$IF" ] && /usr/sbin/wpa_cli -i "$IF" status 2> /dev/null | grep -E '^(wpa_state|ssid|ip_address)='
    [ -n "$IF" ] && iw dev "$IF" link | grep -E 'signal'
    echo "watchdog: $([ -f $WATCHDOG_PID ] && kill -0 "$(cat $WATCHDOG_PID)" 2> /dev/null && echo running || echo stopped)"
    ;;
*)
    echo "usage: $0 start|stop|restart|status"
    exit 1
    ;;
esac
