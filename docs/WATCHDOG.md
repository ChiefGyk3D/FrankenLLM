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
| Email | `SMTP_HOST`, `SMTP_FROM`, `EMAIL_TO`, optional `SMTP_PORT`, `SMTP_SECURITY` (`starttls` or `ssl`), `SMTP_USER`, `SMTP_PASSWORD` |

Email uses Python's standard-library SMTP client, so the box does not need `sendmail` or any mail agent. Secrets are given to `curl` through a config file descriptor and never appear in `ps`.

Transport rules, enforced in the code:

- Every notification URL (Discord, ntfy, Matrix) must be a single-line `https://` URL, and `curl` is limited to https and https redirects. Plain `http://`, `file://` and other schemes are refused, so a token is never sent in the clear.
- Email is always TLS: `starttls` (default, port 587) or `ssl` (port 465). There is no cleartext mode and `SMTP_SECURITY=none` is refused. `SMTP_HOST` may contain only letters, digits, dots and hyphens, and `SMTP_PORT` must be 1 to 65535.
- A value with a control character (a line break, tab or escape) in any channel setting is refused before it can reach a `curl` config or a mail header.

## Privileges

The watchdog needs no root, so it does not have one. The installer puts the scripts in `/usr/local/lib/frankenllm` (owned by root) and the unit runs them as a systemd dynamic user with a private state directory. It never reads `config.sh`, a `.env`, or anything else from the FrankenLLM checkout, so write access to the checkout or `/opt/frankenllm` cannot be turned into code running as root. The env file stays `root:root 0600`. systemd hands it to the unit as a credential (`LoadCredential=`), and the watchdog reads it as data. Ports come from `WATCHDOG_PORTS` in that env file.

### The env file is data, never shell code

`/etc/frankenllm/watchdog.env` has one grammar, used by the timer run and by `install-watchdog.sh test` (which runs as root). It is never sourced. Each line is blank, a `#` comment, or `KEY=VALUE`:

- `KEY` must be one of the settings in this document (plus `DOPPLER_TOKEN`). Any other name, a bare command, or `export KEY=...` makes the watchdog refuse the whole file and exit non-zero.
- `VALUE` is everything after the first `=`, taken literally. No quotes, no `$variables`, no `$(commands)`. Write `WATCHDOG_PORTS=11434 11435`, not `WATCHDOG_PORTS="11434 11435"`.
- Any control character (CR, tab, escape, NUL) rejects the file, so a Windows line ending is an error rather than a silent part of a secret.
- Error messages name the line number, never the value.

### Limits

- Numeric settings (`WATCHDOG_REPEAT_HOURS` 1 to 8760, `WATCHDOG_REBOOT_GRACE_HOURS` 0 to 8760, ports 1 to 65535, at most 16 ports) must be plain decimal digits; anything else exits with status 2 before any arithmetic runs.
- `WATCHDOG_HOST` must be a loopback address (`127.x.x.x`, `localhost`, `::1`). To watch Ollama on another machine you must set `WATCHDOG_ALLOW_REMOTE_HOST=true` explicitly; this sends health probes over the network in plain HTTP, so only do it on a network you trust. The host may contain only letters, digits, dots, colons and hyphens.
- Local answers from Ollama are capped at 1 MiB; a bigger one is ignored.
- The unit runs with `MemoryMax=128M`, `CPUQuota=50%`, `TimeoutStartSec=120` and `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`. `PrivateDevices` is deliberately not set because `nvidia-smi` needs the NVIDIA device nodes.

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
| `WATCHDOG_PORTS` | `11434 11435` | Ollama ports to check |
| `WATCHDOG_HOST` | `127.0.0.1` | Where Ollama listens (loopback only) |
| `WATCHDOG_ALLOW_REMOTE_HOST` | unset | `true` to allow a non-loopback `WATCHDOG_HOST` |
| `WATCHDOG_REPEAT_HOURS` | `24` | Reminder interval |
| `WATCHDOG_REBOOT_GRACE_HOURS` | `72` | How long a pending reboot is tolerated |
| `WATCHDOG_USE_DOPPLER` | unset | `true` to fetch secrets with Doppler |

## Running it by hand

```bash
scripts/watchdog.sh --print   # run the checks, print problems, touch nothing
```

State lives in `/var/lib/frankenllm-watchdog`, one small file per active problem.

## Tests

```bash
tests/test-watchdog.sh
```

`curl`, `nvidia-smi` and `python3` are stubs and the NVIDIA version files are fakes, so the tests never touch a real server, driver or webhook. They cover each check, the alert/remind/recover cycle, delivery failure and retry, every channel at once, and that secrets never reach `curl`'s command line. They also feed hostile values (shell syntax in the env file, arithmetic expressions in numeric settings, line breaks in URLs and tokens, non-https endpoints, cleartext SMTP, remote hosts, oversized answers) and check that nothing runs and nothing is sent, and that the unit file carries its limits.

The test-only overrides (`WATCHDOG_TESTING=1` with `WATCHDOG_STATE_DIR`, `WATCHDOG_PROC_NVIDIA_VERSION`, `WATCHDOG_LIBDIR`, `WATCHDOG_REBOOT_FILE`, `WATCHDOG_NOW`, `WATCHDOG_ENV_FILE`, `WATCHDOG_DRY_RUN`, and for the installer `WATCHDOG_INSTALLED_LIB`) are honored only when `WATCHDOG_TESTING=1` is set in the process environment. The env file cannot set it, and the unit never does, so in production the environment cannot move paths, the clock or the settings file.
