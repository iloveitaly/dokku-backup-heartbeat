# dokku-backup-heartbeat

A Dokku plugin that sends an HTTPS GET heartbeat after a successful `dokku-datastore` backup using the `v0.12.0+` `service-action` `post-backup` trigger.

## Requirements

- Dokku with `dokku-datastore` `v0.12.0+` for `service-action` `post-backup` dispatch
- `curl >= 8.3.0` on the Dokku host, needed for `--variable` and `--expand-url` so the URL stays off the command line
- `sha256sum`, `shasum`, or `openssl`

## Installation

```bash
sudo dokku plugin:install <git-url> --name backup-heartbeat
```

## CLI commands

All commands identify a target by `<datastore> <service> <bucket>`.

### `backup-heartbeat:set <datastore> <service> <bucket>`

Reads the HTTPS heartbeat URL from stdin. Running `set` again for an existing target rotates its URL atomically.

Heartbeat push URLs contain a secret bearer token; anyone who gets the URL can send fake heartbeats and hide failed backups. The command rejects passing the URL as an argument so it stays out of process tables (`ps` and `/proc/<pid>/cmdline`), `sudo`, `ssh`, and Dokku logs (`SSH_ORIGINAL_COMMAND`, `--trace`), interactive shell history, and CI or OpenTofu `local-exec` logs.

Manual usage:

```bash
printf '%s\n' "$HEARTBEAT_URL" | dokku backup-heartbeat:set postgres militia_media_app_postgres movie-tickets-database-backups/dokku-postgres
```

Remote provisioning over SSH, such as CI or an OpenTofu `null_resource` / `terraform_data` provisioner:

```bash
printf '%s\n' "$HEARTBEAT_URL" | ssh -T dokku@host backup-heartbeat:set postgres militia_media_app_postgres movie-tickets-database-backups/dokku-postgres
```

### `backup-heartbeat:report [<datastore> [<service> [<bucket>]]]`

Lists configured targets filtered by 0, 1, 2, or 3 arguments. Output shows whether each target has a URL configured without printing the URL:

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

## Matching and failure semantics

`service-action` sends a request only when called with the exact 5-argument form `post-backup <datastore> <service> <bucket> success` and all three target fields match a configured entry.

Other events, non-`success` statuses like `failure`, and unconfigured or mismatched buckets exit `0` without making an HTTP request.

If the heartbeat returns a non-2xx HTTP status or times out, `service-action` writes a warning to `stderr` without printing the URL and exits non-zero. `dokku-datastore` records the plugin failure as a warning and keeps the backup's exit status.

## Security notes

- The plugin creates target directories and files with `umask 077` (`0700` directories, `0600` files) under `$DOKKU_LIB_ROOT/data/backup-heartbeat/targets`, owned by `dokku:dokku` when installed as root.
- The hook passes heartbeat URLs to `curl` through the `HEARTBEAT_URL` environment variable with `--variable %HEARTBEAT_URL --expand-url {{HEARTBEAT_URL}}`. URLs do not appear in `argv`, logs, or `backup-heartbeat:report` output.
- Scripts that handle URLs disable xtrace (`set +x`) to avoid leaking secrets when `DOKKU_TRACE=1` is set.
- The plugin accepts only `https://` URLs (`--proto =https --proto-redir =https`) and uses a default timeout of `10` seconds (`BACKUP_HEARTBEAT_TIMEOUT`).

## Rollback

Disable the plugin without removing configured targets:

```bash
sudo dokku plugin:disable backup-heartbeat
```

## Running tests

Run static analysis and the self-contained test suite, which uses temporary directories, a stub `curl`, and a local `python3` TCP stall server:

```bash
shellcheck -x config functions install update service-action commands subcommands/* tests/run.sh
./tests/run.sh
```
