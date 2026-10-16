# PipeWire Quantum Tuner

**pw-quantum-tuner.sh** is a dynamic quantum (buffer size) tuner for PipeWire, designed to automatically adjust the PipeWire server's quantum based on real-time audio client error statistics. Its goal is to optimize latency and reliability; starting with the lowest possible quantum for low-latency audio, and automatically increasing it when audio processing errors are detected. However, it's not meant for most users and explicitly goes against the lessons learned from PulseAudio, which had dynamic latency, and PipeWire does not. This script tries to add that feature back, for users who really want it.

---

## Why use this?

- **Lower latency**: Always seeks the smallest quantum your system can handle.
- **Automatic recovery**: If audio glitches/errors occur, quantum is increased for stability.
- **Hands-off**: No manual tuning or guessing buffer sizes.

---

## Sounds great! Why not use this then?

- **Latency changes**: Less predictable, so if you use a Digital Audio Workstation you probably don't want this.
- **Creates small audio gaps**: When the PipeWire quantum changes, you get short audio gaps as a side effect.
- **Might expose audio device issues**: Very rarely, but sometimes changing the quantum leads to my Bluetooth audio headset disconnecting.

---

## How it works

- **Watches PipeWire clients in real time** using `pw-top`.
- **Tracks running clients** (role "R") and monitors their `ERR` counts (audio processing errors). Idle clients do not trigger adjustments.
- **If any client’s ERR count increases** (i.e., new audio errors are detected for any client during a single `pw-top` frame), the script doubles `clock.min-quantum` (up to a maximum) and increases a backoff timer, giving the system more time before considering reducing the quantum again. PipeWire remains free to choose a larger quantum.
- **Bluetooth fallback**: if a running Bluetooth driver's observed quantum remains below an already-raised minimum and that driver reports further errors after the increase cooldown, the script forces the current target using `clock.force-quantum` instead of raising the floor again. Bluetooth is identified by `bluez_input.*` / `bluez_output.*` node names; merely connected or idle devices do not trigger forcing. Follower nodes (prefixed with `+` or `=` in `pw-top`) are not treated as driver quantum measurements.
- **Forced quantum is temporary**: further error-driven increases adjust both the floor and the override. The override is released when a complete snapshot has no running Bluetooth nodes, or when the stability backoff expires and the floor is lowered. Forcing affects the graph, not just the Bluetooth device, and cannot fix every Bluetooth transport or codec issue.
- **If no new errors are detected for a period** (the backoff interval), the quantum is halved (down to the minimum), gradually seeking the lowest stable buffer size.
- **Backoff intervals are dynamically adjusted**: Each time the quantum is increased, the waiting period before a possible decrease is also increased (and vice versa), to avoid oscillation and to adapt to the system’s needs.
- **Clients that disappear have their error state tracking removed**.
- **All changes are logged**, with debug levels for detailed introspection.
- The tuner tracks its **requested minimum separately from the observed driver quantum**. Lowering the minimum does not guarantee the actual quantum will decrease if a device or application needs a larger buffer.

---

## Usage
### Direct script execution
```bash
chmod +x pw-quantum-tuner.sh
./pw-quantum-tuner.sh [--log-level N]
```
- **--log-level 1 (default)**
  - Shows normal logs: quantum changes, basic actions, startup messages, and errors.
    
- **--log-level 2**
  - Shows everything from level 1.
  - Additionally logs detailed per-client error events, including which clients had ERR increases and their details.
  - Includes extra debug information such as client parsing, state transitions, calculations, column detection, and internal decisions.
    
### Running as a systemd user service

To run the tuner automatically as a user service, use the provided [pw-quantum-tuner.service](./pw-quantum-tuner.service) file.

1. **Place the service file in your systemd user directory:**
   ```bash
   mkdir -p ~/.config/systemd/user
   cp pw-quantum-tuner.service ~/.config/systemd/user/
   ```
2. **Edit the ExecStart path:**
   Open the service file and replace `/full/path/to/script/pw-quantum-tuner/pw-quantum-tuner.sh` with the actual path to your script.
   
4. **Reload user systemd services and enable and start the service:**  
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now pw-quantum-tuner.service
   ```
---

## Configuration

- **Minimum quantum (`min_quantum`)**: read from `default.clock.min-quantum` in `pipewire.conf` (including drop-in `.d/*.conf` files), falling back to `128`.  This is the lowest quantum the tuner will target when the system is stable.
- **Maximum quantum (`max_quantum`)**: read from `default.clock.max-quantum` in `pipewire.conf` (including drop-in `.d/*.conf` files), falling back to `8192`.  If the resolved value is not greater than `min_quantum`, it is automatically raised to `min_quantum × 8`.
- Both values are read **only from config files, never from PipeWire settings metadata**.  Metadata values for `clock.min-quantum` and `clock.max-quantum` can be stale: previous script runs (or older versions of this script) may have written high values there, causing the tuner to start with `min == max` and no room to increase quantum.
- On startup the script **always resets to `min_quantum`**, clearing any stale `clock.force-quantum` and `clock.min-quantum` values from PipeWire metadata.  This ensures a clean slate on each start; the error-detection loop ramps up quickly if the system needs a higher quantum.
- Metadata write failures are logged. Startup exits if the initial floor/override reset fails; runtime failures do not advance the tuner's target or backoff.
---

## Requirements

- Bash (should work with most POSIX shells).
- PipeWire, including `pw-top` and `pw-metadata` (should as far as I know be included by default with PipeWire in most distributions).
- It does **not** require root and should be run at the user level, either directly or as a systemd user service.
