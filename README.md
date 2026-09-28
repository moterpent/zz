# zz (Zeasy) 
### *Minimalist, Snapshot-Aware ZFS Replication*

**zz** is a lightweight Python utility designed to make ZFS off-site replication "Zeasy." It handles the heavy lifting of incremental sends, retention policies, and disaster recovery, ensuring your data is always backed up without the complexity of enterprise-grade storage orchestrators.

This project was started after years of frustration with other zfs replication tools.  There are far more mature, feature rich, and scalable solutions out there.  However, due to issues with setup, maintenance, breakage, recovery from breakage, and disaster recovery, and my own limitations, enough was enough.  It started with two main tenets.  Be simple and reliable.  A person with minimal zfs knowledge (ability to create/modify/destroy pools and datasets) should be able to do any of the following in under a minute:
1. Initialize and start replication with a replica server.
2. Determine the status of the replication.
3. Restore the primary from a replica and, once complete, resume replication with little or no fuss.

---

## 🚀 Key Features

* **Atomic Locking:** Internal file locking prevents overlapping cron jobs from colliding.
* **Sequential Catch-Up:** Automatically detects and sends missing snapshot history if the network or server was down.
* **Drift-Free Scheduling:** A 30-second allowance lets a snapshot fire on the cron run it is due, so the schedule doesn't creep later over time.
* **Dual Retention & Pruning:** Maintain independent history windows (e.g., keep 1 hour of history locally but 30 days remotely).
* **One-Command Recovery:** Rebuild a lost local dataset from your remote target with a single `restore` command.
* **Zero-Database:** All configuration is stored directly in ZFS user properties on the dataset itself.

---

## 🛠️ Installation

1.  Ensure **Python 3.7+** is installed on your host (Tested on Rocky Linux 9).
2.  Clone the repository and link the script onto your path (this lets `zz --version` report the exact commit):
    ```bash
    git clone https://github.com/moterpent/zz /usr/local/src/zz
    ln -s /usr/local/src/zz/zz /usr/local/bin/zz
    ```
    Or copy the `zz` script to `/usr/local/bin/` and `chmod +x` it.
3.  Ensure **SSH Key-Based Authentication** is configured from the local host to the remote host.

To update a cloned install: `git -C /usr/local/src/zz pull`.

---

## 📖 Usage Guide

### 1. Initialize a Relationship
To start backing up a dataset, use `init`. This performs the initial full transfer and sets the backup "contract."
```bash
zz init tank/data backup-server:pool/data --freq 5m --keep-local 1h --keep-remote 7d
```

### 2. Automate with Cron
Add zz sync to your crontab. It handles its own locking and timing checks.
```bash
* * * * * /usr/local/bin/zz sync >> /var/log/zz.out 2>&1
```
Each run logs a header with the version and time, then one line per snapshot sent:
```
--- zz 0.3.3 (a1b2c3d) sync @ 2026-09-28 15:15:01 ---
[*] tank/data: Taking scheduled snapshot @zz_auto_1790630101...
    [+] Sent tank/data @zz_auto_1790626501 -> @zz_auto_1790630101: 5.8M in 0.4s
    [*] Pruning local...
    [*] Pruning remote (backup-server)...
```

Rotate the log with the included logrotate rule (weekly, 12 compressed weeks kept):
```bash
cp util/zz.logrotate /etc/logrotate.d/zz   # edit the path to match your cron line
```

#### Snapshot on demand
To take a snapshot and send it right away, without waiting for the next scheduled one:
```bash
zz sync tank/data --now      # --force is an alias
```
* Takes a snapshot now even if one isn't due, then runs a normal sync.
* Doesn't move the schedule: the next scheduled snapshot comes when it otherwise would have. If a scheduled snapshot happens to be due anyway, only one is taken.
* Doesn't force anything else. Locks, busy checks and errors (a diverged remote, a missing bridge snapshot) stop the sync exactly as without it, and the remote is never overwritten; zz never uses `zfs recv -F`.

Useful for a checkpoint before risky changes, or to test a new setup without waiting a full interval.

