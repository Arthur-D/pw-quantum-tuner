#!/usr/bin/env bash

# === CONFIGURATION ===
base_threshold=3                # Starting threshold for ERR/s
check_interval=10               # Check every 10 seconds
quantum_change_cooldown=15      # Minimum seconds between increases
decrease_attempt_delay=120      # How long to wait before trying a decrease
low_err_streak_target=9         # Number of intervals before attempting to lower

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

# === Read min/max from metadata ===
min_quantum=$(read_metadata_value clock.min-quantum)
max_quantum=$(read_metadata_value clock.max-quantum)
[[ -z "$min_quantum" ]] && min_quantum=128
[[ -z "$max_quantum" ]] && max_quantum=8192

# === Determine initial quantum ===
initial_quantum=$(read_metadata_value clock.force-quantum)
if [[ -z "$initial_quantum" || "$initial_quantum" -le 0 ]]; then
    initial_quantum="$min_quantum"
    echo "$(date +'%F %T') No valid clock.force-quantum found. Setting to $initial_quantum"
    /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$initial_quantum" > /dev/null
else
    echo "$(date +'%F %T') Detected existing clock.force-quantum: $initial_quantum"
fi

quantum=$initial_quantum
stable_quantum=$quantum
low_err_streak=0
last_quantum_change=0
last_decrease_attempt=0

trap 'echo "Exiting... restoring initial quantum: $initial_quantum"; /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$initial_quantum"; exit 0' SIGINT SIGTERM

prev_err=$(get_err_value)

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

    echo "$(date +'%F %T') DEBUG: ERR/s=$err_diff | Quantum=$quantum | Stable=$stable_quantum"

    # === Increase quantum aggressively if ERRs detected ===
    if (( err_diff > base_threshold )); then
        low_err_streak=0

        if (( now - last_quantum_change >= quantum_change_cooldown )) && (( quantum * 2 <= max_quantum )); then
            quantum=$((quantum * 2))
            echo "$(date +'%F %T') ↑ ERR/s: $err_diff | Increasing quantum to $quantum"
            /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$quantum" > /dev/null
            last_quantum_change=$now
        fi

    else
        ((low_err_streak++))

        # Record stable quantum if long enough streak of low errors
        if (( low_err_streak >= 3 )); then
            if (( quantum < stable_quantum || stable_quantum == 0 )); then
                stable_quantum=$quantum
                echo "$(date +'%F %T') Stable quantum determined: $stable_quantum"
            fi
        fi

        # Only try to decrease after long calm
        if (( low_err_streak >= low_err_streak_target )) &&
           (( now - last_quantum_change >= decrease_attempt_delay )) &&
           (( quantum > stable_quantum )) &&
           (( quantum / 2 >= min_quantum )); then

            quantum=$((quantum / 2))
            echo "$(date +'%F %T') ↓ ERR/s: $err_diff | Attempting to decrease quantum to $quantum"
            /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$quantum" > /dev/null
            last_quantum_change=$now
            low_err_streak=0
        fi
    fi
done
