#!/bin/sh
# ==============================================================
#  File: /root/scripts/ids_monitor_v4.8.sh
#  Desc: IDS log monitor para OpenWRT - Correção de falsos ONLINE
# ==============================================================

DEBUG=false
INTERVAL=15
EXPIRE_DAYS=120
DEBOUNCE_SEC=2

# Parâmetros de confirmação Wi-Fi
WIFI_ASSOC_CONFIRM_MAX=6        # segundos máximos para confirmar associação real
WIFI_ASSOC_CHECK_INTERVAL=1     # intervalo entre verificações
MIN_VALID_ONLINE_SEC=3          # se desconectar antes disso sem IP -> ignora
DHCP_WAIT_MAX=10
DHCP_POLL_INTERVAL=1

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0" .sh)"

WHATSAPP_SCRIPT="$DIR/send_whatsapp.sh"
DB_PATH="$DIR/${SCRIPT_NAME}.db"
DB_LOCK_F="$DB_PATH.lock"
LOG_FILE="$DIR/${SCRIPT_NAME}.log"
EVENT_CACHE="/tmp/ids_eventcache"
PENDING_DIR="/tmp/ids_pending_wifi"

STATIC_MACS=""

[ -d "$PENDING_DIR" ] || mkdir -p "$PENDING_DIR"

debug_log() { $DEBUG && echo "[DEBUG] $*" | tee -a "$LOG_FILE"; }

sqlite3_safe() {
  flock -x "$DB_LOCK_F" -c "sqlite3 \"$DB_PATH\" \"$1\""
}

sql_quote() { printf "%s" "$1" | sed "s/'/''/g"; }

check_liveliness() {
  local mac="$1" ip="$2" iface="$3"
  ip neigh | grep -i "$mac" | grep -qw "REACHABLE" && return 0
  if ! echo "$iface" | grep -q '^wlan'; then
    [ "$1" != "" ] && [ "$2" != "" ] && arping -I br-lan -c 1 "$ip" >/dev/null 2>&1 && return 0
  fi
  ping -c 1 -W 1 "$ip" >/dev/null 2>&1 && return 0
  return 1
}

get_iface() {
    local mac="$1" ip="$2" iface
    iface=$(for w in $(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}'); do
               iw dev "$w" station dump | grep -qi "$mac" && { echo "$w"; break; }
           done)
    [ -n "$iface" ] && { echo "$iface"; return; }
    iface=$(ip neigh show "$ip" 2>/dev/null | awk '$3!="br-lan"{print $3; exit}')
    [ -n "$iface" ] && { echo "$iface"; return; }
    if command -v bridge >/dev/null; then
        iface=$(bridge fdb show | awk -v mac="$(echo "$mac" | tr A-Z a-z)" \
               '$1==mac && $4=="master"{print $3; exit}')
        [ -n "$iface" ] && { echo "$iface"; return; }
    fi
    iface=$(ip neigh show "$ip" 2>/dev/null | awk '{print $3; exit}')
    echo "${iface:-unknown}"
}

ensure_iface() {
    local ifname="$1"
    sqlite3_safe "INSERT OR IGNORE INTO interfaces(name) VALUES('$(sql_quote "$ifname")')"
    iface_id=$(sqlite3_safe "SELECT id FROM interfaces WHERE name='$(sql_quote "$ifname")'")
    [ -z "$iface_id" ] && { debug_log "ERRO: interface_id vazio para $ifname"; return 1; }
    echo "$iface_id"
}

send_notification() {
    local change_type="$1" mac="$2" ip="$3" host="$4" iface="$5" status="$6" change_time="$7" extra="$8"
    local status_word
    [ "$status" -eq 1 ] && status_word="online" || status_word="offline"
    local msg="🚨 Alteração detectada ($change_type)!
Data/Hora: $change_time
Interface: $iface
MAC: $mac
IP:  $ip
Nome: $host
Status: $status_word"
    [ -n "$extra" ] && msg="$msg
$extra"

    echo "$msg" >> "$LOG_FILE"
    echo "[$change_time] $change_type $host ($mac) via $iface"
    "$WHATSAPP_SCRIPT" "$msg"
}

