#!/usr/bin/env bash

# Exercise the real frame loop without connecting to the user's PipeWire server.
test_now=1000
metadata_calls=()
fail_property=""
pw-metadata() {
    metadata_calls+=("$4=$5")
    [[ "$4" != "$fail_property" ]]
}
pw-top() { :; }
date() { echo "$test_now"; }

source "$(dirname "${BASH_SOURCE[0]}")/../pw-quantum-tuner.sh" --log-level=0

reset_state() {
    min_quantum=128
    max_quantum=8192
    quantum=128
    forced_quantum=0
    last_increase_time=0
    last_stability_event_time=$test_now
    metadata_calls=()
    prev_errs=()
    curr_errs=()
    client_pretty_names=()
    client_quants=()
    client_roles=()
    quantum_backoff=()
    reported_driver_quants=()
    clients_with_new_errs=()
    fail_property=""
}

expect() {
    if [[ "$1" != "$2" ]]; then
        printf 'FAIL: %s (got %s, expected %s)\n' "$3" "$1" "$2" >&2
        return 1
    fi
}

client() {
    client_pretty_names[1]=$1
    client_quants[1]=$2
    curr_errs[1]=$3
    client_roles[1]=R
}

raise_bluetooth_floor() {
    prev_errs[1]=0
    client bluez_output.test 128 1
    process_frame 1
    expect "$quantum:$forced_quantum" "256:0" "try the floor before forcing" || return
    test_now=$((test_now + min_increase_cooldown))
}

force_bluetooth() {
    raise_bluetooth_floor || return
    client bluez_output.test 128 2
    process_frame 1
    expect "$quantum:$forced_quantum" "256:256" "force an ignored Bluetooth floor"
}

wired_floor() {
    prev_errs[1]=0
    client alsa_output.test 128 1
    process_frame 1
    expect "${metadata_calls[*]}" \
        "clock.min-quantum=256 clock.force-quantum=0" "wired changes only the floor"
}

bluetooth_escalation() {
    force_bluetooth || return
    test_now=$((test_now + min_increase_cooldown))
    client bluez_output.test 256 3
    process_frame 1
    expect "$quantum:$forced_quantum" "512:512" "increase an active override"
}

bluetooth_cooldown() {
    raise_bluetooth_floor || return
    test_now=$((test_now - 1))
    client bluez_input.test 64 2
    process_frame 1
    expect "$quantum:$forced_quantum" "256:0" "fallback respects cooldown" || return
    test_now=$((test_now + 1))
    client bluez_input.test 64 3
    process_frame 0
    expect "$forced_quantum" 256 "partial-frame errors can trigger fallback"
}

bluetooth_respects_floor() {
    raise_bluetooth_floor || return
    client bluez_output.test 512 2
    process_frame 1
    expect "$quantum:$forced_quantum" "512:0" "larger observed quantum is not forced"
}

bluetooth_follower() {
    raise_bluetooth_floor || return
    client '+ bluez_output.test' 64 2
    process_frame 1
    expect "$quantum:$forced_quantum" "512:0" "follower request is not a driver observation"
}

bluetooth_async_follower() {
    force_bluetooth || return
    client '= bluez_output.test' 64 2
    process_frame 1
    expect "$forced_quantum" 256 "async Bluetooth follower still counts as active" || return
    test_now=$((test_now + min_increase_cooldown))
    forced_quantum=0
    client '= bluez_output.test' 64 3
    process_frame 1
    expect "$quantum:$forced_quantum" "512:0" "async follower cannot trigger forcing"
}

new_bluetooth_client() {
    quantum=256
    client bluez_output.test 64 99
    process_frame 1
    expect "$quantum:$forced_quantum" "256:0" "existing errors on a new client do not force"
}

bluetooth_without_errors() {
    raise_bluetooth_floor || return
    process_frame 1
    expect "$quantum:$forced_quantum" "256:0" "ignored floor alone does not force"
}

parse_driver_quantum() {
    find_pwtop_columns 'S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME '
    local line
    line=$(printf '%s %4.1u %6.1u %6.1u %7s %7s %5s %5s  %3.1u %16.16s %s%s' \
        R 1 128 48000 1.0us 2.0us 0.00 0.00 2 'S32LE 2 48000' '' bluez_output.test)
    local fields
    fields=$(parse_client "$line") || return
    expect "$fields" $'1\nbluez_output.test\n2\n128\nR' "driver name and quantum parsing"
}

