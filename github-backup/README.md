# GitHub Backup for Synology

Mirror-clones every repository across one or more GitHub organizations or
users to your Synology NAS. Designed to run unattended once a day via DSM
Task Scheduler.

The script uses `git clone --mirror` (and `git remote update --prune` for
existing mirrors), so the on-disk copy contains every branch, tag and
ref — i.e. a full backup that you can restore from with a single
`git clone` later on.

## Files

| File | Purpose |
| --- | --- |
| `github-backup.sh` | Main backup script. |
| `config.example.env` | Template for the runtime config — copy to `config.env` and edit. |

## Prerequisites

Everything below is available from Synology's official **Package
Center** — no third-party package repositories (Entware, Homebrew,
etc.) are needed.

On the NAS (DSM 7.x):

1. **SSH access** enabled (Control Panel → Terminal & SNMP).
2. **Git Server** — install from Package Center. This puts `git` on the
   system `PATH`.
3. **Python 3** — install from Package Center (the package is named
   *Python 3.9* or similar, depending on DSM version). Used only for
   parsing the JSON responses from the GitHub API via the standard
   library; no `pip` packages are installed. If `python3` ends up at a
   non-default path (e.g. `/usr/local/bin/python3`), set `PYTHON_BIN`
   in `config.env` to point to it.
4. **bash** and **curl** — already present in DSM 7.

That's it. The script itself is a single bash file you can read end to
end before running.

## Setup

### 1. Drop the script onto the NAS

Pick a location that survives DSM updates — somewhere on `/volume1` is
typical. For example:

```bash
sudo mkdir -p /volume1/scripts
sudo cp -r github-backup /volume1/scripts/
sudo chmod +x /volume1/scripts/github-backup/github-backup.sh
```

### 2. Create a GitHub personal access token

Go to <https://github.com/settings/tokens> and create either:

- A **classic** token with the `repo` and `read:org` scopes, or
- A **fine-grained** token, granted to each org/account, with read-only
  access to *Contents* and *Metadata* on all repositories.

Copy the token — you only see it once.

### 3. Configure

```bash
cd /volume1/scripts/github-backup
sudo cp config.example.env config.env
sudo chmod 600 config.env
sudo vi config.env      # paste the token, adjust paths/orgs
```

Key settings (full list in `config.example.env`):

| Variable | Default | Notes |
| --- | --- | --- |
| `GITHUB_TOKEN` | — | Required. |
| `GITHUB_ACCOUNTS` | `stanasiukcom defuseddata marchemycom scrapply` | Space-separated orgs and/or users. The script auto-detects which kind each one is. |
| `BACKUP_ROOT` | `/volume1/backups/github` | Mirrors live under `<root>/<account>/<repo>.git`. |
| `LOG_DIR` | `<root>/logs` | One log file per run. |
| `LOG_RETENTION_DAYS` | `30` | Older log files are deleted automatically. |
| `INCLUDE_PRIVATE` / `INCLUDE_FORKS` / `INCLUDE_ARCHIVED` | `true` | Toggle filters. |

### 4. Run it once by hand

```bash
sudo /volume1/scripts/github-backup/github-backup.sh
```

You should see lines like `cloning stanasiukcom/foo` followed by a
summary at the end. Check `/volume1/backups/github/logs/` for the log
file if anything goes wrong.

### 5. Schedule it daily

DSM Task Scheduler:

1. **Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script**.
2. **General**:
   - Task name: `GitHub backup`
   - User: `root` (so the task can write to `/volume1/backups`)
   - Enabled: yes
3. **Schedule**:
   - Run on the following days: Daily
   - First run time: e.g. `03:00`
   - Frequency: `Every 1 day(s)`
4. **Task Settings → User-defined script**:
   ```sh
   /bin/bash /volume1/scripts/github-backup/github-backup.sh
   ```
   Tick *Send run details by email* and set the address if you want a
   per-run report.
5. **OK** → confirm with the admin password.

You can right-click the task and pick *Run* to test it from the GUI.

## Restoring a repo

The mirrors are bare repositories, so to get a normal working copy:

```bash
git clone /volume1/backups/github/stanasiukcom/myrepo.git /tmp/myrepo
```

To push a local backup back up to GitHub (for example after recreating
an empty repo there):

```bash
cd /volume1/backups/github/stanasiukcom/myrepo.git
git push --mirror https://github.com/stanasiukcom/myrepo.git
```

## Customizing what gets backed up

- **Different orgs/users** — edit `GITHUB_ACCOUNTS` in `config.env`.
- **Skip forks** — `INCLUDE_FORKS="false"`.
- **Skip archived repos** — `INCLUDE_ARCHIVED="false"`.
- **Public-only mirror** — `INCLUDE_PRIVATE="false"`.
- **One-off run with a different config** —
  `GITHUB_BACKUP_CONFIG=/path/to/other.env ./github-backup.sh`.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `required command not found: python3` | Install the *Python 3* package from Synology Package Center, or set `PYTHON_BIN` in `config.env` to the full path (e.g. `/usr/local/bin/python3`). |
| `GITHUB_TOKEN is empty` | `config.env` not next to the script, or the token line is commented out. |
| `clone failed` for one repo | Token lacks access — confirm the org granted the fine-grained token, or that the classic token has `repo` scope. |
| Task Scheduler reports exit code `1` | At least one repo failed. Check the latest log under `LOG_DIR`. |
| API rate-limit errors | The token isn't being sent. Re-check `GITHUB_TOKEN`; authenticated requests get 5,000/hour. |

## Security notes

- `config.env` holds a token with read access to private repos. Keep it
  `chmod 600` and owned by the user that runs the task.
- The token is passed to git via `-c http.extraHeader=...`, which keeps
  it out of the on-disk `.git/config` of every mirror. It only lives in
  the `config.env` file and in the running process's memory.
- Mirrors include every branch and tag — if you've ever committed a
  secret, it's in the backup too. Treat `BACKUP_ROOT` accordingly.
