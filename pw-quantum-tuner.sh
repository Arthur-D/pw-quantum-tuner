#!/usr/bin/env bash

base_backoff=1
check_interval=1

# Minimum time in seconds between quantum increases
min_increase_cooldown=4

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

# Read current min-quantum from PipeWire metadata (this is what we'll be adjusting)
current_min_quantum=$(read_metadata_value clock.min-quantum)
pwtop_quantum=$(get_pwtop_quantum)
if [[ -n "$pwtop_quantum" && "$pwtop_quantum" -gt 0 ]]; then
    quantum=$pwtop_quantum
elif [[ -n "$current_min_quantum" && "$current_min_quantum" -gt 0 ]]; then
    quantum=$current_min_quantum
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
            id)             pwtop_col_idx["id"]=$idx ;;
            quant|quantum)  pwtop_col_idx["quant"]=$idx ;;
            err|error|errs) pwtop_col_idx["err"]=$idx ;;
            name)           pwtop_col_idx["name"]=$idx ;;
            *)              ;;
        esac
        idx=$((idx+1))
    done
    
    # Debug: log detected columns at startup
    if (( log_level >= 2 )); then
        log 2 "Column detection from header: $header"
        for col_name in id quant err name; do
            if [[ -n "${pwtop_col_idx[$col_name]}" ]]; then
                log 2 "  $col_name -> column ${pwtop_col_idx[$col_name]}"
            else
                log 2 "  $col_name -> NOT FOUND"
            fi
        done
    fi
}