### 3. Check Status
View replication health for all managed datasets:
```bash
zz status
```
```
DATASET              | STATUS   | LAST SNAP          | LAG              | NEXT SNAP
------------------------------------------------------------------------------------------
tank/data            | OK       | 0:12:40 ago        | 0:12:40          | 0:47:20
```
* **LAST SNAP**: when the most recent scheduled snapshot was taken (`--now` snapshots aren't counted here).
* **LAG**: age of the newest snapshot confirmed on the remote, i.e. how far behind the replica is.
* **STATUS**: `OK`; `LAGGING` (lag over 2× freq + 5m); `STALLED` (lag over max(1 day, 4× freq)); `ERROR` (the last sync attempt failed; the reason is listed below the table); `INIT`; or `UNKNOWN` (no sync recorded yet).

`zz status` and `zz sync` exit non-zero when anything is unhealthy or failed, so either can drive monitoring or cron alerts.

### 4. Disaster Recovery (Restore)
Recreate a lost dataset from the remote (includes all metadata and history):
```bash
zz restore backup-server:pool/data tank/data
```
* Restores the newest `zz_auto_` snapshot with its full history (`--latest` for just that snapshot), mounts it, and makes it the managed primary again; the next `zz sync` resumes replication incrementally.
* If a restore is interrupted, run the same command again to resume it.
* Refuses to overwrite an existing dataset. Restoring to a different name while the original still replicates to that remote leaves the copy unmanaged.

### 5. Stop Tracking (Forget)
Remove zz management but keep your data.
```bash
zz forget tank/data
```
### 6. Manual Updates & Meta
Update a setting without re-initializing:
```bash
zz set tank/data freq 15m
```
### 7. View the current "contract" for a specific dataset:
```bash
zz meta tank/data
```

## Command Line Usage
```
usage: zz [-h] [--version] <command> ...

Zeasy: Simplified ZFS Replication

options:
  -h, --help  show this help message and exit
  --version   show program's version number and exit

Commands:
  <command>
    init      Start replicating a dataset: <dataset> <host:pool/dataset> [--freq] [--keep-local] [--keep-remote] [--keep-min]
    sync      Snapshot if due and send to the remote: [dataset] [--now]
    status    Replication health of all managed datasets
    meta      Show a dataset's settings: <dataset>
    set       Change a setting: <dataset> <prop> <value>
    abort     Discard an interrupted transfer on the remote: <dataset>
    forget    Stop managing a dataset (data is kept): <dataset>
    restore   Recreate a dataset from the remote: <host:pool/dataset> <dataset> [--latest]

Durations: 30m, 1h, 7d, 2w, 1y (a bare number means minutes).

Examples:
  zz init tank/data backup:pool/data --freq 1h
  zz status
  zz restore backup:pool/data tank/data
```

## 🏷️ Versioning
`zz --version` reports the release version from `__version__` in the script. When run from a git checkout (e.g. `/usr/local/bin/zz` symlinked into a clone), the commit is appended, with `-dirty` if the script has local modifications:
```
zz 0.3.3 (b59c7fd)
```
The same string heads `zz status` output and each `zz sync` run in the log. Bump `__version__` for any behavior change.

## ⚙️ Configuration (The Contract)
zz stores configuration in ZFS user properties. The settings move with the dataset. `init` and `set` reject invalid values; if one is set some other way, zz skips the affected step and reports it as an `ERROR` rather than guessing.

Durations accept `m`, `h`, `d`, `w` and `y` (e.g. `30m`, `12h`, `7d`, `2w`, `1y`); a bare number means minutes.

|Property     |Description|Default|Example|
|-------------|---------------|-------------------|-------------|
|zz:target     |Remote host and the exact dataset to replicate into (parents are created by init)|-|backup:pool/backups/data|
|zz:freq       |How often to sync|60m|5m, 1h, 30d|
|zz:keep_local |Local retention window|7d|1h, 2h, 1d|
|zz:keep_remote|Remote retention window|30d|24h, 30d, 1y|
|zz:keep_min   |Safety floor: newest N snapshots never pruned, on either side, regardless of age|10|24|
|zz:last_sync  |Time of last scheduled snapshot; the schedule counts from it (managed by zz)|-|1790626501|
|zz:last_sent  |Time of newest snapshot confirmed on remote (managed by zz)|-|1790626501|
|zz:last_error |Last sync failure, cleared on success (managed by zz)|-|1790626501 Could not retrieve...|


## ⚠️ Important Notes
* **Snapshots:** zz only manages snapshots prefixed with @zz_auto_.
* **Remote Integrity:** zz uses incremental sends without the -F (Force) flag. Do
  not modify the remote dataset directly (keep it readonly=on) to avoid stream
divergence. If it is modified, syncs fail with "destination has been modified" and
`zz status` shows `ERROR`; roll the remote back to its newest `zz_auto_` snapshot
(`zfs rollback pool/data@zz_auto_...`) and the next sync catches up.
* **Lock Files:** Stored in `/run/zz/` (root-only; override with `ZZ_LOCK_DIR`). A short lock serializes snapshotting, and a second lock prevents overlapping transfers, so snapshots are still taken on schedule while a long transfer runs.
* **Schedule Drift:** A snapshot is taken when at least `freq` minus 30 seconds has
passed since the last one. Without that allowance, a cron run a second early would
defer the snapshot to the next run, and the schedule would creep later over time.

License: 
MIT License

Keep it Zeasy.
