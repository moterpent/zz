# zz (Zeasy) 
### *Minimalist, Snapshot-Aware ZFS Replication*

**zz** is a lightweight Python utility designed to make ZFS off-site replication "Zeasy." It handles the heavy lifting of incremental sends, retention policies, and disaster recovery, ensuring your data is always backed up without the complexity of enterprise-grade storage orchestrators.

---

## 🚀 Key Features

* **Atomic Locking:** Internal file locking prevents overlapping cron jobs from colliding.
* **Sequential Catch-Up:** Automatically detects and sends missing snapshot history if the network or server was down.
* **Phase-Drift Correction:** Built-in "slop" and timestamp flooring ensures syncs stay aligned with clock and minute boundaries.
* **Dual Retention:** Maintain independent history windows (e.g., keep 1 hour of history locally but 30 days remotely).
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
