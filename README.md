# synology-scripts

Scripts I run on my Synology NAS. Each script lives in its own
subdirectory together with a dedicated `README.md` covering setup,
configuration, and DSM Task Scheduler instructions.

## Scripts

| Script | Purpose |
| --- | --- |
| [`github-backup/`](./github-backup/) | Mirror-clone every repo across one or more GitHub orgs/users to the NAS once a day. |

## Conventions

- Scripts assume DSM 7.x and a `/volume1` data volume.
- Scripts and their docs live under `/volume1/scripts/<name>/` on the
  NAS — clone or copy this repo there.
- Configuration lives in a `config.env` next to each script. A
  `config.example.env` is checked in; copy it, edit, and `chmod 600`.
- Logs are written under `/volume1/backups/<name>/logs/` by default and
  rotated after a configurable retention period.
- Scheduled jobs are added through **Control Panel → Task Scheduler →
  Create → Scheduled Task → User-defined script**, running as `root`
  unless a script's README says otherwise.

## Common prerequisites

Most scripts in this repo expect:

- SSH access to the NAS (Control Panel → Terminal & SNMP).
- `git`, `curl`, and `jq`. `git` and `curl` ship with DSM or are
  installable via Package Center; `jq` is easiest to get through
  [Entware](https://github.com/Entware/Entware/wiki/Install-on-Synology-NAS)
  (`opkg install jq`).

Per-script requirements and tokens are listed in each subdirectory's
README.

## Installing on the NAS

```bash
ssh admin@your-nas
sudo mkdir -p /volume1/scripts
cd /volume1/scripts
sudo git clone https://github.com/stanasiukcom/synology-scripts.git .
```

Then follow the README inside the script you want to run.

## Updating

```bash
cd /volume1/scripts/synology-scripts
sudo git pull
```

`config.env` files are gitignored intentionally — they hold tokens — so
pulling won't clobber your local configuration.
