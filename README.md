# SUBtl-Check

A lightweight **subdomain status checker**. Feed it a list of hosts (such as the
output of [Sub_Recon](../Sub_Recon)) and it probes each one with
[ProjectDiscovery `httpx`](https://github.com/projectdiscovery/httpx) to tell you
which subdomains are **alive** and what **HTTP status code** they return.

This is the natural next step after subdomain enumeration: a wildcard recon run can
surface hundreds of names, but most are dead. SUBtl-Check trims that list down to the
live hosts worth looking at and saves a clean **bare-hostname** `*_alive.txt` you can
hand straight to a takeover scanner like [Subdomain_Takeover](../Subdomain_Takeover).

> ⚠️ **For authorized security testing and responsible-disclosure research only.**
> Only probe hosts you own or have explicit written permission to test.

## Why `httpx`?

On Kali, the `httpx` command in `/usr/bin` is the *Python HTTP client* — not the
prober you want here. SUBtl-Check installs and uses **ProjectDiscovery httpx** (the
fast Go-based prober) and resolves the binary explicitly, so the Python one on your
`PATH` can never shadow it.

## How to use

Give the script executable permission and run it, pointing it at your input. There is
**no default/hardcoded path** — you always tell it what to check.

```bash
chmod +x subtl_check.sh

# A file of hosts (one per line):
./subtl_check.sh -L subs.txt

# A directory of subdomain lists (every *.txt in it — e.g. Sub_Recon's output):
./subtl_check.sh -d ../Sub_Recon/sub_recon

# Be patient with slow/flaky targets, and also save a breakdown file:
./subtl_check.sh -L subs.txt -s -o results.txt
```

### Options

| Flag | Description |
|------|-------------|
| `-L <hosts_file>` | Check the hosts listed in a file (one per line; blank lines / `#comments` ignored). |
| `-d <dir>` | Check every `*.txt` list in a directory. |
| `-s` | **Slow mode** — longer timeout (30s), more retries (3), gentler concurrency (15 threads). Use when targets are slow or rate-limited so live-but-slow hosts aren't falsely marked dead. |
| `-o <file>` | Also save the status-code breakdown to a single file (in addition to the per-list alive files). |
| `-h` | Show usage. |

You must provide exactly one of `-L` or `-d`.

## First run / setup

On the **first run** the script checks for its dependencies and installs anything
missing (this check runs once, then is skipped):

- **Go** — installed via your package manager if absent.
- **ProjectDiscovery httpx** — installed with `go install github.com/projectdiscovery/httpx/cmd/httpx@latest`.

To re-trigger the dependency check, delete the flag file:

```bash
rm ./.subtl-check_ran_already
```

## Output

For each input list, the live hosts are saved under `./domain_status_output/`. For an
input named `tesla_com.txt` you get:

| File | Contents |
|------|----------|
| `tesla_com_alive.txt` | The **bare hostnames** that responded, one per line (e.g. `shop.tesla.com`) — deduped and scheme-stripped, ready to pipe straight into [Subdomain_Takeover](../Subdomain_Takeover) or any other tool. |

Dead/unresolved hosts are simply left out — keeping only the live ones is automatic, so
there's no separate "prune" step. If you also pass `-o <file>`, the status-code
breakdown for every list is appended to that one file.

### On screen

The terminal shows a per-list summary: **alive / dead counts** and a **colour-coded
status-code breakdown** — each code is labelled (`200 OK`, `403 Forbidden`, `502 Bad
Gateway`, …) and the live URLs are grouped beneath it. When more than one list is
processed, a grand total is printed at the end.

```
   Status Code Breakdown:

   [200]  OK  (2 hosts)
   [200]  https://example.com
   [200]  https://github.com
```

## What counts as alive vs dead?

`httpx` marks a host **alive** if it returns *any* HTTP response — `200`, `301`, `403`,
`404`, `500` all count, because a server answered. A host is **dead** only when no HTTP
response comes back at all (DNS doesn't resolve, connection refused, or timeout). Note
that a merely *slow* host can be marked dead if it exceeds the timeout — that's what
`-s` (slow mode) is for.

## Roadmap

- **v1 (current): basic mode** — alive/dead + HTTP status code, colour-coded breakdown.
- **v2: rich enrichment** — page title, web server, content-length, detected tech stack,
  CDN, and final redirect URL, for faster triage of live hosts.
