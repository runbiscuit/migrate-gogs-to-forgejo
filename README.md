# Gogs → Gitea → Forgejo Migration Script

A shell script to migrate a self-hosted [Gogs](https://gogs.io) instance to [Forgejo](https://forgejo.org),
stepping through an intermediate Gitea upgrade along the way.

**Author's Note:**

I've been using Gogs for the longest time, but development seems to be inactive these days. 

Finally took down the Gogs daemon for an hour during a non-busy time to get this migrated over, surprisingly easy!

## Usage
```
sudo ./upgrade.sh [OPTIONS]

Options:
	--gogs-dir DIR Gogs installation directory (default: /home/git/gogs)
	--gitea-dir DIR Gitea/Forgejo install directory (default: /home/git/gitea)
	--data-dir DIR Data root directory (default: /home/git)
	--user USER OS user running the service (default: git)
	--db-type TYPE Gogs DB type: mysql|postgres|sqlite3 (default: sqlite3)
	--db-name DB Database name (mysql/postgres only)
	--db-user USER Database user (mysql/postgres only)
	--db-pass PASS Database password (mysql/postgres only)
	--db-host HOST Database host:port (default: 127.0.0.1:3306)
	--arch ARCH linux-amd64|linux-arm64|... (default: linux-amd64)
	--forgejo-latest VER Latest Forgejo version (default: 10.0.3)
	--dry-run Print steps without executing
	--skip-backup Skip backup (NOT recommended)
	--resume-from STAGE Resume from a specific stage number
	-h, --help Show this help
```

## Tips

- Use `--resume-from` as you need - the script may fail abruptly and this lets you pick up where you left off.
- At **stage 3** and **stage 9**, run the [recurring database steps](#database---recurring) before continuing.

## Prerequisites

### Database - Run Once

Before starting, convert your Gogs database to `utf8mb4`:

```sql
ALTER DATABASE `<gogs-database>` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
```

### Database - Recurring

At the stages noted above, fetch and run all table conversion statements:

```sql
SELECT CONCAT('ALTER TABLE ', table_name, ' CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;') AS mySQL
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = '<gogs-database>' AND TABLE_TYPE = 'BASE TABLE';
```

Copy the output and run it as a batch against the same database.

## Manual Verification

To confirm Gitea or Forgejo starts correctly under your service user before wiring up the service unit:

```bash
sudo -u <gogs-user> <gogs-directory>/gitea web
OR
sudo -u <gogs-user> <gogs-directory>/forgejo web
```

## AI Disclosure

generated-by: Claude Sonnet 4.6 with human review

Co-authored-by: Edwin A. \<github@biscuit.sh\>
