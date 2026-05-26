# PrintBack — what we do with the data

Plain-language description of the data architecture. Purpose: anyone (you, a
lawyer, a partner, a hypothetical auditor) gets a clear 5-minute picture of what
the system collects, where it stores it, what it uses it for, and what it
deliberately doesn't do. No "everything is fine" salesmanship — WiFi sniffing
and probe-tracking sits on a regulatory edge by nature. This file is descriptive,
the lawyer takes it and drafts whatever downstream documents are needed.

## What we collect

The ESP32 listens to WiFi probe requests — broadcast frames every phone with WiFi
enabled emits every few tens of seconds looking for known networks. From each
frame we extract:

- **fingerprint** — 8-byte hash of the Information Elements (IEs) in the frame.
  Stable across observations of the same device configuration, **but not a MAC**
  and does not identify a person. Computed on the ESP32 itself; the host never
  sees the raw IE bytes.
- **source MAC** — the sender's MAC address. Modern phones randomize it, but we
  store whatever arrives.
- **RSSI** — signal strength in dBm. A rough proxy for distance.
- **channel** (1 / 6 / 11) — purely diagnostic.
- **timestamp** — ESP32 monotonic clock + host wall clock at receipt.

Nothing else. We don't read SSID names, we don't look at frame payload, we don't
touch any frames outside management/probe-request subtype.

## Why we collect it

Business goal: **footfall statistics and returning-customer analytics** for the
operator's premises. Concrete questions we want to answer:

- how many unique devices today, yesterday, this week
- what fraction are returning (seen before) vs new
- frequency segmentation (one-off visitor vs 2-3x vs regular vs heavy)
- hourly traffic distribution (when's the peak)
- trend over time (is footfall growing or shrinking)

What is **not** the goal: tracking a specific individual, matching to
transactions, sending notifications, integrating with CCTV. This architecture
literally can't do those things — see "What the system doesn't do" below.

This is a well-established category of tool. Spaceti, FootfallCam, Brickstream
and similar vendors run essentially the same approach at scale in Polish
shopping galleries. It's not novel territory.

## How the data is stored

One SQLite file on the operator's local computer (`%APPDATA%\PrintBack\printback.db`).
No server, no cloud, no network calls. Three tiers with decreasing detail:

**L1 — raw observations (30 days)**
One row per probe — MAC, RSSI, channel, timestamp, fingerprint. This is the most
privacy-sensitive layer (it contains MAC), so retention is short. After 30 days
the row is automatically deleted from disk.

**L2 — daily visits (365 days)**
A background job aggregates each completed day: one row per fingerprint × date,
with first-seen, last-seen, observation count, distinct active hours.
**No MAC, no RSSI.** Returning vs new analytics come from this tier. Rows expire
after 365 days.

**L3 — daily totals (unlimited)**
Same aggregation step also produces one row per date with totals: unique count,
new, returning, hourly histogram, channel distribution. **No identifiers at all.**
This is anonymous statistics, no longer personal data, kept forever for
year-over-year trends.

The pattern: the further back in history, the less granular. MAC lives 30 days.
Fingerprint up to a year. Pure counts forever. Each tier holds only what's
genuinely needed for its use case.

## What it's used for

- **Stats tab**: active devices right now, today vs yesterday, % new/returning,
  frequency segments, 30-day trend
- **Debug tab**: live RSSI, channel distribution, active devices list (sortable
  by signal — "who's closest right now"), raw event log — this is for the
  operator to verify the system is working
- **Whitelist**: manually or automatically excludes from stats devices that
  obviously aren't customers (staff phones, the router, the shop next door)

Everything local, on one operator screen. Nothing leaves that computer.

## Auto-whitelist

The system spots "obviously-not-a-customer" devices: if a fingerprint appears
in 6+ distinct hours within an 8-hour rolling window (i.e., something is sitting
on premises for most of a shift), it's auto-added to the whitelist and stops
counting toward statistics. The operator sees this in the Debug tab and can
un-flag false positives. This is data minimisation — we don't process the data
of devices that obviously aren't part of the use case.

## What the system doesn't do (architecture-enforced)

These constraints are baked into the code, not just declared:

- **No network calls** — the app has no HTTP/MQTT/anything outbound. Data
  physically has no way to leave the operator's computer.
- **No crosslinking** — the schema has no columns or interfaces to join a
  fingerprint with anything external (CRM, loyalty, POS, CCTV). The operator
  can't do this in one click.
- **No raw L1 export** — there's no "export everything including MAC to CSV"
  button. Trivial to add, deliberately omitted.
- **Hash computed on the ESP32** — raw IE bytes never reach the host. The host
  receives a pseudonym, not the source material.
- **Auto-purge** — retention isn't "up to the operator", it's enforced by the
  hourly maintenance job. Rows delete themselves after 30 / 365 days.
- **Daily backup** — atomic `VACUUM INTO` snapshot, rotated to the last 7. The
  backups inherit the same retention.

## Honest precision limits

- iOS 14+ and Android 10+ randomize the MAC in probe requests every few minutes.
  The IE-fingerprint is more stable, but some phones randomize aggressively
  enough that the same returning customer can look like 2-3 different devices.
  **The "% returning" number underestimates by something like 10-30%.**
- The sniffer picks up signal within a radius — in a shopping passage it can
  count people from the shop next door. The RSSI floor (default -85 dBm) filters
  most of that out, but not perfectly.
- This is **trend estimation**, not precise measurement. Present it to the boss
  / partner as "traffic up ~15%", never "exactly 142 customers walked in".

## Configuration

`%APPDATA%\PrintBack\config.json`. All thresholds tunable here:

```json
{
  "l1_retention_days": 30,
  "l2_retention_days": 365,
  "returning_window_days": 30,
  "auto_wl_window_hours": 8,
  "auto_wl_min_distinct_hours": 6,
  "auto_wl_min_observations": 30,
  "backup_keep_days": 7,
  "locale": "pl"
}
```

Defaults are intended as ceilings. Shortening retention is always safe.
Extending L1 beyond 30 days or L2 beyond 365 is a deliberate operator decision
and should be documented in that operator's own DPIA.
