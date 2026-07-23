# Changelog

## Unreleased

- Gives a linked worktree its own development database, derived from the same slug
  as the hostname: `cora_development` becomes `cora_development_fix_billing`. A
  main worktree keeps the database it already has, and `config/database.yml` is
  never modified — the loaded configuration is renamed at boot. Development only;
  file-backed databases (SQLite) and entries marked `database_tasks: false` are
  left alone, replicas follow their primary, and names are capped at 63 bytes.
  Copse does not create the database: run `bin/rails db:prepare`. The suffix is
  derived from the checkout on disk rather than from Copse's own environment, so
  `db:prepare` and `bin/rails console` reach the same database as `bin/dev`, and
  a stale `COPSE_DATABASE_SUFFIX` cannot rename a main worktree's database.
- Exports `COPSE_DATABASE_SUFFIX` in a linked worktree, for other processes to
  read. Copse never reads it back.

## 0.1.0 (2026-07-23)

First release.

- Derives a hostname per app and per git worktree: `<project>.localhost` for a
  main worktree, `<branch>.<project>.localhost` for a linked one, falling back to
  the directory name on a detached `HEAD` or outside git entirely.
- Derives a stable port from the hostname — `CRC32` indexed into `3000..9999`
  minus 25 well-known service ports. A pure function, identical across machines,
  terminals, reboots, and Ruby versions, with no stored state and no coordination.
- Runs the `web` process in the foreground with the terminal's stdin, stdout, and
  stderr, so `binding.irb` and `debug` work as they do under a bare
  `rails server`. Remaining `Procfile.dev` entries run under foreman and are
  terminated when the foreground process exits.
- Exports `PORT`, `COPSE_PORT`, `COPSE_HOST`, `COPSE_URL`, and `VITE_RUBY_PORT`.
  Non-`web` processes should read `COPSE_PORT`: foreman rewrites `PORT` per child.
- Sets `default_url_options` for routes and Action Mailer in development, only
  when Copse booted the app and only when the app has not set its own `host`.
- `bin/rails generate copse:install` wires up `bin/dev` and creates a minimal
  `Procfile.dev` only when the app has none.
- Supports Overmind as an alternative supervisor:
  `copse:install --process-manager=overmind` writes a `bin/dev` that hands the
  whole `Procfile.dev`, `web` included, to `overmind start` with the derived
  environment — no split session, because Overmind's per-process pty already
  keeps the debugger working. An app whose `bin/dev` already drives Overmind gets
  that variant by default rather than being downgraded to foreman. Overmind is
  probed at run time, so a teammate without it falls back to the foreman session.
  The derived port is passed to Overmind as `-p` and `OVERMIND_SKIP_ENV=1` is set,
  so no env file can beat it — the same reason foreman is given `--env /dev/null`.
- Warns when a Procfile entry runs the Tailwind CLI with a bare `--watch`, which
  exits when stdin closes and so ends the whole foreman session with status 0.

### Notes

- Zero runtime dependencies. Foreman is invoked as a subprocess, never required,
  and is only needed for apps with non-`web` Procfile entries.
- Requires Ruby >= 3.2.0.
- Pipelines and background (`&`) Procfile lines cannot be made signal-transparent;
  Copse warns and leaves them alone. See the README.
