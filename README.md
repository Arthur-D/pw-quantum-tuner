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
- **Tracks all running clients** (role "R") and monitors their `ERR` counts (audio processing errors).
- **If any client’s ERR count increases** (i.e., new audio errors are detected for any client during a single `pw-top` frame), the script doubles min-quantum (up to a maximum) and increases a backoff timer, giving the system more time before considering reducing the quantum again.
- **If no new errors are detected for a period** (the backoff interval), the quantum is halved (down to the minimum), gradually seeking the lowest stable buffer size.
- **Backoff intervals are dynamically adjusted**: Each time the quantum is increased, the waiting period before a possible decrease is also increased (and vice versa), to avoid oscillation and to adapt to the system’s needs.
- **Clients that disappear have their error state tracking removed**.
- **All changes are logged**, with debug levels for detailed introspection.

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

- The script will use PipeWire’s configured `min_quantum` and `max_quantum` if available, or fallback to defaults.
- You can override quantum by setting PipeWire metadata (`clock.min-quantum`), or by passing options to the script.

---

## Requirements

- Bash (should work with most POSIX shells).
- PipeWire, including `pw-top` and `pw-metadata` (should as far as I know be included by default with PipeWire in most distributions).
- It does **not** require root and should be run at the user level, either directly or as a systemd user service.
