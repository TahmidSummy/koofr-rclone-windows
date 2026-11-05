# Benchmarks

These are the scripts behind every number in [docs/RESEARCH.md](../docs/RESEARCH.md). `results/` holds the raw CSVs and `logs/` the rclone log of every run. Koofr mount IDs, user names and PC names in the logs were replaced with placeholders such as `<koofr-mount-id>`.

## Before you run anything
- The tests **upload and download about 8 GiB** to and from Koofr, and take about 2 hours. Some configurations are deliberately slow.
- They use a throwaway Koofr folder, **`koofr:_rclone-lab`**. Make sure it doesn't exist or holds nothing you need. `90-cleanup.ps1` **purges** it.
- They need about 2 GB free in the lab folder, plus room for the test caches.
- Your real drive mount is never touched. Mount tests use **`W:`**, so that letter must be free.
- Use a normal (non-admin) PowerShell.

```powershell
$env:KOOFR_LAB = 'D:\rclone-lab'      # lab folder on a local SSD (default E:\rclone-lab)
New-Item -ItemType Directory -Force "$env:KOOFR_LAB\results","$env:KOOFR_LAB\logs" | Out-Null
```

## Scripts, in order

| Script | What it does | Results |
|---|---|---|
| `lab.ps1` | Shared helpers: timed rclone runs, a CSV row per test, test mounts on W:, random files | – |
| *(data setup)* | Make the test files. Run this first:<br>`. .\lab.ps1; New-Item -ItemType Directory -Force "$Lab\data\large","$Lab\data\medium","$Lab\data\small" \| Out-Null; New-RandomFile "$Lab\data\large\big1g.bin" 1GB; 1..20 \| % { New-RandomFile ("$Lab\data\medium\m{0:D2}.bin" -f $_) 25MB }; 1..300 \| % { New-RandomFile ("$Lab\data\small\s{0:D3}.bin" -f $_) 64KB }` | – |
| `10-upload-tests.ps1` | U01–U12: transfers × HTTP/2 × file size. Also seeds `koofr:_rclone-lab/src` | §6.1 |
| `20-download-tests.ps1` | D01–D15, L01–L02: streams / transfers × HTTP/2, listing | §6.2 |
| `25-repeat-tests.ps1` | Repeats of the noisy results, plus `--tpslimit 20` | §6.2, §6.3 |
| `30-mount-tests.ps1` | M01–M07: cold 1 GiB reads through a W: mount | §6.4 |
| `40-mount-small-write-tests.ps1` | S01–S03 (browsing / small files), W01–W04 (writes) | §6.6, §6.7 |
| `50-ab-read-tests.ps1` | Interleaved A/B reads with a 5-min hang watchdog. `-RcloneExe <path> -Tag <name>` to compare versions | §6.5 |
| `60-tpslimit-test.ps1` | D17a/b: 600 requests with `--tpslimit 40` | §6.3 |
| `70-smoke-test.ps1` | The final flag set on W: | §6.8 |
| `80-watchdog-tests.ps1` | T1–T9: watchdog, internet check, refresh, health check (uses `../scripts`) | §8.2 |
| `85-installer-test.ps1` | I1–I8: install / uninstall end to end on W: (paths are from the original lab; adjust before re-running) | §8.3 |
| `90-cleanup.ps1` | Purges `koofr:_rclone-lab` and deletes local test data | – |

## Tips from running them
- **Koofr's speed swings up to 2× through the day.** Compare settings with interleaved runs (`50-ab-read-tests.ps1` style), not one run each.
- **Heavy small-file tests can trip Koofr's rate limit and break the next test.** Leave 1–2 minutes between them.
- **If a mount test seems stuck, check the `<id>-mount.log`.** A read can hang (M06 on rclone 1.74.2). `50-ab-read-tests.ps1` has a watchdog for this, and the older scripts don't.
