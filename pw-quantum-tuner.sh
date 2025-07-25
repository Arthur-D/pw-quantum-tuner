#!/usr/bin/env bash

base_backoff=1
check_interval=1

# Minimum time in seconds between quantum increases
min_increase_cooldown=10

log_level=1
for arg in "$@"; do
    case "$arg" in
        --log-level)
            shift
            log_level="$1"
            shift
            ;;
        --log-level=*)
            log_level="${arg#*=}"
            shift
            ;;
    esac
done

log() {
    local lvl=$1; shift
    if (( log_level >= lvl )); then
        echo "$@"
    fi
}

get_pipewire_conf_value() {
    local key="$1"
    local val=""
    for conf in /etc/pipewire/pipewire.conf ~/.config/pipewire/pipewire.conf; do
        if [[ -f "$conf" ]]; then
            v=$(grep -E "^\s*${key}\s*=" "$conf" | tail -n1 | sed -E "s/^\s*${key}\s*=\s*([0-9]+).*/\1/")
            [[ -n "$v" ]] && val="$v"
        fi
    done
    echo "$val"
}

read_metadata_value() {
    /usr/bin/pw-metadata -n settings | grep "key:'$1'" | head -n1 | sed -n "s/.*value:'\([0-9]\+\)'.*/\1/p"
}

get_pwtop_quantum() {
    pw-top -bn 2 2>/dev/null | awk '$1 == "R" && $3 ~ /^[0-9]+$/ && $3 > 0 {print $3; exit}'
}

min_quantum=$(read_metadata_value clock.min-quantum)
max_quantum=$(read_metadata_value clock.max-quantum)
[[ -z "$min_quantum" ]] && min_quantum=$(get_pipewire_conf_value "default.clock.min-quantum")
[[ -z "$max_quantum" ]] && max_quantum=$(get_pipewire_conf_value "default.clock.max-quantum")
[[ -z "$min_quantum" || "$min_quantum" -le 0 ]] && min_quantum=128
[[ -z "$max_quantum" || "$max_quantum" -le 0 ]] && max_quantum=8192

force_quantum=$(read_metadata_value clock.force-quantum)
pwtop_quantum=$(get_pwtop_quantum)
if [[ -n "$pwtop_quantum" && "$pwtop_quantum" -gt 0 ]]; then
    quantum=$pwtop_quantum
elif [[ -n "$force_quantum" && "$force_quantum" -gt 0 ]]; then
    quantum=$force_quantum
else
    quantum=$min_quantum
fi
last_set_quantum=$quantum

declare -A prev_errs curr_errs client_pretty_names client_quants client_roles
declare -A quantum_backoff
default_backoff=1

last_decrease_or_increase_time=0
last_err_increase_time=0
last_increase_time=0

if (( log_level >= 1 )); then
    echo "Starting PipeWire quantum tuner at log level $log_level (quant=$quantum, min=$min_quantum, max=$max_quantum)"
fi

declare -A pwtop_col_idx

find_pwtop_columns() {
    local header="$1"
    local idx=1
    for col in $header; do
        col_lc=$(echo "$col" | tr '[:upper:]' '[:lower:]')
        case "$col_lc" in
            id)     pwtop_col_idx["id"]=$idx ;;
            quant)  pwtop_col_idx["quant"]=$idx ;;
            err)    pwtop_col_idx["err"]=$idx ;;
            name)   pwtop_col_idx["name"]=$idx ;;
            *)      ;;
        esac
        idx=$((idx+1))
    done
}

parse_client() {
    local line="$1"
    [[ "$line" =~ ^[[:space:]]*$ ]] && return 1
    [[ "$line" =~ ^\ *[A-Z]\ +ID\ +QUANT ]] && return 1
    [[ "$line" =~ ^\ *[-]+ ]] && return 1
    local role
    role=$(awk '{print $1}' <<< "$line")
    [[ -z "$role" ]] && return 1
    local id quant err name
    id=$(awk -v idx="${pwtop_col_idx["id"]}" '{print $idx}' <<< "$line")
    quant=$(awk -v idx="${pwtop_col_idx["quant"]}" '{print $idx}' <<< "$line")
    err=$(awk -v idx="${pwtop_col_idx["err"]}" '{print $idx}' <<< "$line")
    name=$(awk -v idx="${pwtop_col_idx["name"]}" '{for(i=idx;i<=NF;++i) {printf "%s ", $i}; print ""}' <<< "$line" | sed 's/ *$//')
    [[ -z "$id" || -z "$quant" || -z "$err" ]] && return 1
    key="$id"
    log 3 "Parsed client: key=$key, name=$name, err=$err, quant=$quant, role=$role, line='$line'"
    printf "%s\n%s\n%s\n%s\n%s\n" "$key" "$name" "$err" "$quant" "$role"
    return 0
}

clamp() {
    local val="$1"
    local min="$2"
    local max="$3"
    (( val < min )) && val=$min
    (( val > max )) && val=$max
    echo "$val"
}

clients_with_new_errs=()
seen_this_frame=()