initialize_db() {
sqlite3_safe "PRAGMA foreign_keys = ON"
sqlite3_safe "PRAGMA journal_mode = WAL"
sqlite3_safe "CREATE TABLE IF NOT EXISTS interfaces (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE)"
sqlite3_safe "CREATE TABLE IF NOT EXISTS devices (mac TEXT PRIMARY KEY, name TEXT, description TEXT) WITHOUT ROWID"
sqlite3_safe "CREATE TABLE IF NOT EXISTS current_status (
    mac TEXT PRIMARY KEY REFERENCES devices(mac) ON DELETE CASCADE,
    interface_id INTEGER REFERENCES interfaces(id),
    ip TEXT, hostname TEXT, status INTEGER NOT NULL,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
)"
sqlite3_safe "CREATE TABLE IF NOT EXISTS status_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    mac TEXT, interface_id INTEGER, ip TEXT, hostname TEXT,
    status INTEGER NOT NULL, ts DATETIME DEFAULT CURRENT_TIMESTAMP,
    event_type TEXT DEFAULT 'status')"
sqlite3_safe "CREATE INDEX IF NOT EXISTS idx_status_logs_mac_ts ON status_logs(mac, ts DESC)"
sqlite3_safe "CREATE INDEX IF NOT EXISTS idx_current_status_status ON current_status(status)"
}

get_human_duration() {
    local total_secs=$1
    [ -z "$total_secs" ] || [ "$total_secs" -lt 0 ] && total_secs=0
    local hours=$((total_secs / 3600))
    local mins=$(( (total_secs % 3600) / 60 ))
    local secs=$((total_secs % 60))
    printf "%02dh:%02dm:%02ds" $hours $mins $secs
}

calculate_duration_log() {
    local mac="$1" new_status="$2" change_time="$3"
    local last_ts="" last_epoch=0 now_epoch=0 total_secs=0 label=""
    
    now_epoch=$(date -d "$change_time" +%s 2>/dev/null)
    [ -z "$now_epoch" ] && now_epoch=$(date +%s)

    if [ "$new_status" -eq 0 ]; then
        last_ts=$(sqlite3_safe "SELECT ts FROM status_logs WHERE mac='$mac' AND status=1 ORDER BY ts DESC LIMIT 1")
        label="Tempo ON"
    elif [ "$new_status" -eq 1 ]; then
        last_ts=$(sqlite3_safe "SELECT ts FROM status_logs WHERE mac='$mac' AND status=0 ORDER BY ts DESC LIMIT 1")
        label="Tempo OFFLINE"
    fi

    [ -z "$last_ts" ] && return

    last_epoch=$(date -d "$last_ts" +%s 2>/dev/null)
    [ -z "$last_epoch" ] && return

    total_secs=$((now_epoch - last_epoch))
    
    echo "$label: $(get_human_duration $total_secs)"
}

get_device_info() {
    local mac="$1"
    local ip="" host=""
    
    local dhcp_info
    dhcp_info=$(awk -v m="$mac" '$2==m {print $3"|"$4}' /tmp/dhcp.leases | head -1)
    
    if [ -n "$dhcp_info" ]; then
        ip=$(echo "$dhcp_info" | cut -d'|' -f1)
        host=$(echo "$dhcp_info" | cut -d'|' -f2)
    fi
    
    if [ -z "$ip" ]; then
        ip=$(ip neigh | grep -i "$mac" | awk '{print $1; exit}')
    fi
    
    if [ -z "$host" ] || [ "$host" = "*" ]; then
        local db_host
        db_host=$(sqlite3_safe "SELECT hostname FROM status_logs WHERE mac='$mac' AND hostname IS NOT NULL AND hostname != '' AND hostname != '*' ORDER BY ts DESC LIMIT 1")
        [ -n "$db_host" ] && host="$db_host"
    fi
    
    [ -z "$host" ] && host="*"
    
    echo "$ip|$host"
}

