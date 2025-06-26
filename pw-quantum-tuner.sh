#!/usr/bin/env bash

# === CONFIGURATION ===
base_threshold=2              # Base ERR/s threshold
low_err_streak_target=10      # Longer wait before decreasing quantum
quantum_change_cooldown=30    # Seconds between allowed quantum changes
check_interval=10             # How often to check (in seconds)

# === Function to read numeric metadata values ===
read_metadata_value() {
    /usr/bin/pw-metadata -n settings | grep "key:'$1'" | head -n1 | sed -n "s/.*value:'\([0-9]\+\)'.*/\1/p"
}

# === Read min/max quantum from metadata, with sane fallbacks ===
min_quantum=$(read_metadata_value clock.min-quantum)
max_quantum=$(read_metadata_value clock.max-quantum)

[[ -z "$min_quantum" ]] && min_quantum=128
[[ -z "$max_quantum" ]] && max_quantum=8192

# === Determine current quantum (only used if valid) ===
initial_quantum=$(read_metadata_value clock.force-quantum)

if [[ -z "$initial_quantum" || "$initial_quantum" -le 0 ]]; then
    echo "$(date +'%F %T') No valid clock.force-quantum found. Waiting to set quantum until needed."
    quantum=0
else
    echo "$(date +'%F %T') Detected existing clock.force-quantum: $initial_quantum"
    quantum=$initial_quantum
fi

# === Setup state ===
low_err_streak=0
last_quantum_change=0
prev_err=$(/usr/bin/pw-top -bn2 | awk 'NF >= 9 && $9 ~ /^[0-9]+$/ { if ($9 > max) max = $9 } END { print max + 0 }')

# === Main Loop ===
while true; do
    sleep "$check_interval"
    now=$(date +%s)

    curr_err=$(/usr/bin/pw-top -bn2 | awk 'NF >= 9 && $9 ~ /^[0-9]+$/ { if ($9 > max) max = $9 } END { print max + 0 }')

    if ! [[ "$curr_err" =~ ^[0-9]+$ ]] || ! [[ "$prev_err" =~ ^[0-9]+$ ]]; then
        prev_err=$curr_err
        continue
    fi

    err_diff=$((curr_err - prev_err))
    prev_err=$curr_err

    # Skip changes if quantum is unset and no ERRs
    if (( quantum == 0 )) && (( err_diff == 0 )); then
        continue
    fi

    # If no valid quantum yet, set to min_quantum on first ERR
    if (( quantum == 0 )); then
        quantum=$min_quantum
        echo "$(date +'%F %T') ↑ First ERRs detected | Setting initial quantum to $quantum"
        /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$quantum" > /dev/null
        last_quantum_change=$now
        continue
    fi

    # Adaptive threshold grows with quantum
    threshold=$((base_threshold + quantum / 512))

    # === Increase quantum ===
    if (( err_diff > threshold )); then
        low_err_streak=0
        if (( now - last_quantum_change >= quantum_change_cooldown )) && (( quantum * 2 <= max_quantum )); then
            quantum=$((quantum * 2))
            echo "$(date +'%F %T') ↑ ERR/s: $err_diff | Increasing quantum to $quantum"
            /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$quantum" > /dev/null
            last_quantum_change=$now
        fi

    # === Decrease quantum ===
    else
        ((low_err_streak++))
        if (( low_err_streak >= low_err_streak_target )) && (( now - last_quantum_change >= quantum_change_cooldown )) && (( quantum / 2 >= min_quantum )); then
            quantum=$((quantum / 2))
            echo "$(date +'%F %T') ↓ ERR/s: $err_diff | Decreasing quantum to $quantum"
            /usr/bin/pw-metadata -n settings 0 clock.force-quantum "$quantum" > /dev/null
            last_quantum_change=$now
            low_err_streak=0
        fi
    fi
done
