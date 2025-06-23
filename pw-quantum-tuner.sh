#!/usr/bin/env bash

# === CONFIGURATION ===
base_threshold=3              # Default ERR/s threshold to trigger increase
min_threshold=1               # Adaptive threshold lower bound
adaptive_decay=1              # How fast to restore threshold after quiet
check_interval=10             # Check every 10 seconds

quantum_change_cooldown=30    # Minimum seconds between increases
decrease_cooldown=120         # Minimum seconds between decreases
low_err_streak_target=6       # Intervals below threshold to decrease quantum

# === Function to read numeric metadata values ===
read_metadata_value() {
    /usr/bin/pw-metadata -n settings | grep "key:'$1'" | head -n1 | sed -n "s/.*value:'\([0-9]\+\)'.*/\1/p"
}

# === Function to extract ERR value from second snapshot ===
get_err_value() {
    /usr/bin/pw-top -bn2 2>/dev/null |
    awk '
    BEGIN { snapshot = 0; err_col = 0 }
    /^S[ \t]+ID/ {
        snapshot++
        for (i = 1; i <= NF; i++) if ($i == "ERR") err_col = i
        next
    }
    snapshot == 2 && NF && err_col && $err_col ~ /^[0-9]+$/ {
        if ($err_col > max) max = $err_col
    }
    END { print max + 0 }'
}

# === Read min/max from metadata, with sane fallbacks ===
min_quantum=$(read_metadata_value clock.min-quantum)
max_quantum=$(read_metadata_value clock.max-quantum)
[[ -z "$min_quantum" ]] && min_quantum=128
[[ -z "$max_quantum" ]] && max_quantum=4096

# === Determine initial quantum ===
initial_quantum=$(read_metadata_value clock.force-quantum)
if [[ -z "$initial_quantum" || "$initial_quantum" -le 0 ]]; then
    echo "$(date +'%F %T') Invalid or missing clock.force-quantum — using min_quantum ($min_quantum)"
    initial_quantum="$min_quantum"
    /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$initial_quantum"
else
    echo "$(date +'%F %T') Detected existing clock.force-quantum: $initial_quantum"
fi

quantum=$initial_quantum

# === Setup signal handler ===
trap 'echo "Exiting... restoring initial quantum: $initial_quantum"; /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$initial_quantum"; exit 0' SIGINT SIGTERM

# === State ===
low_err_streak=0
last_quantum_change=0
adaptive_threshold=$base_threshold
prev_err=$(get_err_value)

# === Main Loop ===
while true; do
    sleep "$check_interval"
    now=$(date +%s)

    curr_err=$(get_err_value)

    if ! [[ "$curr_err" =~ ^[0-9]+$ ]] || ! [[ "$prev_err" =~ ^[0-9]+$ ]]; then
        prev_err=$curr_err
        continue
    fi

    err_diff=$((curr_err - prev_err))
    prev_err=$curr_err

#     echo "$(date +'%F %T') DEBUG: ERR/s=$err_diff | Quantum=$quantum | Threshold=$adaptive_threshold"

    # === Decision: Increase quantum ===
    if (( err_diff > adaptive_threshold )); then
        low_err_streak=0
        (( adaptive_threshold-- ))
        (( adaptive_threshold < min_threshold )) && adaptive_threshold=$min_threshold

        if (( now - last_quantum_change >= quantum_change_cooldown )) && (( quantum * 2 <= max_quantum )); then
            quantum=$((quantum * 2))
            echo "$(date +'%F %T') ↑ ERR/s: $err_diff | Increasing quantum to $quantum"
            /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$quantum" > /dev/null
            last_quantum_change=$now
        fi

    # === Decision: Decrease quantum ===
    else
        ((low_err_streak++))
        (( adaptive_threshold += adaptive_decay ))
        (( adaptive_threshold > base_threshold )) && adaptive_threshold=$base_threshold

        if (( low_err_streak >= low_err_streak_target )) && \
           (( now - last_quantum_change >= decrease_cooldown )) && \
           (( quantum / 2 >= min_quantum )); then

            quantum=$((quantum / 2))
            echo "$(date +'%F %T') ↓ ERR/s: $err_diff | Decreasing quantum to $quantum"
            /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$quantum" > /dev/null
            last_quantum_change=$now
            low_err_streak=0
        fi
    fi
done
