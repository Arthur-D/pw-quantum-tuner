# PipeWire Quantum Tuner

PipeWire Quantum Tuner is a bash script that dynamically adjusts PipeWire audio buffer sizes (quantum) in real-time to optimize audio latency and reliability. It monitors audio client error statistics and automatically increases buffer sizes when audio processing errors are detected, while seeking the lowest possible latency when the system is stable.

**Always follow these instructions first** and only fallback to additional search or bash commands when the information here is incomplete or found to be in error.

## Working Effectively

### Prerequisites and Installation
- Install PipeWire and required tools:
  ```bash
  sudo apt update
  sudo apt install -y pipewire pipewire-bin
  ```
  TIMING: Package installation takes 2-5 minutes depending on system and network. NEVER CANCEL the installation process.

- Alternative package managers:
  - **Fedora/RHEL**: `sudo dnf install pipewire pipewire-utils`
  - **Arch Linux**: `sudo pacman -S pipewire`

- Verify installation:
  ```bash
  which pw-top pw-metadata bash awk grep sed date
  ```
  All commands must be available before proceeding.

### Repository Structure
- `pw-quantum-tuner.sh` - Main executable bash script
- `pw-quantum-tuner.service` - SystemD user service file template
- `README.md` - Comprehensive documentation
- `LICENSE` - MIT license file
- `.gitignore` - Currently empty

### Script Validation and Testing
- Validate script syntax (always run this first):
  ```bash
  bash -n ./pw-quantum-tuner.sh
  ```
  TIMING: Syntax check completes in under 1 second.

- Run shellcheck if available for code quality:
  ```bash
  shellcheck ./pw-quantum-tuner.sh
  ```
  Note: Script has some unused variable warnings which are acceptable.

### Running the Script
- Basic execution (requires running PipeWire server):
  ```bash
  ./pw-quantum-tuner.sh
  ```

- With debug logging:
  ```bash
  ./pw-quantum-tuner.sh --log-level 3
  ```

- Log levels:
  - `--log-level 1` (default): Normal logs (quantum changes, basic actions)
  - `--log-level 2`: Also logs per-client error events  
  - `--log-level 3`: Full debug (parsing, state, all calculations)

TIMING: Script startup takes less than 1 second. Runtime is continuous until stopped.

CRITICAL: The script requires a running PipeWire server to function properly. Without it, you'll see "Host is down" or "can't connect" errors.

### Dependencies Validation
The script depends on these commands that must be available:
- `bash` - Shell interpreter
- `pw-top` - PipeWire process monitor (from pipewire-bin package)
- `pw-metadata` - PipeWire metadata tool (from pipewire-bin package)  
- `awk`, `grep`, `sed`, `date` - Standard Unix text processing tools

### SystemD Service Setup
- The provided service file needs path customization:
  ```bash
  # Edit pw-quantum-tuner.service and replace placeholder path
  sed -i "s|/full/path/to/script/pw-quantum-tuner|$(pwd)|g" pw-quantum-tuner.service
  ```

- Install as user service:
  ```bash
  mkdir -p ~/.config/systemd/user
  cp pw-quantum-tuner.service ~/.config/systemd/user/
  systemctl --user daemon-reload
  systemctl --user enable pw-quantum-tuner.service
  ```

## Validation

### Always validate after making changes:
1. **Syntax validation**: Always run `bash -n ./pw-quantum-tuner.sh` before testing
2. **Functional testing**: Test script execution with different log levels
3. **PipeWire integration**: Verify script can connect to PipeWire when server is running

### Manual Testing Scenarios
Since this is an audio utility that requires a running PipeWire server:

1. **Basic functionality test**:
   ```bash
   # Test script starts and handles missing PipeWire gracefully
   timeout 5 ./pw-quantum-tuner.sh --log-level 1
   ```
   Expected: Script should start, show "can't connect" messages, and exit cleanly.
   TIMING: Test completes in under 5 seconds. NEVER CANCEL this test.

2. **Debug output validation**:
   ```bash
   # Test verbose logging works
   timeout 3 ./pw-quantum-tuner.sh --log-level 3
   ```
   Expected: Should show detailed debug output about column detection and client parsing.
   TIMING: Test completes in under 3 seconds. NEVER CANCEL this test.

3. **Command line argument parsing**:
   ```bash
   # Test both argument formats
   ./pw-quantum-tuner.sh --log-level=2 &
   sleep 1 && kill %1
   ./pw-quantum-tuner.sh --log-level 3 &
   sleep 1 && kill %1
   ```

IMPORTANT: Full functional testing requires a running PipeWire audio server with active audio clients. In headless environments, the script will start but show connection errors, which is expected behavior.

### Production Environment Testing
When PipeWire is running with audio clients:
1. **Monitor quantum adjustments**: Run script and observe automatic quantum changes
2. **Verify error detection**: Check that audio glitches trigger quantum increases  
3. **Validate backoff behavior**: Confirm quantum decreases when system stabilizes
4. **Test service integration**: Verify SystemD service starts and stops correctly

## Common Tasks

### Code Quality and Linting
- Always run syntax validation: `bash -n ./pw-quantum-tuner.sh`
- Use shellcheck for style checking: `shellcheck ./pw-quantum-tuner.sh`
- Review script with different log levels to understand behavior

### Making Changes
- Test syntax after any script modifications
- Validate service file changes with: `systemd-analyze verify pw-quantum-tuner.service`
- Always test both normal and debug output modes

### Deployment
- Script is production-ready as-is, no build process needed
- Copy script to target location and make executable: `chmod +x pw-quantum-tuner.sh`
- Install systemd service for automatic startup
- Requires PipeWire to be running on target system

## Key Implementation Details

### Script Functionality
- Monitors PipeWire clients using `pw-top -b` in batch mode
- Tracks audio processing errors (ERR column) for running clients (role "R")
- Automatically doubles quantum when errors increase (with cooldown protection)
- Gradually reduces quantum when system is stable
- Uses adaptive backoff timers to prevent oscillation

### Configuration
- Reads quantum limits from PipeWire configuration files
- Falls back to defaults: min_quantum=128, max_quantum=8192  
- Can be overridden via PipeWire metadata: `clock.force-quantum`
- Minimum 10-second cooldown between quantum increases

### Error Handling
- Gracefully handles missing PipeWire server
- Safely parses `pw-top` output with column detection
- Removes tracking for disappeared audio clients
- Logs all quantum changes and reasons

NEVER CANCEL: Script runs continuously by design. Use Ctrl+C or systemd to stop cleanly.

## Troubleshooting

### Common Issues
- "Host is down" errors: PipeWire server not running or accessible
- "command not found": Install pipewire and pipewire-bin packages
- Service won't start: Check and fix paths in service file
- No quantum changes: Normal if no audio clients or errors detected

### Debug Information
Use `--log-level 3` to see:
- Column parsing from pw-top output
- Client detection and error tracking  
- Quantum change calculations and decisions
- All pw-metadata command executions

The script is designed to be safe and non-destructive - it only adjusts PipeWire metadata settings and does not require root access.