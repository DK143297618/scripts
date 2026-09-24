# scripts

One-click install/update scripts for VPS (Debian).

| Script | What it does | Run |
|---|---|---|
| [install-usque-warp.sh](install-usque-warp.sh) | Cloudflare WARP via usque — MASQUE tunnel + IPv6 egress | `curl -fsSL https://raw.githubusercontent.com/DK143297618/scripts/main/install-usque-warp.sh \| bash` |
| [update-smartdns.sh](update-smartdns.sh) | Install/update pymumu smartdns (Web UI build) from GitHub releases — Debian/Ubuntu, amd64/arm64 | `curl -fsSL https://raw.githubusercontent.com/DK143297618/scripts/main/update-smartdns.sh \| bash` |
| [realm-manager.sh](realm-manager.sh) | Realm port-forward manager — rules carry **remarks**, musl build via `docker.mmzs.space`, sha256 verified against GitHub digest | `curl -fsSL https://raw.githubusercontent.com/DK143297618/scripts/main/realm-manager.sh -o realm-manager.sh && chmod +x realm-manager.sh && ./realm-manager.sh` |
