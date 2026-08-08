# Security audit — 2026-08-06

Point-in-time audit of the live box, run because
[`security-architecture.md`](security-architecture.md) turned out to describe
an architecture retired in March 2026 and its claims read as false today.

**Scope:** internet-facing exposure and credential hygiene. Not a code audit.

**Headline:** one critical exposure found and closed during the audit. The
rest is in decent shape — SSH and service bindings are genuinely well
configured.

---

## Why the old document reads false

It is not a regression. `security-architecture.md` is dated **2025-01-13** and
describes the ngrok era: port 22 the only opening, all public traffic through
an ngrok tunnel to nginx on `127.0.0.1:8080`. That was accurate when written.

| When | What |
|---|---|
| 2025-01-13 | Doc written. ngrok-only. Claims true. |
| **2026-03-15 13:59** | `apt install -y caddy` — earliest `Caddyfile.bak` carries the same minute |
| 2026-04-05 / 04-08 | Caddyfile revisions as real hostnames come online |
| 2026-07-07 | `Caddyfile.pre-cutover` — marketing takes the apex |
| 2026-07-14 11:45:00 | UFW rules last rewritten (v4 + v6, same second) |
| 2026-07-14 11:47:51 | Reboot |

**The claims died on 2026-03-15.** Caddy cannot complete an ACME challenge or
serve HTTPS on a public domain without inbound 80/443, so the moment the box
started serving `uzelhub.com`, "only port 22" was over. Nothing failed to
persist — UFW rules survived the reboot exactly as designed, which is why
they are still present.

The 11:45 rewrite three minutes before the reboot is unexplained but almost
certainly a reload; `safe-reboot.sh` contains no firewall commands and the
journal shows no rule-change events. The ports had already been open for four
months.

---

## Findings

### 🔴 CRITICAL — `.git` of a private repo publicly dumpable — **FIXED**

`studio.uzelhub.com` serves `/opt/uzelhub-web` — the **repository root** — so
the `.git` directory was reachable over the internet.

```
200  https://studio.uzelhub.com/.git/config
200  https://studio.uzelhub.com/.git/HEAD
200  https://studio.uzelhub.com/.git/index
200  https://studio.uzelhub.com/.git/packed-refs
```

With `index` and `packed-refs` readable, every object is enumerable and
fetchable — the entire **private** repository, including full history, could
be reconstructed by anyone. History matters more than the working tree: it
carries everything ever committed and later removed.

`.git/config` was already handing out the GitHub remote
(`git@github.com:dshorter/uzelhub-web.git`).

**Fixed during the audit** — `chmod 750 /opt/uzelhub-web/.git`. Caddy runs as
`caddy` (groups: `caddy`, `www-data`), not `claude`, so dropping the
world-read bit is sufficient. Now returns 403. Verified: git operations
unaffected, all four sites still 200.

**Durable fix still wanted** — permissions are the wrong layer for this, and a
future `chmod -R` re-opens it. Caddy is operator-only, so paste into the
`studio.uzelhub.com` block:

```caddy
    # The docroot is a git working tree; never serve its metadata.
    @dotfiles path /.* /*/.*
    handle @dotfiles {
        respond 404
    }
```

Then `sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy`.

**Not affected:** apex, predictor, blog and the desk all keep `.git` above
their docroot. Studio was uniquely exposed because it serves the repo root.

---

### 🟠 HIGH — live secrets inside a public docroot

`/opt/uzelhub-web/services/uzella-proxy/.env` sits **inside the studio
docroot** and holds:

```
ANTHROPIC_API_KEY
CONTACT_DB_URL
CONTACT_IP_SALT
ASK_DB_URL
```

It currently returns 403 — but only because the file happens to be `600
claude:claude` and Caddy cannot read it. **The only thing between an Anthropic
API key and the public internet is one permission bit.** A single careless
`chmod 644`, or a `chmod -R` over the tree, publishes it.

Good news: it is gitignored and has never been tracked.

**Fix:** move the file out of the docroot — `/etc/uzella-proxy/.env`, referenced
from the unit as `EnvironmentFile=` — or stop serving the repo root from
studio. The dotfile rule above also covers it, but defence in depth belongs
here given what leaks.

---

### 🟠 HIGH — unpatched kernel and libc, reboot pending 3½ weeks

```
/var/run/reboot-required : YES
  linux-image-6.8.0-136-generic
  linux-image-6.8.0-137-generic
  linux-base, libc6
```

Running kernel is **6.8.0-134**; two newer images are installed and waiting.
Uptime 3 weeks 3 days. `libc6` is pending too, which means long-running
processes hold the old library until restarted.

