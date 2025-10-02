# PipeWire Quantum Tuner

**pw-quantum-tuner.sh** is a dynamic quantum (buffer size) tuner for PipeWire, designed to automatically adjust the PipeWire server's quantum based on real-time audio client error statistics. Its goal is to optimize latency and reliability; starting with the lowest possible quantum for low-latency audio, and automatically increasing it when audio processing errors are detected.

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
- **Tracks all running clients** (role "R") and monitors their `ERR` counts (audio processing errors).
- **If any client’s ERR count increases** (i.e., new audio errors are detected for any client during a single `pw-top` frame), the script doubles the quantum (up to a maximum) and increases a backoff timer, giving the system more time before considering reducing the quantum again.
- **If no new errors are detected for a period** (the backoff interval), the quantum is halved (down to the minimum), gradually seeking the lowest stable buffer size.
- **Backoff intervals are dynamically adjusted**: Each time the quantum is increased, the waiting period before a possible decrease is also increased (and vice versa), to avoid oscillation and to adapt to the system’s needs.
- **Clients that disappear have their error state tracking removed**.
- **All changes are logged**, with debug levels for detailed introspection.

---

## Implementation Approach

This script adjusts PipeWire's `clock.min-quantum` parameter rather than `clock.force-quantum`. This approach was recommended during discussions with PipeWire's upstream developers and offers several advantages:

- **Better compatibility**: Works more naturally with PipeWire's internal scheduling and allows the audio server to make optimal decisions while respecting the minimum buffer size constraint.
- **Dynamic latency**: The quantum can vary between the configured minimum and maximum based on system conditions, rather than being locked to a fixed value.
- **More flexible**: Other audio clients and applications can still influence quantum selection within the constraints set by min-quantum.

### Trade-offs

- **Variable latency**: Since the actual quantum used by PipeWire may be higher than the min-quantum setting (depending on client requirements and system load), latency is less predictable than with a fixed quantum.
- **Not for all users**: If you need consistent, predictable latency (e.g., for professional audio production or DAW use), manually setting a fixed quantum value may be more appropriate.
- **Audio gaps during transitions**: When the quantum changes, brief audio glitches may occur as the audio pipeline reconfigures.

### Migration from Previous Versions

If you were using an earlier version of this script that adjusted `clock.force-quantum`, the new version will work as a drop-in replacement with no configuration changes needed. The script now:

1. Sets `clock.min-quantum` instead of `clock.force-quantum` when increasing or decreasing buffer sizes
2. Reads the current `clock.min-quantum` value on startup to determine the initial quantum
3. Still respects your configured min and max quantum limits

No manual intervention is required for the migration.

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

- The script will use PipeWire's configured `min_quantum` and `max_quantum` if available, or fallback to defaults (128 and 8192 respectively).
- The script dynamically adjusts PipeWire's `clock.min-quantum` metadata value in real-time to tune buffer sizes.
- **Note on approach**: This script adjusts `clock.min-quantum` rather than `clock.force-quantum`, following recommendations from PipeWire's creator during upstream discussions. This approach is more compatible with PipeWire's design and allows the audio server to make better scheduling decisions while respecting the minimum buffer size constraint.

---

## Requirements

- Bash (should work with most POSIX shells).
- PipeWire, including `pw-top` and `pw-metadata` (should as far as I know be included by default with PipeWire in most distributions).
- It does **not** require root and should be run at the user level, either directly or as a systemd user service.
