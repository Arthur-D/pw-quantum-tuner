# pw-quantum-tuner

A simple adaptive script for PipeWire that tunes the quantum level to reduce audio glitches and optimize performance.

## How it works

`pw-quantum-tuner.sh` monitors the error rate (ERR/s) reported by `pw-top`. If the error rate increases above a dynamic threshold, it increases the PipeWire quantum (buffer size). If errors stay low for a while, it decreases the quantum, aiming for the lowest stable value.

- Reads current and allowed quantum values from PipeWire metadata.
- Adjusts the `clock.force-quantum` setting via `pw-metadata` to optimize for minimal audio errors.
- Runs in a loop, checking every 10 seconds (configurable).

## Requirements

- Bash
- PipeWire (`pw-top`, `pw-metadata` utilities)

## Usage

1. Make the script executable:

    ```bash
    chmod +x pw-quantum-tuner.sh
    ```

2. Run the script (it may require appropriate permissions to access PipeWire):

    ```bash
    ./pw-quantum-tuner.sh
    ```

3. The script will automatically monitor and adjust the quantum value as needed. It will log changes to the console.

## Using as a systemd service

To have `pw-quantum-tuner.sh` run automatically, you can use a systemd user service:

1. **Copy the unit file**  
   Place the `pw-quantum-tuner.service` file into your user systemd directory:
   
   ```bash
   mkdir -p ~/.config/systemd/user
   cp pw-quantum-tuner.service ~/.config/systemd/user/
   ```

2. **Reload systemd to recognize the new service:**

   ```bash
   systemctl --user daemon-reload
   ```

3. **Enable and start the service:**

   ```bash
   systemctl --user enable --now pw-quantum-tuner.service
   ```

4. **Check status:**

   ```bash
   systemctl --user status pw-quantum-tuner.service
   ```

Make sure that the script path in the service file matches the location of your `pw-quantum-tuner.sh` script.

## Configuration

You can edit the script to adjust thresholds and intervals:

- `base_threshold`: Base error threshold before increasing quantum (default: 3)
- `low_err_streak_target`: Target of low error checks before decreasing quantum (default: 60)
- `quantum_change_cooldown`: Minimum seconds between quantum changes (default: 30)
- `check_interval`: How often to check for errors (default: 10)
