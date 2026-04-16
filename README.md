# Cloudflare DDNS Updater
![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Bash](https://img.shields.io/badge/Language-Bash-green.svg)
![Systemd](https://img.shields.io/badge/Scheduler-Systemd-lightgrey.svg)

A production-ready, highly robust Dynamic DNS (DDNS) updater for Cloudflare. Designed specifically for headless VPS and home server environments running Ubuntu/Debian. 

It periodically validates your public IPv4 address using multiple redundant endpoints and synchronizes it with a Cloudflare DNS record using least-privilege API access.

## ✨ Key Features
- **Idempotent API Interaction**: Leverages local state caching to guarantee Cloudflare API calls are *only* made when an IP change actually occurs.
- **Failover IP Detection**: Queries multiple public IP providers (`ipify`, `ifconfig.me`, etc.) with strict IPv4 regex validation.
- **Auto-Provisioning**: Detects missing DNS records and gracefully creates them via `POST` if a `PUT` update isn't possible.
- **Telegram Webhooks**: Native, payload-encoded URL integration for real-time state-change alerting.
- **Modern Systemd Integration**: Bypasses the limitations of `cron` using precision `systemd` timers and native `journald` log routing.

## 📂 Repository Structure
```text
.
├── ddns-update.sh        # Core worker script
├── install.sh            # Interactive deployment script
├── uninstall.sh          # Cleanup script
├── .env.example          # Template for configuration
└── systemd/              # Systemd unit templates