process_frame() {
    local quantum_increased=0
    local increased_clients=()

    # Initialize prev_errs for new clients
    for key in "${!curr_errs[@]}"; do
        local curr_val=${curr_errs[$key]:-0}
        if [[ -z "${prev_errs[$key]+set}" ]]; then
            prev_errs[$key]=$curr_val
        fi
    done

    # Detect new ERRs
    for key in "${!curr_errs[@]}"; do
        local curr_val=${curr_errs[$key]:-0}
        local prev_val=${prev_errs[$key]:-0}
        if (( curr_val > prev_val )); then
            clients_with_new_errs+=("$key")
            increased_clients+=("$key")
        fi
    done

    # Only allow quantum increase if cooldown has elapsed
    now=$(date +%s)
    seconds_since_increase=$(( now - last_increase_time ))

    if (( ${#clients_with_new_errs[@]} > 0 )) && (( seconds_since_increase >= min_increase_cooldown )); then
        next_quantum=$((quantum * 2))
        next_quantum=$(clamp "$next_quantum" "$min_quantum" "$max_quantum")
        if (( next_quantum > quantum )); then
            # Backoff handling
            if [[ -z "${quantum_backoff[$quantum]+set}" ]]; then
                quantum_backoff[$quantum]=$default_backoff
            fi
            if [[ -z "${quantum_backoff[$next_quantum]+set}" ]]; then
                quantum_backoff[$next_quantum]=${quantum_backoff[$quantum]}
            fi
            quantum_backoff[$next_quantum]=$(( quantum_backoff[$next_quantum] * 2 ))
            # Log
            deltas=()
            for key in "${increased_clients[@]}"; do
                delta=$((curr_errs[$key] - prev_errs[$key]))
                name="${client_pretty_names[$key]}"
                deltas+=("  $name ($delta new ERRs, total ${curr_errs[$key]} ERRs)")
            done
            total_delta=0
            for key in "${increased_clients[@]}"; do
                total_delta=$((total_delta + curr_errs[$key] - prev_errs[$key]))
            done
            msg="↑ Increasing quantum from $quantum to $next_quantum due to $total_delta new ERRs (next decrease in ${quantum_backoff[$next_quantum]} min)"
            log 1 "$msg"
            if (( log_level >= 2 )); then
                for line in "${deltas[@]}"; do log 2 "$line"; done
            fi
            /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$next_quantum" >/dev/null 2>&1
            last_set_quantum=$next_quantum
            quantum=$next_quantum
            last_decrease_or_increase_time=$now
            last_err_increase_time=$now
            last_increase_time=$now
        fi
    fi

    # Quantum decrease (as before)
    if [[ -z "${quantum_backoff[$quantum]+set}" ]]; then
        quantum_backoff[$quantum]=$default_backoff
    fi
    current_backoff=${quantum_backoff[$quantum]}
    seconds_since_for_decrease=$(( now - last_err_increase_time ))
    loadavg=$(awk '{print $1}' /proc/loadavg)
    if (( current_backoff > 1 )) && awk "BEGIN {exit !($loadavg < 1.0)}"; then
        old_backoff=$current_backoff
        current_backoff=$((old_backoff / 2))
        (( current_backoff < 1 )) && current_backoff=1
        quantum_backoff[$quantum]=$current_backoff
        log 1 "↳ System load is low ($loadavg), halving decrease backoff: $old_backoff → $current_backoff min"
    fi
    if (( quantum > min_quantum )); then
        if (( seconds_since_for_decrease >= current_backoff * 60 )); then
            next_quantum=$((quantum / 2))
            next_quantum=$(clamp "$next_quantum" "$min_quantum" "$max_quantum")
            if [[ -z "${quantum_backoff[$next_quantum]+set}" ]]; then
                quantum_backoff[$next_quantum]=$current_backoff
            fi
            next_backoff=$(( quantum_backoff[$next_quantum] / 2 ))
            (( next_backoff < 1 )) && next_backoff=1
            quantum_backoff[$next_quantum]=$next_backoff
            log 1 "↓ Decreasing quantum from $quantum to $next_quantum (next decrease in ${quantum_backoff[$next_quantum]} min)"
            /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$next_quantum" >/dev/null 2>&1
            last_set_quantum=$next_quantum
            quantum=$next_quantum
            last_decrease_or_increase_time=$now
            last_err_increase_time=$now
            # Reset last_increase_time so that if an error occurs immediately after decrease, increase is not blocked
            last_increase_time=0
        fi
    fi

    # Only update prev_errs for clients actually seen in this frame
    for key in "${!curr_errs[@]}"; do
        prev_errs[$key]=${curr_errs[$key]}
    done

    # Remove tracking info for vanished clients
    for gone_key in "${!prev_errs[@]}"; do
        if [[ -z "${curr_errs[$gone_key]+set}" ]]; then
            unset prev_errs[$gone_key]
        fi
    done

    # Clear for next frame
    clients_with_new_errs=()
    curr_errs=()
    client_pretty_names=()
    client_quants=()
    client_roles=()
}

header_found=0
pwtop_header=""
frame_started=0

pw-top -b | while read -r line; do
    # Detect new frame by header line
    if [[ "$line" =~ ID[[:space:]]+QUANT ]]; then
        if (( frame_started )); then
            process_frame
        fi
        find_pwtop_columns "$line"
        pwtop_header="$line"
        frame_started=1
        continue
    fi

    parsed=($(parse_client "$line"))
    [[ $? != 0 ]] && continue
    key="${parsed[0]}"
    name="${parsed[1]}"
    err="${parsed[2]}"
    quant_client="${parsed[3]}"
    role="${parsed[4]}"

    if [[ "$role" != "R" ]]; then
        continue
    fi

    curr_errs["$key"]=$err
    client_pretty_names["$key"]="$name"
    client_quants["$key"]=$quant_client
    client_roles["$key"]=$role
done

# process last frame if script is exiting
process_frame
