# AGENTS.md

## Project overview
- This repository contains a single Bash utility, `pw-quantum-tuner.sh`, that tunes the PipeWire quantum dynamically based on client error counts.
- `pw-quantum-tuner.service` is a user-systemd service template for running the script automatically.
- `README.md` is the primary end-user documentation and should stay aligned with script behavior.

## Repository layout
- `pw-quantum-tuner.sh` — main executable script
- `pw-quantum-tuner.service` — systemd user service template
- `README.md` — usage, behavior, and setup documentation
- `.github/copilot-instructions.md` — existing repository-specific automation guidance

## Working expectations
- Keep changes minimal and targeted.
- Prefer Bash built-ins and standard Unix tools already used by the script.
- Do not introduce new dependencies unless absolutely necessary.
- Preserve compatibility with environments where PipeWire tools may be unavailable during validation.

## Validation
- Always run syntax validation after editing the script:
  - `bash -n ./pw-quantum-tuner.sh`
- Run ShellCheck when available:
  - `shellcheck ./pw-quantum-tuner.sh`
- If behavior changes, exercise the script with bounded manual checks:
  - `timeout 5 ./pw-quantum-tuner.sh --log-level 1`
  - `timeout 3 ./pw-quantum-tuner.sh --log-level 3`
- If the systemd unit changes, verify it:
  - `systemd-analyze verify pw-quantum-tuner.service`

## PipeWire-specific notes
- Full functional testing requires a running PipeWire server.
- In headless or CI environments, `pw-top` / `pw-metadata` connection failures are expected and should be handled gracefully.
- The tuner adjusts PipeWire metadata only; it should remain safe and non-destructive.

## Editing guidance
- Keep log-level behavior and command-line parsing consistent with the README unless intentionally updating both.
- If script behavior changes, update `README.md` and `pw-quantum-tuner.service` when relevant.
- Do not add planning or scratch files to the repository.
