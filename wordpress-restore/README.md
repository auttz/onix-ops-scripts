# wordpress-restore

Standalone restore for the WordPress sites migrated to `192.168.1.11`
(`nap-k3s-server-001`). Not a CronJob — run it by hand from the command line
whenever a site needs restoring from its latest daily backup.

## Requirements

- `kubectl` configured against the target cluster
- Ruby with the `aws-sdk-s3` gem (`gem install aws-sdk-s3`)

## Usage

```bash
S3_KEY=... \
S3_SECRET=... \
S3_URL=... \
S3_BUCKET=devhubs-backup \
S3_FILE=aldamex/wp-backup-gke-20261003220009.zip \
NAMESPACE=web-aldamex \
WP_APP_POD=web-aldamex-wordpress-0 \
WP_MYSQL_POD=web-aldamex-mysql-0 \
ruby restore-wordpress.rb
```

`S3_KEY`/`S3_SECRET`/`S3_URL`/`S3_BUCKET` are the same GCS interop credentials
used for the backup CronJob. `S3_FILE` is the object key without the bucket
name (the part after `gs://devhubs-backup/`).

Safe to re-run — every run fully overwrites the database and WordPress files
with whatever `S3_FILE` currently points at, so restoring a newer day's
backup is just changing `S3_FILE` and running again.

The script prints a restart-count/phase check for both pods after restoring
and exits non-zero (with `WARNING:` lines) if either pod restarted or isn't
`Running` afterward.
