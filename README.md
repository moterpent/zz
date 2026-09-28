# zz (Zeasy) 
### *Minimalist, Snapshot-Aware ZFS Replication*

**zz** is a lightweight Python utility designed to make ZFS off-site replication "Zeasy." It handles the heavy lifting of incremental sends, retention policies, and disaster recovery, ensuring your data is always backed up without the complexity of enterprise-grade storage orchestrators.

This project was started after years of frustration with other zfs replication tools.  There are far more mature, feature rich, and scalable solutions out there.  However, due to issues with setup, maintenance, breakage, recovery from breakage, and disaster recovery, and my own limitations, enough was enough.  It started with two main tenants.  Be simple and reliable.  A person with minimal zfs knowledge (ability to create/modify/destroy pools and datasets) should be able to do any of the following in under a minute:
1. Initialize and start replication with a replica server.
2. Determine the status of the replication.
3. Restore the primary from a replica and, once complete, resume replication with little or no fuss.

---

## 🚀 Key Features

* **Atomic Locking:** Internal file locking prevents overlapping cron jobs from colliding.
* **Sequential Catch-Up:** Automatically detects and sends missing snapshot history if the network or server was down.
* **Phase-Drift Correction:** Built-in "slop" and timestamp flooring ensures syncs stay aligned with clock and minute boundaries.
* **Dual Retention & Pruning:** Maintain independent history windows (e.g., keep 1 hour of history locally but 30 days remotely).
* **One-Command Recovery:** Rebuild a lost local dataset from your remote target with a single `restore` command.
* **Zero-Database:** All configuration is stored directly in ZFS user properties on the dataset itself.

---

## 🛠️ Installation

1.  Ensure **Python 3.6+** is installed on your host (Tested on Rocky Linux 9).
2.  Download the `zz` script to `/usr/local/bin/`.
3.  Make it executable:
    ```bash
    chmod +x /usr/local/bin/zz
    ```
4.  Ensure **SSH Key-Based Authentication** is configured between the local and remote host.

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
* * * * * /usr/local/bin/zz sync >> /var/log/zz.log 2>&1
```

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
* **LAST SNAP**: when the most recent snapshot was taken locally.
* **LAG**: age of the newest snapshot confirmed on the remote, i.e. how far behind the replica is.
* **STATUS**: `OK`; `LAGGING` (lag over 2× freq + 5m); `STALLED` (lag over max(1 day, 4× freq)); `ERROR` (the last sync attempt failed; the reason is listed below the table); `INIT`; or `UNKNOWN` (no sync recorded yet).

`zz status` and `zz sync` exit non-zero when anything is unhealthy or failed, so either can drive monitoring or cron alerts.

### 4. Disaster Recovery (Restore)
Recreate a lost dataset from the remote (includes all metadata and history):
```bash
zz restore backup-server:pool/data tank/data
```

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
usage: zz [-h] <command> ...

Zeasy: Simplified ZFS Replication

options:
  -h, --help  show this help message and exit

Commands:
  <command>
    init      Setup replication [dataset] [remote] [--freq] [--keep-local] [--keep-remote] [--keep-min]
    sync      Run incremental sync [dataset] [--force]
    status    Show health of all managed datasets
    meta      View configuration contract [dataset]
    set       Update properties [dataset] [prop] [value]
    forget    Stop tracking a dataset [dataset]
    restore   Recover from remote [remote] [local_dataset] [--latest]

Examples:
  zz init tank/data backup:pool/data --freq 1h
  zz restore backup:pool/data tank/data --latest
```

## 🏷️ Versioning
`zz --version` reports the release version from `__version__` in the script. When run from a git checkout (e.g. `/usr/local/bin/zz` symlinked into a clone), the commit is appended, with `-dirty` if the script has local modifications:
```
zz 0.2.0 (42c3fae)
```
The same string heads `zz status` output and each `zz sync` run in the log. Bump `__version__` for any behavior change.

## ⚙️ Configuration (The Contract)
zz stores configuration in ZFS user properties. The settings move with the dataset.

|Property     |Description|Default|Example|
|-------------|---------------|-------------------|-------------|
|zz:target     |Remote SSH target and path|-|192.168.60.62:tank/test|
|zz:freq       |How often to sync|60m|5m, 1h, 30d|
|zz:keep_local |Local retention window|7d|1h, 2h, 1d|
|zz:keep_remote|Remote retention window|30d|24h, 30d, 1y|
|zz:last_sync  |Time of last local snapshot (managed by zz)|-|1790626501|
|zz:last_sent  |Time of newest snapshot confirmed on remote (managed by zz)|-|1790626501|
|zz:last_error |Last sync failure, cleared on success (managed by zz)|-|1790626501 Could not retrieve...|


## ⚠️ Important Notes
* **Snapshots:** zz only manages snapshots prefixed with @zz_auto_.
* **Remote Integrity:** zz uses incremental sends without the -F (Force) flag. Do
  not modify the remote dataset directly (keep it readonly=on) to avoid stream
divergence.
* **Lock Files:** Stored in /tmp/zz_[dataset_name].lock to prevent overlapping runs.
* **Phase-Drift:** The script "floors" the last sync time to the
nearest minute to prevent the schedule from slowly drifting forward.📄

License: 
MIT License

Keep it Zeasy.
