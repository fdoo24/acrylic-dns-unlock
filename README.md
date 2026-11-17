# acrylic-dns-unlock

Route AI services (Gemini, ChatGPT, Claude, AI Studio, NotebookLM, Spotify, …) through a
remote **SNI exit IP** using a local DNS rewrite — **no VPN, no proxy, no TUN adapter**.
Everything else (LAN, local/RU sites) keeps going to your normal router DNS.

Built on [Acrylic DNS Proxy](https://mayakron.altervista.org/acrylic.htm) (portable, GPL),
installed as a Windows service. Inspired by an AdGuard Home `dnsrewrite` setup, reproduced
locally so any PC on the LAN works without per-device VPN.

> How it works: AI domains are resolved to the exit IP (a reverse SNI proxy abroad that
> forwards to the real services with valid certs). The client just needs DNS pointing those
> domains at the exit. Non-AI queries are forwarded to your upstream DNS unchanged.

---

## Install (one command)

Open **PowerShell** (any window — the script self-elevates via UAC) and run:

```powershell
irm https://raw.githubusercontent.com/fdoo24/acrylic-dns-unlock/main/install.ps1 | iex
```

Or clone and run locally:

```powershell
git clone https://github.com/fdoo24/acrylic-dns-unlock
cd acrylic-dns-unlock
.\install.ps1
```

The installer:
1. Downloads Acrylic + `domains.txt` (or uses the local clone's copies).
2. Auto-detects the active adapter and its current DNS → uses it as upstream.
3. Backs up current DNS to `acrylic-backup.json`.
4. Writes `AcrylicConfiguration.ini` (upstream = router, bind `127.0.0.1` / `::1`).
5. Generates wildcard hosts (`IP >domain` = `domain` + `*.domain`) from `domains.txt`.
6. Installs + starts the `AcrylicDNSProxySvc` service (Automatic).
7. Points the adapter DNS at `127.0.0.1` / `::1`, flushes cache.
8. Verifies `gemini.google.com` resolves to the exit IP.

### Options

```powershell
.\install.ps1 -ExitIP 1.2.3.4 -UpstreamDNS 192.168.1.1 -InstallDir D:\AcrylicDNS
```

| Param | Default | Meaning |
|---|---|---|
| `-ExitIP` | `179.254.143.17` | Remote exit IP for AI domains (overrides per-line IPs). |
| `-UpstreamDNS` | auto | DNS for all non-rewritten queries (router/ISP). |
| `-InstallDir` | `%LOCALAPPDATA%\AcrylicDNS` | Install location. |
| `-TestDomain` | `gemini.google.com` | Domain used for the post-install check. |

---

## Recovery — if the exit / DNS server dies

Return DNS to DHCP/router immediately (Acrylic service stays installed, traffic bypasses it):

```powershell
.\restore-dns.ps1
# or remotely:
irm https://raw.githubusercontent.com/fdoo24/acrylic-dns-unlock/main/restore-dns.ps1 | iex
```

Uses `acrylic-backup.json` when present, otherwise resets every adapter pointing at `127.0.0.1`.

## Change the exit IP / refresh domains

```powershell
.\update-ip.ps1 -NewIP 1.2.3.4
# or regenerate from your AdGuard gist:
.\update-ip.ps1 -DomainsUrl https://gist.githubusercontent.com/<you>/<id>/raw/domains.txt
```

## Uninstall

```powershell
.\uninstall.ps1            # restore DNS + remove service + delete files
.\uninstall.ps1 -KeepFiles # restore DNS + remove service, keep files
```

---

## domains.txt format

AdGuard-style rewrite lines (the installer parses these):

```
||gemini.google.com^$dnsrewrite=179.254.143.17
||openai.com^$dnsrewrite=179.254.143.17
```

Each becomes `179.254.143.17 >gemini.google.com` in `AcrylicHosts.txt`
(`>domain` covers the domain **and all subdomains**). Edit the list and re-run
`update-ip.ps1 -DomainsUrl …`, or edit `AcrylicHosts.txt` directly and restart the service.

---

## Verify manually

```powershell
Resolve-DnsName gemini.google.com -Server 127.0.0.1   # -> exit IP
Resolve-DnsName ya.ru -Server 127.0.0.1               # -> real IP (forwarded)
Get-Service AcrylicDNSProxySvc                        # Running / Automatic
ssh fd@192.168.0.127                                  # LAN still works
```

## Gotchas

- **IPv6 bypass**: if the adapter has a global IPv6 address and a foreign IPv6 DNS, queries
  can skip Acrylic. The installer binds `::1` too; remove foreign IPv6 DNS if needed.
- **HTTP/2 coalescing (421)**: browsers may reuse a connection across rewritten domains that
  share the exit IP; usually fine because the exit is a passthrough SNI proxy.
- `>google.com` redirects **all** Google subdomains. Keep the list scoped to what you need.
- The exit IP and domain list are public (same as the source gist). No secrets live here.

---

## Future: Linux server version (notes, not implemented)

Goal: run the same DNS-rewrite on a Linux box (e.g. the tender-robots server) so bots reach
OpenRouter / Gemini directly without the dead xray tunnel.

- **dnsmasq**: `address=/gemini.google.com/179.254.143.17` (covers subdomains),
  `address=/openai.com/…`, plus `server=<upstream>` for everything else;
  point `/etc/resolv.conf` (or the bot's resolver) at `127.0.0.1`.
- **CoreDNS** alternative: `template` / `rewrite` plugin mapping AI domains to the exit IP,
  `forward . <upstream>`.
- **OpenRouter**: add `openrouter.ai` (and `*.openrouter.ai`) to the exit's SNI-proxy config
  **and** to the domain list — it is not in the current gist. Then set bot `cfg.proxy=""`
  (direct) and let DNS do the routing.
- Keep production untouched until explicitly approved; test in the sandbox first.

## License

Installer scripts: MIT (see `LICENSE`). Acrylic DNS Proxy is GPL — bundled unmodified in
`vendor/Acrylic-Portable.zip`; see its `License.txt` / `ReadMe.txt` after extraction.