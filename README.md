# dokku-backup-heartbeat

Dokku plugin that sends an HTTPS GET heartbeat notification after a successful `dokku-datastore` backup (`v0.12.0+` `service-action` `post-backup` trigger).

## Requirements

- Dokku with `dokku-datastore` `v0.12.0+` (for `service-action` `post-backup` dispatch)
- `curl >= 8.3.0` on the Dokku host (required for `--variable` and `--expand-url` so the heartbeat URL is never passed on the command line)
- `sha256sum`, `shasum`, or `openssl`

## Installation

```bash
sudo dokku plugin:install <git-url> --name backup-heartbeat
```

## CLI Commands

All commands identify targets by `<datastore> <service> <bucket>`.

### `backup-heartbeat:set <datastore> <service> <bucket>`

Reads the HTTPS heartbeat URL from **stdin**. Re-running `set` for an existing target atomically rotates its URL.

**Why stdin instead of a CLI argument?** Heartbeat push URLs embed a secret bearer token directly in the URL—anyone who obtains it can forge green heartbeats and mask failed backups. Passing the URL as a command-line argument is intentionally rejected so it cannot leak into process tables (`ps` / `/proc/<pid>/cmdline`), `sudo`/`ssh`/Dokku logs (`SSH_ORIGINAL_COMMAND`, `--trace`), interactive shell history, or CI/OpenTofu `local-exec` logs.

Manual usage:

```bash
printf '%s\n' "$HEARTBEAT_URL" | dokku backup-heartbeat:set postgres militia_media_app_postgres movie-tickets-database-backups/dokku-postgres
```

Remote provisioning via SSH (e.g., CI or OpenTofu `null_resource` / `terraform_data` provisioner):

```bash
printf '%s\n' "$HEARTBEAT_URL" | ssh -T dokku@host backup-heartbeat:set postgres militia_media_app_postgres movie-tickets-database-backups/dokku-postgres
```

### `backup-heartbeat:report [<datastore> [<service> [<bucket>]]]`

Lists configured targets filtered by 0, 1, 2, or 3 arguments. Output shows whether a URL is configured, never the URL itself:

```bash
dokku backup-heartbeat:report
dokku backup-heartbeat:report postgres
dokku backup-heartbeat:report postgres militia_media_app_postgres
```

### `backup-heartbeat:unset <datastore> <service> <bucket>`

Removes a configured target:

```bash
dokku backup-heartbeat:unset postgres militia_media_app_postgres movie-tickets-database-backups/dokku-postgres
```

## Matching & Failure Semantics

- **Exact 5-argument match**: `service-action` only dispatches when invoked as:
  `post-backup <datastore> <service> <bucket> success`
  where `<datastore>`, `<service>`, and `<bucket>` exactly match a configured target.
- **Failed backups send nothing**: non-`post-backup` events, non-`success` statuses (such as `failure`), and unconfigured or mismatched buckets exit `0` without making any HTTP request.
- **Non-2xx / timeout handling**: if the heartbeat request returns a non-2xx HTTP status or times out, `service-action` logs a warning to `stderr` (never printing the URL) and exits non-zero. `dokku-datastore` logs the plugin failure as a warning while preserving the backup's exit status.

## Security Notes

- Target directories and files are created with `umask 077` (`0700` directories, `0600` files) under `$DOKKU_LIB_ROOT/data/backup-heartbeat/targets`, owned by `dokku:dokku` when installed as root.
- Heartbeat URLs are passed to `curl` exclusively via the `HEARTBEAT_URL` environment variable with `--variable %HEARTBEAT_URL --expand-url {{HEARTBEAT_URL}}`, never in `argv`, logs, or `backup-heartbeat:report` output.
- URL scripts explicitly disable xtrace (`set +x`) to prevent secret leakage even when `DOKKU_TRACE=1` is set.
- Only `https://` URLs are accepted (`--proto =https --proto-redir =https`), with a default request timeout of `10` seconds (`BACKUP_HEARTBEAT_TIMEOUT`).

## Rollback

To disable the plugin without removing configured targets:

```bash
sudo dokku plugin:disable backup-heartbeat
```

## Running Tests

Run static analysis and the self-contained test suite (uses temporary directories, a stub `curl`, and a local `python3` TCP stall server):

```bash
shellcheck -x config functions install update service-action commands subcommands/* tests/run.sh
./tests/run.sh
```
