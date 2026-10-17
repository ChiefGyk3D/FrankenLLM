# Watchdog alerts

The boot-time auto-fix looks at the GPU once per boot. That left a gap: an unattended upgrade of the NVIDIA packages in the middle of an uptime leaves the kernel module on the old version and the userland libraries on the new one. `nvidia-smi` then fails with "Driver/library version mismatch", Ollama starts without CUDA, logs `inference compute id=cpu`, and every model quietly runs on the CPU. Nothing is down, so nothing complains. In the case this was built for, requests went from about half a second to over a minute and RAM filled up with weights and KV cache that belonged in VRAM, for eight days, with no notice.

The watchdog is a systemd timer that checks for exactly that and pushes an alert.

## What it checks

Every five minutes:

| Key | Problem | What you do |
|---|---|---|
| `gpu-nvml` | `nvidia-smi` cannot talk to the driver | Reboot to reload the driver |
| `gpu-skew` | The loaded kernel module version differs from the userland libraries | Reboot |
| `gpu-cpu-<port>` | A loaded model has no VRAM, so it is running on the CPU | Check `nvidia-smi` and the Ollama startup log |
| `ollama-<port>` | An Ollama instance does not answer | `systemctl status ollama-gpu*` |
| `reboot-pending` | `/run/reboot-required` has been there longer than the grace period | Reboot when convenient |

Each alert says what is wrong in plain words and what to do about it.

## How it alerts

- One message when a problem appears.
- A reminder every `WATCHDOG_REPEAT_HOURS` (default 24) while it lasts.
- One message when it clears, with how long it was broken.
- Several problems in the same run share one message.
- If no channel can deliver, nothing is recorded as sent. The next run tries again, and the unit exits non-zero so `systemctl --failed` shows it.

Alerts use the label in `WATCHDOG_LABEL` (default `FrankenLLM`), never a hostname.

## Channels

Each channel turns on when its variables are set. Use as many as you like.

| Channel | Variables |
|---|---|
| Discord | `DISCORD_WEBHOOK_URL` |
| ntfy | `NTFY_URL`, optional `NTFY_TOKEN` |
| Matrix | `MATRIX_HOMESERVER`, `MATRIX_ACCESS_TOKEN`, `MATRIX_ROOM_ID` |
| Email | `SMTP_HOST`, `SMTP_FROM`, `EMAIL_TO`, optional `SMTP_PORT`, `SMTP_SECURITY` (`starttls`, `ssl`, `none`), `SMTP_USER`, `SMTP_PASSWORD` |

Email uses Python's standard-library SMTP client, so the box does not need `sendmail` or any mail agent. Secrets are given to `curl` through a config file descriptor and never appear in `ps`.

## Install

```bash
sudo scripts/install-watchdog.sh install   # needs curl, jq, flock, nvidia-smi
sudoedit /etc/frankenllm/watchdog.env      # fill in at least one channel
sudo scripts/install-watchdog.sh test      # sends a test alert through every channel
sudo scripts/install-watchdog.sh status    # timer state and the checks right now
```

### Secrets from Doppler

Keep the channel values in a Doppler config instead of the env file: put only `DOPPLER_TOKEN` and `WATCHDOG_USE_DOPPLER=true` in `/etc/frankenllm/watchdog.env`, and the watchdog re-runs itself under `doppler run --`.

### Stop the driver drifting again

```bash
sudo scripts/install-watchdog.sh hold-nvidia     # apt-mark hold every installed NVIDIA package
sudo scripts/install-watchdog.sh unhold-nvidia   # before a deliberate driver upgrade
```

The hold is what prevents the drift. The watchdog is what tells you if something else causes it.

## Settings

| Variable | Default | |
|---|---|---|
| `WATCHDOG_LABEL` | `FrankenLLM` | Name shown in alerts |
| `WATCHDOG_PORTS` | from `FRANKEN_GPU*_PORT`, else `11434 11435` | Ollama ports to check |
| `WATCHDOG_HOST` | `127.0.0.1` | Where Ollama listens |
| `WATCHDOG_REPEAT_HOURS` | `24` | Reminder interval |
| `WATCHDOG_REBOOT_GRACE_HOURS` | `72` | How long a pending reboot is tolerated |
| `WATCHDOG_USE_DOPPLER` | unset | `true` to fetch secrets with Doppler |

## Running it by hand

```bash
scripts/watchdog.sh --print   # run the checks, print problems, touch nothing
```

State lives in `/var/lib/frankenllm/watchdog`, one small file per active problem.

## Tests

```bash
tests/test-watchdog.sh
```

`curl`, `nvidia-smi` and `python3` are stubs and the NVIDIA version files are fakes, so the tests never touch a real server, driver or webhook. They cover each check, the alert/remind/recover cycle, delivery failure and retry, every channel at once, and that secrets never reach `curl`'s command line.
