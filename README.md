# a1-hunter — beat "Out of host capacity" on Oracle Cloud Always Free

[![shellcheck](https://github.com/deadpoolrulesmarvel1-svg/oracle-free-tier-instance-hunter/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/deadpoolrulesmarvel1-svg/oracle-free-tier-instance-hunter/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![shell](https://img.shields.io/badge/shell-bash-4EAA25.svg)](a1-hunter.sh)

**A single bash script that retries Oracle Cloud instance creation until an Always Free
ARM VM (`VM.Standard.A1.Flex`, 2 OCPU / 12 GB) is actually yours.** No Python, no Docker,
no dependencies beyond the OCI CLI. Runs unattended under systemd for days or weeks.

If you have ever seen this and given up, this repo is for you:

```
ServiceError: InternalError: Out of host capacity.
```

> **Confirmed working.** This logic has obtained a 2 OCPU / 12 GB `VM.Standard.A1.Flex`
> instance on a real Always Free account after **about a day** of unattended retrying.
> Your mileage will vary enormously by region — see the FAQ.

---

## What "Out of host capacity" actually means

**It means Oracle has no free ARM hosts in your home region at that moment.** It is not a
misconfiguration, not a quota problem, and not something you can fix by changing your
request. Oracle's own guidance is that it is a temporary shortage that "might take several
days" to clear. In heavily contended regions — India, and other popular ones — it can take
**weeks**, and it will only clear the instant another user releases a host.

Whoever is asking at that instant wins. That is the entire game, and it is why a script
beats clicking Create.

## Quick start

```bash
git clone https://github.com/deadpoolrulesmarvel1-svg/oracle-free-tier-instance-hunter.git
cd oracle-free-tier-instance-hunter
DRY_RUN=1 ./a1-hunter.sh     # check what it resolved
./a1-hunter.sh               # then let it run
```

That's it. Compartment, availability domains, subnet and image are all discovered from
your existing `~/.oci/config` — most people need no configuration at all.

No VCN yet? Let it build one:

```bash
CREATE_NETWORK=1 ./a1-hunter.sh
```

## Requirements

- [OCI CLI](https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm), configured with `oci setup config`
- An SSH public key (`ssh-keygen -t ed25519` if you have none)
- `bash` and `curl`. `jq` only if you want webhook notifications.

Works on Linux and macOS.

---

## FAQ

### How long does it take to get an Oracle free ARM instance?

**Anywhere from minutes to weeks, entirely depending on your home region.** Well-supplied
regions often provision on the first or second try; **about a day** is a realistic figure
for a moderately contended one, and that is what this script took on the account it was
built for. Heavily contended ones can refuse
thousands of consecutive attempts before a host frees up. There is no queue and no
priority — you are racing everyone else's retry loop, and the winner is whoever happens to
be asking at the moment a host is released.

This is why an unattended script beats clicking Create: the window is seconds long and
usually happens while you are asleep.

### Does retrying faster improve my odds?

**No — and this is measured, not guessed.** Oracle's rate limiter appears to adapt to
sustained request rates, so a tighter interval buys more API calls but a *smaller* number
of real capacity checks. Same account, same region, two pacing settings:

| Interval | Real capacity checks | Rate-limited (wasted) | Share wasted |
|---|---|---|---|
| **120s** | **353/day** | 7/day | 2% |
| 60s | 282/day | 160/day | **36%** |

Halving the interval produced **20% fewer real attempts per day**. At 60s, more than a
third of every call was rejected before it could even check for capacity, and each
rejection triggered a backoff longer than the interval saved.

**120 seconds is the default here for that reason.** If you want to experiment, measure
the ratio rather than the raw attempt count:

```bash
grep -c "Out of host capacity" a1-hunter.log   # real checks
grep -c "rate limited" a1-hunter.log           # wasted calls
```

### Can I get free capacity in a different region?

**No.** Always Free resources exist only in your tenancy's home region — *"You must create
the Always Free compute instances in your home region."* Subscribing to another region
does not give you free capacity there; anything you create is billed at normal rates.
([Oracle docs](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm))

### Should I specify a fault domain?

**No — leave it unset.** Oracle's own error message suggests trying without one. Pinning a
fault domain restricts you to a subset of hosts for no benefit. This script never sends one.

### How much free ARM compute does Oracle actually give?

**2 OCPU and 12 GB of memory**, as of 15 June 2026 — 1,500 OCPU-hours plus 9,000 GB-hours
per month. This was **halved** from the previous 4 OCPU / 24 GB with no announcement;
Oracle updated the documentation and users discovered it when instances stopped fitting.
Enforcement of the lower limit began 18 August 2026.
([Oracle docs](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) ·
[InfoQ](https://www.infoq.com/news/2026/07/oracle-cloud-free-tier-limits/))

You also get, separately from the ARM allowance: **two `VM.Standard.E2.1.Micro` x86
instances** (1/8 OCPU, 1 GB each), 200 GB of block storage, and 10 TB/month of egress.

### Is there a way to get one immediately?

**Yes — pay for it.** Paid A1 capacity is a separate and far less contended pool, and
upgrading to pay-as-you-go generally gets you an instance straight away. Whether PAYG
accounts keep the older 4 OCPU / 24 GB free allowance is
[disputed](https://www.infoq.com/news/2026/07/oracle-cloud-free-tier-limits/): Oracle's
docs say all tenancies get the reduced allowance, while some support emails have said
otherwise. Don't rely on it.

The free alternative that is almost always available today is `VM.Standard.E2.1.Micro`:

```bash
SHAPE=VM.Standard.E2.1.Micro ./a1-hunter.sh
```

### Will this create duplicate instances?

**No.** Before every attempt it lists non-terminated instances in the compartment and
exits if one already exists. Restarting it, or running it after it succeeded, is safe.

### Does it downgrade to a smaller shape if the full size isn't available?

**Never.** If you ask for 2 OCPU / 12 GB you get that or nothing. A smaller VM is a
permanent consolation prize for a temporary shortage — and in a starved region you may not
be able to resize later.

---

## Configuration

Everything is optional. Copy `config.example.env` to `config.env` to change any of it.

| Variable | Default | What it does |
|---|---|---|
| `OCI_PROFILE` | `DEFAULT` | Profile in `~/.oci/config` |
| `OCI_BIN` | `oci` | Path to the CLI (useful for a venv install) |
| `SHAPE` | `VM.Standard.A1.Flex` | Or `VM.Standard.E2.1.Micro` for x86 |
| `OCPUS` / `MEMORY_GB` | `2` / `12` | Ignored for fixed shapes |
| `BOOT_VOLUME_GB` | `50` | Free tier gives 200 GB total |
| `SSH_KEY_FILE` | `~/.ssh/id_rsa.pub` | Log in as `ubuntu` |
| `INTERVAL` | `120` | Seconds between attempts — see the FAQ before lowering |
| `MAX_BACKOFF` | `900` | Ceiling for rate-limit backoff |
| `DEADLINE_DAYS` | `0` | `0` = run forever |
| `DRY_RUN` | `0` | `1` = resolve config, print, exit |
| `CREATE_NETWORK` | `0` | `1` = build a VCN + public subnet if none exists |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | — | Ping you when it lands |
| `WEBHOOK_URL` | — | Discord/Slack-style webhook |
| `COMPARTMENT_ID`, `AVAILABILITY_DOMAINS`, `SUBNET_ID`, `IMAGE_ID` | auto | Override discovery |

## Run it somewhere that stays awake

A laptop that sleeps is a laptop that is not retrying, and the race is won in the seconds
after a host frees up. Put it on something always-on — a Raspberry Pi, a cheap VPS, or a
VM you already own in another Oracle account:

```bash
sudo cp a1-hunter.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now a1-hunter
journalctl -u a1-hunter -f
```

`enable` is the important word — see below.

## Lessons learned the hard way

Things that cost real time to discover, kept here so they cost you none.

**Use a supervisor, not `nohup`.** A VM running this was rebooted by its host after nine
weeks of uptime. The loop had been backgrounded with `nohup` and simply never came back —
everything else on the box was under Docker or systemd and recovered by itself. Use the
unit file and `systemctl enable` it.

**Don't check liveness with `pgrep -f a1-hunter.sh` over SSH.** The pattern matches the SSH
command string itself, so it reports "running" whether or not anything is. That false
positive hid the outage above for half an hour. Use `systemctl is-active a1-hunter`.

**Attempt numbers restart with the process.** Count across restarts by grepping the log:

```bash
grep -c "Out of host capacity" a1-hunter.log
```

**Run exactly one hunter per tenancy.** Two loops racing each other produce
`TooManyRequests` and fewer real attempts than one loop alone.

**Think hard before terminating a free instance you already have.** In a starved region,
giving one up means joining the back of this queue to get it back — and since the June 2026
halving, an older 4 OCPU / 24 GB instance cannot be recreated at its original size once
destroyed.

## Prior art

| Project | Language | Approach |
|---|---|---|
| [oracle-freetier-instance-creation](https://github.com/mohankumarpaluru/oracle-freetier-instance-creation) | Python | Feature-rich, Gmail/Discord/Telegram notifications |
| [oci-instance-creator](https://github.com/mowirth/oci-instance-creator) | Go | Docker-friendly, rotates zones |
| [oracle-nabber](https://github.com/OverlyDev/oracle-nabber) | Python | Long-running nabber |
| **a1-hunter** | bash | Zero-dependency single file, auto-discovery, systemd-first |

All solve the same problem. Pick whichever fits your box; this one exists for people who
want to drop one script onto a server they already have and forget about it.

## Contributing

Issues and PRs welcome — especially reports of how long it took in your region, which is
the data nobody publishes. Run `shellcheck a1-hunter.sh` before submitting.

## License

MIT — see [LICENSE](LICENSE).