`safe-reboot.sh` exists and the 2026-07-14 reboot went cleanly, so the
mechanism is proven.

---

### 🟡 MEDIUM — no brute-force protection on an internet-facing SSH port

**27,726** failed SSH attempts in the last 7 days — roughly 4,000/day.
`fail2ban` is **inactive**.

Password auth is off, so these cannot succeed. The cost is unbounded log
growth, journal noise that buries real events, and wasted cycles. `fail2ban`
with the `sshd` jail turns this off in one package.

---

### 🟡 MEDIUM — working files served publicly from the studio docroot

Serving the repo root means non-page files are fetchable:

| Path | |
|---|---|
| `/uzella.zip` | 19 KB archive |
| `/mktg-notes.txt` | 20 KB — **`VOICE.md` itself flags this as needing a scrub before the repo could go public** |
| `/editing-notes.md`, `/BACKLOG.md` | working notes |
| `/services/uzella-proxy/*.js`, `*.json` | service source |

Studio already 404s `/marketing/*`, so the fix pattern exists — it just needs
extending, or the docroot narrowing to what is meant to be published.

---

### 🟡 MEDIUM — doctrine and data files public on the apex

The apex docroot is `/opt/uzelhub-web/marketing`, so these are all live:

```
/VOICE.md  /VOICE-LEDGER.md  /CHARTER.md  /TODO.md
/CONCEPT-INVENTORY.md  /promotion-survey.yaml
/data/products.json  (5 copyDraft review notes)
```

`VOICE.md` contains the autopsy of old copy and a candid section on which work
is *not* publicly verifiable. `VOICE-LEDGER.md` carries editorial judgements
including one calling a live receipt's claim likely false. None of this is
catastrophic; all of it was written expecting privacy.

---

### 🔵 LOW — vestigial ngrok tunnel still registered

`https://agents-platform.ngrok.io → http://web-server:80` is still registered
and answering (502 — the `web-server` container exists but is in `Created`
state). A tunnel bypasses UFW, Cloudflare, and any future Zero Trust policy —
a different edge entirely.

Not an open door today; an unlatched one, a `docker start` away from serving.
Subscription has been dropped, but a running agent does not necessarily
disconnect on a billing change. `docker stop ngrok` is definitive.

---

### 🔵 INFO — origin reachable by IP

UFW permits 80/443 from anywhere, which is *correct* for a public web server —
Cloudflare's edge connects from arbitrary addresses. DNS does not leak the
origin (all four hostnames resolve to Cloudflare only; origin is
178.156.207.242), but Hetzner ranges are swept continuously, so obscurity is
not the control.

Consequence for the planned Zero Trust work: **Access is enforced at
Cloudflare's edge, not at the origin.** Keep the capability-URL token in the
desk path until the origin is either restricted to Cloudflare's CIDRs or moved
behind a Cloudflare Tunnel. A Tunnel would also make the retired document's
claims literally true again — same shape as the ngrok design, no inbound
ports — which is the tidiest end state.

Hetzner's cloud firewall could not be inspected; `hcloud` is not installed and
it is console-side.

---

## What passes

- **SSH hardening** — `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PermitRootLogin prohibit-password`, pubkey only. This is why 27k failed
  attempts are noise rather than an incident.
- **Service bindings** — every container on loopback:
  `ghost 127.0.0.1:2368`, `hvac-postgres 127.0.0.1:5432`, `n8n 127.0.0.1:5678`,
  `ngrok 127.0.0.1:4040`, `ghost-mysql` container-internal. **No `0.0.0.0`
  publications**, so the classic Docker-bypasses-UFW hole is not present.
- **UFW active and enabled**, default-deny inbound, exactly three ports.
- **Secrets never committed** — `.env` is gitignored and untracked.
- **`.git` not exposed** on apex, predictor, blog or the desk.
- **TLS** terminated at Cloudflare and Caddy; all four hostnames proxied.

---

## Priority order

1. **Paste the Caddy dotfile rule** — makes the critical fix durable rather
   than permission-dependent (operator, 2 min)
2. **Move `.env` out of the docroot** (operator, 10 min)
3. **`safe-reboot`** — kernel + libc pending 3½ weeks
4. **`apt install fail2ban`** — kills 4,000 daily probes
5. **`docker stop ngrok`** — remove the unmonitored entrance
6. **Narrow the studio docroot** or extend its 404 rules
7. **Amend `security-architecture.md`** — dated block, old text kept visible
8. **Cloudflare Tunnel** — own piece of work; restores the original property
