#!/usr/bin/env bash

base_backoff=1
check_interval=2

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
    # Get the first nonzero quantum from a running stream
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

declare -A prev_errs curr_errs client_pretty_names client_quants client_seen client_roles
declare -A quantum_backoff
default_backoff=1

last_action_time=0
last_decrease_or_increase_time=0
last_err_increase_time=0

if (( log_level >= 1 )); then
    echo "Starting PipeWire quantum tuner at log level $log_level (quant=$quantum, min=$min_quantum, max=$max_quantum)"
fi

interval_lines=()
interval_count=0
quantum_just_changed=0
last_quantum_direction="none"

get_last_frame() {
    local i last_header_idx=-1
    for ((i=0; i<${#interval_lines[@]}; ++i)); do
        line="${interval_lines[$i]}"
        read -r _ _ field3 _ _ _ _ _ field9 _ <<< "$line"
        if [[ "$field9" == "ERR" && "$field3" == "QUANT" ]]; then
            last_header_idx=$i
        fi
    done
    if (( last_header_idx < 0 )); then
        printf "%s\n" "${interval_lines[@]}"
    else
        for ((i=last_header_idx+1; i<${#interval_lines[@]}; ++i)); do
            printf "%s\n" "${interval_lines[$i]}"
        done
    fi
}

parse_client() {
    local line="$1"
    [[ "$line" =~ ^[[:space:]]*$ ]] && return 1
    local field1 field2 field3 field4 field5 field6 field7 field8 field9
    read -r field1 field2 field3 field4 field5 field6 field7 field8 field9 _ <<< "$line"
    if [[ "$field9" == "ERR" && "$field3" == "QUANT" ]]; then
        return 1
    fi
    [[ ! "$field9" =~ ^[0-9]+$ ]] && return 1
    local role quant err name id
    role="$field1"
    id="$field2"
    quant="$field3"
    err="$field9"
    name=$(awk '{print $NF}' <<<"$line")
    [[ -z "$name" || "$name" == "0" || "$name" == "ERR" ]] && return 1
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

pw-top -b | while read -r line; do
    now=$(date +%s)
    interval_lines+=("$line")
    if (( now - last_action_time < check_interval )); then continue; fi
    last_action_time=$now

    unset curr_errs client_pretty_names client_quants client_roles
    declare -A curr_errs client_pretty_names client_quants client_roles

    frame_lines=()
    while IFS= read -r frame_line; do
        frame_lines+=("$frame_line")
    done < <(get_last_frame)

    for line_in in "${frame_lines[@]}"; do
        parsed=($(parse_client "$line_in"))
        [[ $? != 0 ]] && continue
        key="${parsed[0]}"
        name="${parsed[1]}"
        err="${parsed[2]}"
        quant="${parsed[3]}"
        role="${parsed[4]}"
        # Only process running clients
        if [[ "$role" != "R" ]]; then
            continue
        fi
        curr_errs["$key"]=$err
        client_pretty_names["$key"]="$name"
        client_quants["$key"]=$quant
        client_roles["$key"]=$role
    done
    interval_lines=()

    # Initialize backoff for current quantum if not set
    if [[ -z "${quantum_backoff[$quantum]+set}" ]]; then
        quantum_backoff[$quantum]=$default_backoff
    fi
    current_backoff=${quantum_backoff[$quantum]}

    quantum=$(clamp "$quantum" "$min_quantum" "$max_quantum")
    interval_count=$((interval_count + 1))

    # --- If quantum was just changed, reset all prev_errs and skip delta detection ---
    if (( quantum_just_changed )); then
        for k in "${!curr_errs[@]}"; do
            prev_errs["$k"]=${curr_errs["$k"]}
        done
        quantum_just_changed=0
        continue
    fi

    increase_names=()
    increase_amounts=()
    increased_this_interval=0
    for key in "${!curr_errs[@]}"; do
        # Only track running clients
        if [[ "${client_roles[$key]}" != "R" ]]; then
            continue
        fi
        curr_val=${curr_errs[$key]:-0}
        prev_val=${prev_errs[$key]:-unset}
        if [[ -z "${client_seen[$key]+set}" ]]; then
            # First time ever seen: initialize, do not report
            client_seen[$key]=1
            prev_errs[$key]=$curr_val
            continue
        fi
        if [[ "$prev_val" == "unset" ]]; then
            # Reappeared after missing: re-initialize, do not report
            prev_errs[$key]=$curr_val
            continue
        fi
        if (( curr_val > prev_val )); then
            increase_names+=("$key")
            increase_amounts+=("$((curr_val - prev_val))")
            increased_this_interval=1
        fi
    done

    quantum_changed=0

    if (( increased_this_interval )); then
        next_quantum=$((quantum * 2))
        next_quantum=$(clamp "$next_quantum" "$min_quantum" "$max_quantum")
        # Initialize backoff for next quantum if not set
        if [[ -z "${quantum_backoff[$next_quantum]+set}" ]]; then
            quantum_backoff[$next_quantum]=$current_backoff
        fi
        if (( next_quantum > quantum )); then
            # Calculate total new ERRs for this interval
            total_new_errs=0
            for delta in "${increase_amounts[@]}"; do
                total_new_errs=$((total_new_errs + delta))
            done

            # Double the backoff for next quantum when increasing
            quantum_backoff[$next_quantum]=$(( quantum_backoff[$next_quantum] * 2 ))

            msg="↑ Increasing quantum from $quantum to $next_quantum due to $total_new_errs new ERRs (next decrease in ${quantum_backoff[$next_quantum]} min)"
            log 1 "$msg"
            if (( log_level >= 2 )); then
                for i in "${!increase_names[@]}"; do
                    key="${increase_names[$i]}"
                    delta="${increase_amounts[$i]}"
                    total="${curr_errs[$key]}"
                    log 2 "  ${client_pretty_names[$key]} ($delta new ERRs, total $total ERRs)"
                done
            fi
            /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$next_quantum" >/dev/null 2>&1
            last_set_quantum=$next_quantum
            quantum=$next_quantum
            quantum_just_changed=1
        fi
        last_decrease_or_increase_time=$now
        last_err_increase_time=$now
        # Refresh backoff for new quantum
        current_backoff=${quantum_backoff[$quantum]}
    fi

    seconds_since_increase=$(( now - last_err_increase_time ))

    if (( quantum > min_quantum )); then
        if (( seconds_since_increase >= current_backoff * 60 )); then
            next_quantum=$((quantum / 2))
            next_quantum=$(clamp "$next_quantum" "$min_quantum" "$max_quantum")
            # Initialize backoff for next quantum if not set
            if [[ -z "${quantum_backoff[$next_quantum]+set}" ]]; then
                quantum_backoff[$next_quantum]=$current_backoff
            fi
            # Halve the backoff for next quantum, but at least 1
            next_backoff=$(( quantum_backoff[$next_quantum] / 2 ))
            (( next_backoff < 1 )) && next_backoff=1
            quantum_backoff[$next_quantum]=$next_backoff

            log 1 "↓ Decreasing quantum from $quantum to $next_quantum (next decrease in ${quantum_backoff[$next_quantum]} min)"
            if (( log_level >= 3 )); then
                log 3 "↓ Decreasing quantum from $quantum to $next_quantum (next decrease in ${quantum_backoff[$next_quantum]} min)"
            fi
            /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$next_quantum" >/dev/null 2>&1
            last_set_quantum=$next_quantum
            quantum=$next_quantum
            last_decrease_or_increase_time=$now
            last_err_increase_time=$now
            quantum_just_changed=1
            current_backoff=${quantum_backoff[$quantum]}
        else
            if (( log_level >= 3 )); then
                seconds_left=$(( current_backoff * 60 - seconds_since_increase ))
                mins_left=$(( seconds_left / 60 ))
                secs_rem=$(( seconds_left % 60 ))
                log 3 "$mins_left minute(s) $secs_rem second(s) before next decrease (quant=$quantum, min=$min_quantum, max=$max_quantum)"
            fi
        fi
    else
        if (( log_level >= 3 )); then
            seconds_since_increase=$(( now - last_err_increase_time ))
            seconds_left=$(( current_backoff * 60 - seconds_since_increase ))
            (( seconds_left < 0 )) && seconds_left=0
            mins_left=$(( seconds_left / 60 ))
            secs_rem=$(( seconds_left % 60 ))
            log 3 "Minimum quantum achieved: $mins_left minute(s) $secs_rem second(s) of backoff left (quantum=$quantum, min=$min_quantum, max=$max_quantum)"
        fi
    fi

    # Always update prev_errs for all currently seen running clients
    for k in "${!curr_errs[@]}"; do prev_errs["$k"]=${curr_errs["$k"]}; done

    # Remove tracking info for vanished clients
    for key in "${!prev_errs[@]}"; do
        if [[ -z "${curr_errs[$key]+set}" ]]; then
            unset prev_errs[$key]
            unset client_seen[$key]
        fi
    done
done