wait_for_dhcp() {
    local mac="$1"
    local elapsed=0
    while [ $elapsed -lt $DHCP_WAIT_MAX ]; do
        local info
        info=$(get_device_info "$mac")
        local ip host
        ip=$(echo "$info" | cut -d'|' -f1)
        host=$(echo "$info" | cut -d'|' -f2)
        if [ -n "$ip" ]; then
            echo "$ip|$host"
            return 0
        fi
        sleep $DHCP_POLL_INTERVAL
        elapsed=$((elapsed + DHCP_POLL_INTERVAL))
    done
    echo "NOIP|*"
    return 1
}

is_currently_online() {
    local mac="$1"
    local st
    st=$(sqlite3_safe "SELECT status FROM current_status WHERE mac='$mac'")
    [ "$st" = "1" ]
}

mark_pending() {
    local mac="$1" iface="$2"
    date +%s > "$PENDING_DIR/$mac"
    echo "$iface" > "$PENDING_DIR/${mac}.iface"
}

clear_pending() {
    local mac="$1"
    rm -f "$PENDING_DIR/$mac" "$PENDING_DIR/${mac}.iface"
}

pending_age() {
    local mac="$1"
    [ -f "$PENDING_DIR/$mac" ] || { echo 0; return; }
    local start now
    start=$(cat "$PENDING_DIR/$mac")
    now=$(date +%s)
    echo $((now-start))
}

confirm_wifi_association() {
    local mac="$1" iface="$2"
    local waited=0
    while [ $waited -lt $WIFI_ASSOC_CONFIRM_MAX ]; do
        # DHCP ou ARP
        local info ip host
        info=$(get_device_info "$mac")
        ip=$(echo "$info" | cut -d'|' -f1)
        host=$(echo "$info" | cut -d'|' -f2)
        if [ -n "$ip" ]; then
            echo "$ip|$host"
            return 0
        fi
        # Station dump confirma associação?
        iw dev "$iface" station get "$mac" >/dev/null 2>&1 && {
            # Ainda sem IP, mas está realmente associado. Retornamos ip vazio porém confirmamos.
            echo "|$host"
            return 0
        }
        sleep $WIFI_ASSOC_CHECK_INTERVAL
        waited=$((waited + WIFI_ASSOC_CHECK_INTERVAL))
    done
    return 1
}

upsert_current_status() {
    local mac="$1" status="$2" ip="$3" host="$4" iface_name="$5" change_type="$6"
    local change_time; change_time=$(date "+%Y-%m-%d %H:%M:%S")

    # Proteção: se status=1 (online) e ip vazio e nada em ARP → ignorar (não confirma)
    if [ "$status" -eq 1 ]; then
        if [ -z "$ip" ]; then
            local arp_ip
            arp_ip=$(ip neigh | grep -i "$mac" | awk '{print $1; exit}')
            if [ -z "$arp_ip" ]; then
                debug_log "IGNORANDO ONLINE sem IP/ARP confirmado para $mac ($change_type)"
                return
            fi
            [ -z "$ip" ] && ip="$arp_ip"
        fi
    fi
    
    if [ -z "$ip" ] || [ -z "$host" ] || [ "$host" = "*" ]; then
        local info
        info=$(get_device_info "$mac")
        local new_ip new_host
        new_ip=$(echo "$info" | cut -d'|' -f1)
        new_host=$(echo "$info" | cut -d'|' -f2)
        [ -n "$new_ip" ] && ip="$new_ip"
        [ -n "$new_host" ] && [ "$new_host" != "*" ] && host="$new_host"
    fi

    local host_q; host_q=$(sql_quote "$host")
    sqlite3_safe "INSERT INTO devices(mac,name) VALUES('$mac','$host_q')
                  ON CONFLICT(mac) DO UPDATE SET name=excluded.name"

    local iface_id; iface_id=$(ensure_iface "$iface_name")
    [ -z "$iface_id" ] && return

    local ip_q; ip_q=$(sql_quote "$ip")
    local prev
    prev=$(sqlite3_safe "SELECT status,ip,hostname FROM current_status WHERE mac='$mac'")
    local changed=0 extra=""
    if [ -z "$prev" ]; then
        changed=1
        [ -z "$change_type" ] && change_type="novo"
    else
        IFS='|' read prev_status prev_ip prev_host <<EOF
$prev
EOF
        [ "$prev_status" != "$status" ] && changed=1
        if $DEBUG; then
          [ "$prev_ip" != "$ip" ] && [ -n "$ip" ] && { changed=1; change_type="ip_change"; extra="IP antigo: $prev_ip"; }
          [ "$prev_host" != "$host" ] && [ "$host" != "*" ] && { changed=1; change_type="host_change"; extra="Hostname antigo: $prev_host"; }
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        sqlite3_safe "INSERT INTO current_status (mac, interface_id, ip, hostname, status, updated_at)
           VALUES ('$mac', $iface_id, '$ip_q', '$host_q', $status, '$change_time')
           ON CONFLICT(mac) DO UPDATE SET
                interface_id=$iface_id,
                ip='$ip_q',
                hostname='$host_q',
                status=$status,
                updated_at=CURRENT_TIMESTAMP"
        sqlite3_safe "INSERT INTO status_logs (mac, interface_id, ip, hostname, status, ts, event_type)
           VALUES ('$mac', $iface_id, '$ip_q', '$host_q', $status, '$change_time', '$change_type')"

        local duration_log
        duration_log=$(calculate_duration_log "$mac" "$status" "$change_time")
        
        if [ -n "$duration_log" ]; then
            if [ -n "$extra" ]; then
                extra="$extra
$duration_log"
            else
                extra="$duration_log"
            fi
        fi

        send_notification "$change_type" "$mac" "$ip" "$host" "$iface_name" "$status" "$change_time" "$extra"
    fi
}

