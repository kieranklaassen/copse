# Copse

A hostname and a port for every Rails app and every git worktree, derived rather
than assigned — while the debugger keeps working.

```
~/code/cora            on main         →  http://cora.localhost:5368
~/code/cora-fix-billing on fix-billing →  http://fix-billing.cora.localhost:4783
~/code/other-app       on main         →  http://other-app.localhost:8119
```

No daemon. No reverse proxy. No DNS configuration. No privileged listener. Zero
runtime dependencies.

## Why

Every Rails app defaults to port 3000, so the second one you start will not boot.
You hand-assign `-p 3001`, then forget which app owns which number, and your
teammates pick different ones so URLs aren't shareable. Worse, everything lands on
`localhost`, so every app shares one cookie jar and one `localStorage`: signing
into one signs you out of another, and anything with subdomain or session behavior
acts nothing like production.

Copse derives a hostname and a port from what you already have — the directory
name and the branch — so nothing collides and nothing has to be chosen. The
hostname isn't routing traffic; it's giving each app a distinct **browser origin**,
which is the half that fixes the shared-cookie-jar problem, and it needs no
listener to do it.

### Why not puma-dev

[puma-dev](https://github.com/puma/puma-dev) does naming well and gives you a bare
`https://app.test` with no port. It buys that by running your app as a background
daemon, which takes the web process off your terminal — and with it `binding.irb`
and interactive debugging.

Rails' own `bin/dev` has the mirror-image problem: everything stays local, but
foreman multiplexes stdin and stdout, which makes the debugger unusable
([rails/rails#52459](https://github.com/rails/rails/issues/52459)).

Copse runs the `web` process in the **foreground**, with your terminal's stdin,
stdout, and stderr, in the terminal's foreground process group. `binding.irb`
behaves exactly as it does under a bare `rails server`. Everything else in
`Procfile.dev` goes to foreman in the background.

The trade is explicit: **you keep the `:5368`.** If a bare hostname matters more
than your debugger, use puma-dev — it occupies that trade honestly.

## Install

```ruby
# Gemfile
group :development do
  gem "copse"
end
```

```bash
bundle install
bin/rails generate copse:install
bin/dev
```

The generator writes a `bin/dev` that calls Copse, and creates a minimal
`Procfile.dev` **only if you don't already have one**. An existing `Procfile.dev`
is never modified. An existing `bin/dev` is copied to `bin/dev.before-copse`
before being replaced.

### foreman

If your `Procfile.dev` has anything besides a `web` line, Copse hands those
processes to `foreman`, which must be available:

```ruby
gem "foreman", group: :development
```

Two things worth knowing. Foreman **0.90.0 or newer** is what Copse's teardown
behavior is verified against; older versions warn. And under a version manager,
gems are per-Ruby-version — switching Ruby can make foreman disappear with no
change to your code, which is why Copse names that possibility in the error.

If your `Procfile.dev` has only a `web` line, foreman is never invoked and never
needs to be installed.

## How the name and port are derived

| Where you are | Hostname |
|---|---|
| Main worktree | `<project>.localhost` |
| Linked worktree | `<branch>.<project>.localhost` |
| Linked worktree, detached `HEAD` | `<directory>.<project>.localhost` |
| Not a git repository at all | `<directory>.localhost` |

`<project>` is the **main** worktree's directory name, even when you're in a
linked one — so `~/code/cora-fix-billing` on branch `fix-billing` becomes
`fix-billing.cora.localhost`, not `cora-fix-billing.cora.localhost`.

Names are reduced to a single valid DNS label: lowercased, anything outside
`[a-z0-9]` collapsed to `-`, trimmed, capped at 63 characters. So `feat/billing-v2`
becomes `feat-billing-v2`. This is a whitelist, not a substitution — git permits
`;`, `$(`, and quotes in branch names, and the result reaches your environment and
a generated Procfile.

The port is `CRC32(hostname)` indexed into the available ports: `3000..9999` minus
25 well-known service ports. It's a pure function, so the same hostname gives the
same port on every machine, in every terminal, across reboots, and across Ruby
versions — with no stored state and no coordination.

### Collisions

Derivation is uncoordinated by design — a registry or a bind-and-probe would
reintroduce the state that makes ports unstable. So collisions are possible, and
the rate is measured rather than hand-waved (20,000 seeded trials over 6,975
available ports):

| Worktrees running at once | Chance two share a port |
|---|---|
| 10 | ~0.6% |
| 10, using Vite | ~2.5% |
| 40 | ~10% |

Vite doubles the figure because a Vite app draws **two** ports, not one. If you hit
a collision, Copse names the port and the hostname rather than leaving you with
Puma's bare `Address already in use`. The fix is to rename a worktree or a branch.

## What your processes receive

| Variable | Value |
|---|---|
| `COPSE_HOST` | `cora.localhost` |
| `COPSE_URL` | `http://cora.localhost:5368` |
| `COPSE_PORT` | the derived port |
| `PORT` | the derived port — **for the `web` process only** |
| `VITE_RUBY_PORT` | the derived companion port |

**Read `COPSE_PORT`, not `PORT`, in a non-`web` process.** Foreman assigns each of
its children `base_port + index * 100`, so a secondary's `PORT` is a number Copse
never derived. `COPSE_PORT` is the one foreman leaves alone.

In development, Copse also sets `default_url_options` for routes and Action Mailer,
so generated links and mail URLs use the derived host. It stays out of the way
when it isn't the one booting: not in other environments, not under a plain
`bin/rails server`, and not when your app has set its own `host`.

Puma still prints its own `Listening on http://127.0.0.1:5368`. That line reports
the address it bound; Copse's line reports the name to visit. Both are correct.

### Vite

`VITE_RUBY_PORT` is set automatically — `vite_ruby` reads it, and environment wins
over `config/vite.json`. Nothing to configure and nothing to compute.

Vite is the only bundler that needs this. esbuild via `jsbundling-rails`,
`cssbundling-rails`, `tailwindcss-rails`, Propshaft, and importmap have **no port
at all** — they write to `app/assets/builds` and are served by the Rails process on
Copse's port.

## Where `*.localhost` resolves

RFC 6761 §6.3 makes `.localhost` special with a **SHOULD**, not a MUST, so support
is genuinely uneven. This matrix separates two different questions: whether a
client resolves the name, and whether it then connects to a server bound to IPv4
loopback (which is what Rails does by default, while `*.localhost` resolves `::1`
first).

Measured on macOS 26.5.2 with no `/etc/hosts` entry:

| Client | Resolves | Connects | How verified |
|---|---|---|---|
| Chromium / Chrome / Edge | ✅ | ✅ | **verified here**, nested labels included |
| `curl` 8.2.1 | ✅ | ✅ | **verified here** — falls back past `::1` |
| System resolver | ✅ | — | **verified here** — `["::1", "127.0.0.1"]` |
| Firefox | ✅ | ✅ | *not verified here* — built in since Firefox 84 |
| Safari, macOS 26+ | ✅ | ✅ | *not verified here* — the fix is in the OS resolver, which **is** verified |
| Safari, macOS ≤ 15 | ❌ | — | *not verified* — reported in [WebKit #160504](https://bugs.webkit.org/show_bug.cgi?id=160504) |
| `curl`, macOS ≤ 15 | ❌ | — | *not verified* — uses the system resolver |
| Linux + `systemd-resolved` | ✅ | — | *not verified here* — documented in `systemd-resolved.service(8)` |
| Linux, bare glibc | ❌ | — | *not verified* — no `.localhost` special case in glibc |

Cells marked *not verified* are reported from primary sources, not measured on this
machine. They are labelled rather than presented as fact.

**If your client is one of the ❌ rows**, add a hosts entry:

```
127.0.0.1  fix-billing.cora.localhost
```

Two caveats that make this less pleasant than it looks. Neither glibc nor the macOS
resolver supports wildcards, so that's **one line per hostname — meaning one per
branch**. And it does nothing for Chrome, which hardcodes `.localhost` in its own
resolver and
[ignores your hosts file](https://issues.chromium.org/issues/41175806) for these
names.

If you're on macOS 15 or earlier, or bare-glibc Linux, and you need Safari or
`curl`: puma-dev's resolver approach doesn't have this gap. That's a real reason to
prefer it.

## Requirements

- Ruby >= 3.2.0 (matching Rails 8.1's own floor; note 3.2 reached EOL 2026-04-01)
- Rails 7.1+ for the generator and URL integration; the derivation itself needs
  neither Rails nor git
- `foreman` >= 0.90.0, only for apps with non-`web` Procfile entries

Rails 8's development host allowlist already includes `.localhost`, so no
`config.hosts` change is needed.

## Notes

- Pressing `Ctrl-C` can take up to foreman's shutdown timeout (5s default) if a
  watcher doesn't exit promptly. `foreman start -t` tunes it; Copse uses the default.
- A `Procfile.dev` line that is a **pipeline** (`a | b`) or uses a background `&`
  keeps a shell in front of its processes, which no amount of `exec` can collapse
  into one signalable pid. Copse warns about those lines and leaves them alone;
  their children may survive teardown. Splitting them into separate entries fixes it.
- Changing the port range or the reserved list would move nearly every derived
  port, so it's a breaking change and needs a major version bump. A test pins the
  whole set to make that impossible to do by accident.

## Not in scope

No reverse proxy, no background daemon, no TLS, no certificate authority. No port
registry, lock file, or coordination service. No `/etc/hosts` management — where an
entry is needed, this README says so rather than editing system files.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
