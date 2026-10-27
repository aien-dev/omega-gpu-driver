#!/bin/sh
# window/d2-boot.sh -- run once per boot by aien-owndriver-window.service. Status: NOT_RUN.
#   state "run D2" / "run D3": the reboot from W1 has happened; run window/d2-run.sh --go STAGE.
#   state "restore":           the reboot from W7 (or a fallback) has happened; run window/d2-restore.sh --go.
#   no state:                  nothing pending: remove the unit (a leftover unit must never act twice).
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$R/window/common.sh"
LOG=$LOGDIR/d2-$(date -u +%Y%m%dT%H%M%SZ)-boot.log
s=$(cat "$STATE" 2>/dev/null || true)
log "boot unit: state '$s'"
case $s in
"run D2" | "run D3") exec sh "$R/window/d2-run.sh" --go "${s#run }" ;;
restore) exec sh "$R/window/d2-restore.sh" --go ;;
*)
	sudo -n systemctl disable aien-owndriver-window.service >/dev/null 2>&1 || true
	sudo -n rm -f "$UNIT"
	sudo -n systemctl daemon-reload
	log "no pending step: unit removed"
	;;
esac