clean_old_logs() {
    sqlite3_safe "DELETE FROM status_logs WHERE ts < DATE('now','-${EXPIRE_DAYS} days')"
}

need_schema() {
    sqlite3_safe "SELECT 1 FROM sqlite_master WHERE type='table' AND name='current_status'" | grep -q 1 || return 0
    return 1
}

debounce_event() {
    local mac="$1"
    local now day
    now=$(date +%s)
    day=$(date +%Y-%m-%d)
    local last last_day
    last=$(grep "^$mac " "$EVENT_CACHE" 2>/dev/null | awk '{print $2}')
    last_day=$(grep "^$mac " "$EVENT_CACHE" 2>/dev/null | awk '{print $3}')
    grep -v " $day\$" "$EVENT_CACHE" 2>/dev/null > "${EVENT_CACHE}.tmp" && mv "${EVENT_CACHE}.tmp" "$EVENT_CACHE"
    if [ -n "$last" ] && [ $((now-last)) -lt $DEBOUNCE_SEC ] && [ "$last_day" = "$day" ]; then
      return 1
    fi
    sed -i "/^$mac /d" "$EVENT_CACHE" 2>/dev/null
    echo "$mac $now $day" >> "$EVENT_CACHE"
    return 0
}

robust_wifi_watcher() {
  # IMPORTANTE: um único logread -f contínuo
  logread -f 2>/dev/null | grep -E 'AP-STA-(CONNECTED|DISCONNECTED)' | while read -r line; do
      debug_log "RAW_WIFI: $line"
      mac=$(echo "$line" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')
      iface=$(echo "$line" | grep -oE 'wlan[0-9](-[0-9])?')
      [ -z "$mac" ] && continue
      debounce_event "$mac" || continue
      
      if echo "$line" | grep -q 'AP-STA-DISCONNECTED'; then
        # Só registra offline se estava realmente online
        is_currently_online "$mac" || { debug_log "Ignorando DISCONNECTED de $mac (não estava online)"; clear_pending "$mac"; continue; }
        # Verifica se era uma associação pendente curta sem IP válido
        local age
        age=$(pending_age "$mac")
        if [ "$age" -gt 0 ] && [ "$age" -lt "$MIN_VALID_ONLINE_SEC" ]; then
            debug_log "Desconexão rápida ignorada (pendente < ${MIN_VALID_ONLINE_SEC}s) para $mac"
            clear_pending "$mac"
            continue
        fi
        # Recupera dados do banco
        IFS='|' read ip host iface_name <<EOF
$(sqlite3_safe "SELECT COALESCE(ip,'') ||'|'|| COALESCE(hostname,'*') ||'|'|| COALESCE((SELECT name FROM interfaces WHERE id=interface_id),'unknown') FROM current_status WHERE mac='$mac'")
EOF
        upsert_current_status "$mac" 0 "$ip" "$host" "${iface:-$iface_name}" "wifi_disconnected"
        clear_pending "$mac"
        
      elif echo "$line" | grep -q 'AP-STA-CONNECTED'; then
        mark_pending "$mac" "$iface"
        # Primeiro tenta confirmação (IP ou associação estável)
        if confirm_wifi_association "$mac" "$iface"; then
            local info ip host
            info=$(wait_for_dhcp "$mac")  # tenta melhorar IP/host
            ip=$(echo "$info" | cut -d'|' -f1)
            host=$(echo "$info" | cut -d'|' -f2)
            [ "$ip" = "NOIP" ] && ip=""
            upsert_current_status "$mac" 1 "$ip" "$host" "$iface" "wifi_connected"
        else
            debug_log "Assoc. transitória descartada para $mac (sem IP/estação estável)"
            clear_pending "$mac"
        fi
      fi
  done
}

monitor_loop() {
    [ ! -f "$DB_PATH" ] || need_schema && { debug_log "🔧 (Re)criando schema…"; initialize_db; }
    > "$EVENT_CACHE"

    CYCLE=0

    while :; do
        debug_log "🔍 Varredura DHCP e estáticos…"
        awk '{print $2,$3,$4}' /tmp/dhcp.leases | while read -r mac ip host; do
            iface_name=$(get_iface "$mac" "$ip")
            if echo "$iface_name" | grep -q '^wlan'; then
                iw dev "$iface_name" station get "$mac" >/dev/null 2>&1 || continue
            fi
            check_liveliness "$mac" "$ip" "$iface_name" && upsert_current_status "$mac" 1 "$ip" "$host" "$iface_name" "online"
        done

        CYCLE=$(( (CYCLE + 1) % 3 ))
        for mac in $STATIC_MACS; do
            ip=$(ip neigh | awk -v m="$(echo $mac | tr A-Z a-z)" '$1==m{print $2; exit}')
            [ -z "$ip" ] && continue
            iface_name=$(get_iface "$mac" "$ip")
            host="(static)"
            if echo "$iface_name" | grep -q '^wlan'; then
                iw dev "$iface_name" station get "$mac" >/dev/null 2>&1 || continue
            fi
            if ! echo "$iface_name" | grep -q '^wlan' && [ "$CYCLE" -eq 0 ]; then
                check_liveliness "$mac" "$ip" "$iface_name" && upsert_current_status "$mac" 1 "$ip" "$host" "$iface_name" "online"
            fi
        done

        for mac in $(sqlite3_safe "SELECT mac FROM current_status WHERE status=1"); do
            IFS='|' read ip host iface_name <<EOF
$(sqlite3_safe "SELECT COALESCE(ip,'') ||'|'|| COALESCE(hostname,'*') ||'|'|| COALESCE((SELECT name FROM interfaces WHERE id=interface_id),'unknown') FROM current_status WHERE mac='$mac'")
EOF
            if echo "$iface_name" | grep -q '^wlan'; then
                iw dev "$iface_name" station get "$mac" >/dev/null 2>&1 && continue
            fi
            check_liveliness "$mac" "$ip" "$iface_name" || upsert_current_status "$mac" 0 "$ip" "$host" "$iface_name" "offline"
        done

        clean_old_logs
        debug_log "✅ Dormindo ${INTERVAL}s"
        sleep "$INTERVAL"
    done
}

trap "rm -f \"$EVENT_CACHE\"; rm -rf \"$PENDING_DIR\"" EXIT

echo "🚀 IDS monitor V4.8 iniciado (intervalo ${INTERVAL}s)" | tee -a "$LOG_FILE"
robust_wifi_watcher &
monitor_loop