parse_client() {
    local line="$1"
    [[ "$line" =~ ^[[:space:]]*$ ]] && return 1
    [[ "$line" =~ ^[[:space:]]*[A-Z][[:space:]]+ID[[:space:]]+(QUANT|QUANTUM) ]] && return 1
    [[ "$line" =~ ^[[:space:]]*[-]+ ]] && return 1
    local role
    role=$(awk '{print $1}' <<< "$line")
    [[ -z "$role" ]] && return 1
    # Skip lines that look like headers or separators
    [[ "$role" =~ ^(S|ID|QUANT|QUANTUM|RATE|WAIT|BUSY|ERR|FORMAT|NAME)$ ]] && return 1
    local id quant err name
    
    # Check if required column indices are available
    if [[ -z "${pwtop_col_idx["id"]}" || -z "${pwtop_col_idx["quant"]}" || -z "${pwtop_col_idx["err"]}" ]]; then
        log 3 "Skipping client line - missing column indices (id:${pwtop_col_idx["id"]}, quant:${pwtop_col_idx["quant"]}, err:${pwtop_col_idx["err"]})"
        return 1
    fi
    
    id=$(awk -v idx="${pwtop_col_idx["id"]}" '{print $idx}' <<< "$line")
    quant=$(awk -v idx="${pwtop_col_idx["quant"]}" '{print $idx}' <<< "$line")
    err=$(awk -v idx="${pwtop_col_idx["err"]}" '{print $idx}' <<< "$line")
    name=$(awk -v idx="${pwtop_col_idx["name"]}" '{for(i=idx;i<=NF;++i) {printf "%s ", $i}; print ""}' <<< "$line" | sed 's/ *$//')
    
    [[ -z "$id" || -z "$quant" || -z "$err" ]] && {
        log 3 "Skipping client line - empty required fields (id:'$id', quant:'$quant', err:'$err')"
        return 1
    }
    key="$id"
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
            log 3 "Initializing prev_errs for new client $key (${client_pretty_names[$key]:-unknown}): $curr_val"
        fi
    done

    # Detect new ERRs
    for key in "${!curr_errs[@]}"; do
        local curr_val=${curr_errs[$key]:-0}
        local prev_val=${prev_errs[$key]:-0}
        log 3 "Checking client $key (${client_pretty_names[$key]:-unknown}): curr=$curr_val, prev=$prev_val"
        if (( curr_val > prev_val )); then
            clients_with_new_errs+=("$key")
            increased_clients+=("$key")
            log 3 "  -> ERROR INCREASE DETECTED: $prev_val -> $curr_val"
        fi
    done

    # Only allow quantum increase if cooldown has elapsed
    now=$(date +%s)
    seconds_since_increase=$(( now - last_increase_time ))

    # Debug logging for quantum increase decision
    if (( ${#clients_with_new_errs[@]} > 0 )); then
        log 3 "New ERRs detected (${#clients_with_new_errs[@]} clients), evaluating quantum increase..."
        log 3 "  Current quantum: $quantum, would increase to: $((quantum * 2))"
        log 3 "  Seconds since last increase: $seconds_since_increase, cooldown: $min_increase_cooldown"
        if (( seconds_since_increase < min_increase_cooldown )); then
            log 2 "Quantum increase blocked: cooldown period active (${seconds_since_increase}s < ${min_increase_cooldown}s)"
        fi
    else
        log 3 "No new ERRs detected, quantum increase not needed"
        # Additional debugging: show what clients were checked
        if (( ${#curr_errs[@]} > 0 )); then
            log 3 "Checked ${#curr_errs[@]} clients for error increases:"
            for key in "${!curr_errs[@]}"; do
                curr_val=${curr_errs[$key]:-0}
                prev_val=${prev_errs[$key]:-0}
                name="${client_pretty_names[$key]:-unknown}"
                log 3 "  $name (ID:$key): curr=$curr_val, prev=$prev_val"
            done
        else
            log 3 "No clients found in current frame"
        fi
    fi

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
            log 3 "Executing: pw-metadata -n settings 0 clock.min-quantum $next_quantum"
            if /usr/bin/pw-metadata -n settings 0 clock.min-quantum "$next_quantum" >/dev/null 2>&1; then
                log 3 "pw-metadata command succeeded"
            else
                log 1 "ERROR: pw-metadata command failed!"
            fi
            last_set_quantum=$next_quantum
            quantum=$next_quantum
            last_decrease_or_increase_time=$now
            last_err_increase_time=$now
            last_increase_time=$now
        else
            log 2 "Quantum increase blocked: already at maximum (current=$quantum, max=$max_quantum)"
        fi
    fi

    # Quantum decrease (as before)
    if [[ -z "${quantum_backoff[$quantum]+set}" ]]; then
        quantum_backoff[$quantum]=$default_backoff
    fi
    current_backoff=${quantum_backoff[$quantum]}
    seconds_since_for_decrease=$(( now - last_decrease_or_increase_time ))
    log 3 "Decrease evaluation: quantum=$quantum, backoff=${current_backoff}min, seconds_since_change=$seconds_since_for_decrease"
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
            # Calculate next backoff before updating quantum_backoff array
            if [[ -z "${quantum_backoff[$next_quantum]+set}" ]]; then
                next_backoff=$(( current_backoff / 2 ))
            else
                next_backoff=$(( quantum_backoff[$next_quantum] / 2 ))
            fi
            (( next_backoff < 1 )) && next_backoff=1
            quantum_backoff[$next_quantum]=$next_backoff
            log 1 "↓ Decreasing quantum from $quantum to $next_quantum (next decrease in ${quantum_backoff[$next_quantum]} min)"
            log 3 "Executing: pw-metadata -n settings 0 clock.min-quantum $next_quantum"
            if /usr/bin/pw-metadata -n settings 0 clock.min-quantum "$next_quantum" >/dev/null 2>&1; then
                log 3 "pw-metadata command succeeded"
            else
                log 1 "ERROR: pw-metadata command failed!"
            fi
            last_set_quantum=$next_quantum
            quantum=$next_quantum
            last_decrease_or_increase_time=$now
            # Note: Keep last_increase_time unchanged to maintain increase cooldown
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
            log 3 "Removed tracking for vanished client: $gone_key"
        fi
    done

    # Clear for next frame
    clients_with_new_errs=()
    # Note: Don't clear curr_errs immediately since we might process multiple times per collection cycle
    # Instead, clear it when we start a new frame
}

header_found=0
pwtop_header=""
frame_started=0
last_frame_time=0
# Maximum time to wait before processing accumulated frame data (seconds)
max_frame_wait=1
# Track number of lines processed in current frame to ensure regular processing
lines_in_frame=0
# Force frame processing after this many client lines even without header detection
max_lines_per_frame=20

while read -r line; do
    current_time=$(date +%s)
    
    # More aggressive frame processing: process on timeout OR if we have clients waiting
    if (( frame_started && ((current_time - last_frame_time >= max_frame_wait && ${#curr_errs[@]} > 0) || lines_in_frame >= max_lines_per_frame) )); then
        elapsed_time=$((current_time - last_frame_time))
        client_count=${#curr_errs[@]}
        if (( lines_in_frame >= max_lines_per_frame )); then
            log 3 "Processing frame after $lines_in_frame lines (${client_count} clients)"
        else
            log 3 "Processing frame due to timeout (${elapsed_time}s since last frame, ${client_count} clients)"
        fi
        process_frame
        last_frame_time=$current_time
        lines_in_frame=0
    fi
    
    # Header detection - look for actual pw-top headers
    if [[ "$line" =~ ^[[:space:]]*S[[:space:]]+ID[[:space:]]+(QUANT|QUANTUM)[[:space:]]+.*ERR ]] || [[ "$line" =~ ^[[:space:]]*[A-Z][[:space:]]+ID[[:space:]]+(QUANT|QUANTUM)[[:space:]]+.*ERR ]]; then
        if (( frame_started && ${#curr_errs[@]} > 0 )); then
            log 3 "Processing frame with ${#curr_errs[@]} clients (header detected)"
            process_frame
        fi
        find_pwtop_columns "$line"
        pwtop_header="$line"
        frame_started=1
        last_frame_time=$current_time
        lines_in_frame=0
        # Clear frame data for new frame
        curr_errs=()
        client_pretty_names=()
        client_quants=()
        client_roles=()
        log 3 "New frame detected: $line"
        continue
    fi

    parse_result=$(parse_client "$line")
    if [[ $? != 0 ]]; then
        continue
    fi
    
    lines_in_frame=$((lines_in_frame + 1))
    
    # Parse the newline-separated output correctly
    readarray -t parsed_fields <<< "$parse_result"
    key="${parsed_fields[0]}"
    name="${parsed_fields[1]}"
    err="${parsed_fields[2]}"
    quant_client="${parsed_fields[3]}"
    role="${parsed_fields[4]}"

    if [[ "$role" != "R" ]]; then
        continue
    fi

    curr_errs["$key"]=$err
    client_pretty_names["$key"]="$name"
    client_quants["$key"]=$quant_client
    client_roles["$key"]=$role
    
    # Process frame immediately if we detect significant ERR increases
    if [[ -n "${prev_errs[$key]}" ]] && (( err > prev_errs[$key] + 10 )); then
        log 3 "Large ERR increase detected for $name: ${prev_errs[$key]} -> $err, processing frame immediately"
        process_frame
        last_frame_time=$current_time
        lines_in_frame=0
    fi
done < <(pw-top -b)

# process last frame if script is exiting
process_frame
