# ping

A minimal uptime check for personal projects, run by GitHub Actions.

Every 6 hours it requests each site listed in `sites.txt` and checks that the
final response — after redirects — is `200`. It also reads each site's TLS
certificate and warns before it expires.

Results are reported as GitHub issues, so GitHub's own notification emails do
the alerting. There is nothing to host and no third-party service involved.

## How alerting works

| Situation | What happens |
| --- | --- |
| Site fails, no issue open | Opens `Down: example.com` — you get an email |
| Site fails, issue already open | Nothing. No duplicate emails while it stays down |
| Site recovers | Comments and closes the issue — you get a second email |
| Certificate expires within 14 days | Opens `Cert expiring: example.com` |
| Certificate renewed | Closes that issue |

A failing site does **not** fail the workflow. Down sites are tracked as
issues; a red workflow run means the script itself broke.

## Setup

1. Add your sites to `sites.txt`, one per line. A bare domain is checked over
   https; a full URL is used as written.
2. Push to GitHub as a **public** repository — scheduled Actions minutes are
   free there. Note that your site list and incident history become public.
3. In **Settings → Actions → General**, make sure workflows have read and write
   permissions, so the run can open issues and push the heartbeat commit.
4. In your GitHub [notification settings](https://github.com/settings/notifications),
   make sure email is enabled for issue activity on repositories you watch. You
   watch your own repositories by default.
5. Run it once by hand from the **Actions** tab to confirm everything works.

## What this does not do

- **It will not catch short outages.** With a 6 hour interval, the average
  detection delay is about 3 hours and the worst case is 6. It catches a site
  that has stayed down, not a blip.
- **It says nothing about load.** A `200` means the site answered, not that it
  answered quickly or that anything behind it is healthy. Measuring load needs
  metrics from inside the application, not an external request.
- **It checks from one place.** A single GitHub runner in a single region. A
  network problem on their side looks the same as a problem on yours, which is
  why each check retries three times before reporting.

If you need sub-minute detection, multi-region checks, or paging, use a real
monitoring service. This is deliberately the smallest thing that works.

## Running it locally

```bash
DRY_RUN=1 ./scripts/ping.sh
```

`DRY_RUN=1` prints what it would do without touching any issues.

## Configuration

These environment variables override the defaults:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SITES_FILE` | `sites.txt` | Path to the site list |
| `TRIES` | `3` | Attempts before a site is called down |
| `RETRY_DELAY` | `10` | Seconds between attempts |
| `TIMEOUT` | `10` | Per-request timeout in seconds |
| `CERT_WARN_DAYS` | `14` | Days before expiry that triggers a warning |
| `DRY_RUN` | `0` | Set to `1` to skip all issue changes |

To change the schedule, edit the `cron` line in
[`.github/workflows/ping.yml`](.github/workflows/ping.yml).