release_on_disconnect() {
    force_bluetooth || return
    curr_errs=()
    process_frame 0
    expect "$forced_quantum" 256 "partial snapshot does not release override" || return
    process_frame 1
    expect "$quantum:$forced_quantum" "256:0" "empty complete snapshot releases override"
}

release_on_stability() {
    force_bluetooth || return
    test_now=$((test_now + 120))
    process_frame 1
    expect "$quantum:$forced_quantum" "128:0" "stability lowers floor and releases override"
}

fallback_at_maximum() {
    raise_bluetooth_floor || return
    max_quantum=256
    client bluez_output.test 128 2
    process_frame 1
    expect "$quantum:$forced_quantum" "256:256" "fallback works at maximum target"
}

write_failures() {
    prev_errs[1]=0
    client alsa_output.test 128 1
    fail_property=clock.min-quantum
    process_frame 1
    expect "$quantum:$forced_quantum:$last_increase_time" "128:0:0" "failed floor is not committed" || return
    expect "${metadata_calls[*]}" "clock.min-quantum=256" "do not force after floor failure" || return
    reset_state
    force_bluetooth || return
    fail_property=clock.force-quantum
    test_now=$((test_now + 120))
    process_frame 1
    expect "$quantum:$forced_quantum" "256:256" "failed release retains state" || return
    fail_property=""
    process_frame 1
    expect "$quantum:$forced_quantum" "128:0" "retry failed release"
}

failed_startup() {
    fail_property=clock.min-quantum
    if ( source "$(dirname "${BASH_SOURCE[0]}")/../pw-quantum-tuner.sh" --log-level=0 ); then
        echo "FAIL: startup accepted failed metadata initialization" >&2
        return 1
    fi
}

driver_quantum_logging() {
    local -a captured=()
    log() { captured+=("$*"); }
    client bluez_output.test 256 0
    process_frame 0
    expect "${#reported_driver_quants[@]}" 0 "partial snapshots are not reported" || return
    process_frame 1
    expect "${reported_driver_quants[1]}" 256 "initial driver observation is recorded" || return
    [[ "${captured[*]}" == *"Observed driver quantum: bluez_output.test (ID:1) = 256 frames (minimum target=128, forced=0;"* ]] || return 1
    captured=()
    process_frame 1
    [[ "${captured[*]}" != *"Observed driver quantum:"* ]] || return 1
    client bluez_output.test 512 0
    process_frame 1
    expect "${reported_driver_quants[1]}" 512 "changed observation is recorded" || return
    [[ "${captured[*]}" == *"= 512 frames"* ]] || return 1
    captured=()
    client '+ Firefox' 3600 0
    process_frame 1
    expect "${#reported_driver_quants[@]}" 0 "follower measurements excluded" || return
    [[ "${captured[*]}" != *"Observed driver quantum:"* ]] || return 1
    client '= bluez_output.test' 256 0
    process_frame 1
    expect "${#reported_driver_quants[@]}" 0 "async follower excluded" || return
    client bluez_output.test 0 0
    process_frame 1
    expect "${#reported_driver_quants[@]}" 0 "zero measurement excluded" || return
    client bluez_output.test 256 0
    process_frame 1
    curr_errs=()
    process_frame 1
    expect "${#reported_driver_quants[@]}" 0 "disappeared drivers cleared" || return
    captured=()
    client bluez_output.test 256 0
    process_frame 1
    [[ "${captured[*]}" == *"Observed driver quantum:"* ]]
}

failures=0
for test in wired_floor bluetooth_escalation bluetooth_cooldown \
    bluetooth_respects_floor bluetooth_follower bluetooth_async_follower \
    new_bluetooth_client bluetooth_without_errors parse_driver_quantum \
    release_on_disconnect release_on_stability fallback_at_maximum \
    write_failures failed_startup driver_quantum_logging; do
    if ( reset_state; "$test" ); then
        printf 'PASS: %s\n' "$test"
    else
        failures=$((failures + 1))
    fi
done
(( failures == 0 ))
