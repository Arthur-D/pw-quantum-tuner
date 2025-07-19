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

## How It Works

- **Watches PipeWire clients in real time** using `pw-top`.
- **Tracks all running clients** (role "R") and monitors their `ERR` counts (audio processing errors).
- **If any client’s ERR count increases** (i.e., new audio errors are detected for any client during a single `pw-top` frame), the script doubles the quantum (up to a maximum) and increases a backoff timer, giving the system more time before considering reducing the quantum again.
- **If no new errors are detected for a period** (the backoff interval), the quantum is halved (down to the minimum), gradually seeking the lowest stable buffer size.
- **Backoff intervals are dynamically adjusted**: Each time the quantum is increased, the waiting period before a possible decrease is also increased (and vice versa), to avoid oscillation and to adapt to the system’s needs.
- **Clients that disappear have their error state tracking removed**.
- **All changes are logged**, with debug levels for detailed introspection.

---

## Usage

```bash
./pw-quantum-tuner.sh [--log-level N]
```
- `--log-level 1` (default): Normal logs (quantum changes, basic actions)
- `--log-level 2`: Also logs per-client error events
- `--log-level 3`: Full debug (parsing, state, all calculations and internal decisions)

---

## Requirements

- Bash (should work with most POSIX shells)
- PipeWire and `pw-top`
- `pw-metadata` (for reading/writing quantum settings)

---

## Configuration

- The script will use PipeWire’s configured `min_quantum` and `max_quantum` if available, or fallback to defaults.
- You can override quantum by setting PipeWire metadata (`clock.force-quantum`), or by passing options to the script.

---

## How to Monitor

- Run with `--log-level 3` for detailed logs (including every parsed client and all state transitions).
- Quantum changes and reasons (error surges, timeouts) are always logged at level 1.
---

## Notes

- The script is safe to run alongside PipeWire; it only updates the quantum setting via `pw-metadata`.
- It does **not** require root.
