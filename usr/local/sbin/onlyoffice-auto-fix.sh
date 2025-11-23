#!/bin/bash

LOCK="/tmp/onlyoffice-check.lock"
LOG="/var/log/onlyoffice-auto-fix.log"

if [ -f "$LOCK" ]; then
    echo "$(date '+%F %T') : lock present, skipping" >> "$LOG"
    exit 0
fi

touch "$LOCK"

{
    echo " "
    echo "===== $(date '+%F %T') : Running OnlyOffice check ====="

    docker exec nextcloud-aio-nextcloud \
        sudo -E -u www-data php occ onlyoffice:documentserver --check

    STATUS=$?

    if [ $STATUS -eq 0 ]; then
        echo "$(date '+%F %T') : OK ✓"
    else
        echo "$(date '+%F %T') : ERROR – DocumentServer not ready ❌"
    fi

} >> "$LOG" 2>&1

rm -f "$LOCK"
