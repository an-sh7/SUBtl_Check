# SUBtl-Check

A lightweight **subdomain status checker**. Feed it a list of hosts (such as the
output of [Sub_Recon](../Sub_Recon)) and it probes each one with
[ProjectDiscovery `httpx`](https://github.com/projectdiscovery/httpx) to tell you
which subdomains are **alive** and what **HTTP status code** they return.

This is the natural next step after subdomain enumeration: a wildcard recon run can
surface hundreds of names, but most are dead. SUBtl-Check trims that list down to the
hosts actually worth looking at (and produces a clean `*_alive.txt` you can hand to a
takeover scanner like [Subdomain_Takeover](../Subdomain_Takeover)).

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
```

### Options

| Flag | Description |
|------|-------------|
| `-L <hosts_file>` | Check the hosts listed in a file (one per line; blank lines / `#comments` ignored). |
| `-d <dir>` | Check every `*.txt` list in a directory. |
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

Results are written under `./subtl_check/`, one set of files per input list. For an
input named `tesla_com.txt` you get:

| File | Contents |
|------|----------|
| `tesla_com_status.txt` | Every host with its probe result and status code, e.g. `https://shop.tesla.com [200] [SUCCESS]`. Dead hosts are recorded too (`[FAILED]`). |
| `tesla_com_alive.txt` | Just the URLs that responded — ready to pipe into the next tool. |

The script also prints a per-list summary to the terminal: **alive / dead counts** and a
**status-code breakdown** (how many hosts returned 200, 301, 403, …), plus a grand total
when more than one list is processed.

## Roadmap

- **v1 (current): basic mode** — alive/dead + HTTP status code.
- **v2: rich enrichment** — page title, web server, content-length, detected tech stack,
  CDN, and final redirect URL, for faster triage of live hosts.
