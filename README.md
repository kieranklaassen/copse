# Copse

A hostname and a port for every Rails app and every git worktree — while the debugger keeps working.

```
~/code/cora             on main         →  http://cora.localhost:5368
~/code/cora-fix-billing on fix-billing  →  http://fix-billing.cora.localhost:4783
~/code/other-app        on main         →  http://other-app.localhost:8119
```

Derived from the directory name and the branch, so nothing collides and nothing has to be chosen. No daemon, no reverse proxy, no privileged listener, zero runtime dependencies.

A linked worktree gets its own development database from the same derivation — `cora_development_fix_billing`. See [Databases](#databases).

## Installation

```ruby
group :development do
  gem "copse"
end
```

```sh
bundle install
bin/rails generate copse:install
bin/dev
```

The generator writes a `bin/dev` that calls Copse, and creates `Procfile.dev` only if you don't have one. An existing `Procfile.dev` is never modified; an existing `bin/dev` is copied to `bin/dev.before-copse` first.

Already on [Overmind](https://github.com/DarthSim/overmind)? The generator sees it in your `bin/dev` and keeps it. Ask for either supervisor explicitly with `--process-manager=overmind` or `--process-manager=foreman`.

## Why

Two apps both want port 3000, so you hand-assign `-p 3001` and then forget which app owns which number — and your teammates picked different ones. Worse, everything lands on `localhost`, so every app shares one cookie jar and one `localStorage`: signing into one signs you out of another.

The hostname is not routing traffic. It gives each app a distinct **browser origin**, which is the half that fixes the cookie jar, and that needs no listener.

### Versus puma-dev

[puma-dev](https://github.com/puma/puma-dev) gives you a bare `https://app.test` with no port. It buys that by running your app as a background daemon, which takes the web process off your terminal — and `binding.irb` with it. Rails' own `bin/dev` stays local but multiplexes stdin through foreman, which breaks the debugger too ([rails/rails#52459](https://github.com/rails/rails/issues/52459)).

Copse runs `web` in the foreground, holding your terminal's stdin and process group; everything else in `Procfile.dev` goes to foreman. The trade is explicit: **you keep the `:5368`.** If a bare hostname matters more than your debugger, use puma-dev.

## Names

| Where you are | Hostname |
|---|---|
| Main worktree | `<project>.localhost` |
| Linked worktree | `<branch>.<project>.localhost` |
| Linked worktree, detached `HEAD` | `<directory>.<project>.localhost` |
| Not a git repository | `<directory>.localhost` |

`<project>` is always the **main** worktree's directory name, so `~/code/cora-fix-billing` on `fix-billing` is `fix-billing.cora.localhost`, not `cora-fix-billing.cora.localhost`.

The suffix is the one thing here you can change: `.localhost` resolves on the machine and nowhere else, and [not on every client](#where-localhost-resolves). [Zeroconf names](#zeroconf-local-names) swap it for `<machine>.local` and put the app on the network.

Names reduce to one DNS label: lowercased, anything outside `[a-z0-9]` collapsed to `-`, capped at 63 characters. `feat/billing-v2` → `feat-billing-v2`. It's a whitelist, not a substitution — git permits `;`, `$(`, and quotes in branch names, and the result reaches your environment and a generated Procfile.

## Ports

`CRC32(hostname)` indexed into `3000..9999` minus 25 well-known service ports. A pure function: same hostname, same port, on every machine and across reboots and Ruby versions, with no stored state and no coordination.

Always the `.localhost` hostname, even when the app is published under another suffix. Switching a machine to [zeroconf names](#zeroconf-local-names) is about names, so it must not move a port your bookmarks, your OAuth callback registrations, and your teammates still on `.localhost` all point at.

Uncoordinated means collisions are possible. Measured over 20,000 seeded trials against 6,975 available ports:

| Worktrees at once | Chance two share a port |
|---|---|
| 10 | ~0.6% |
| 10, using Vite | ~2.5% |
| 40 | ~10% |

Vite doubles it because a Vite app draws two ports. On a collision Copse names the port and the hostname instead of leaving you with Puma's bare `Address already in use`; rename a worktree or branch to fix it.

Changing the range or the reserved list would move nearly every derived port, so it's a breaking change gated by a test that pins the whole set.

## Environment

| Variable | Value |
|---|---|
| `COPSE_HOST` | `cora.localhost` |
| `COPSE_URL` | `http://cora.localhost:5368` |
| `COPSE_PORT` | the derived port |
| `PORT` | the derived port — **`web` process only** |
| `VITE_RUBY_PORT` | the derived companion port |
| `COPSE_DATABASE_SUFFIX` | `fix_billing` — **linked worktrees only**, actively unset in a main one |
| `BINDING` | `0.0.0.0` — **[zeroconf names](#zeroconf-local-names) only**, and never over one you set |
| `RAILS_DEVELOPMENT_HOSTS` | `.cora.thicc.local` — **zeroconf names only**, appended to any you set |

`COPSE_DATABASE_SUFFIX` is exported for your processes to read; Copse never reads it back. In a main worktree it's *removed* from the child environment rather than merely left unset, so a copy inherited from another worktree's session can't be believed. And the rename below is derived from the checkout on disk, so no stale copy of this variable — a shell opened from a linked worktree, a leftover line in `.env` — can rename a main worktree's database.

**In a non-`web` process, read `COPSE_PORT`, not `PORT`.** Foreman assigns its children `base_port + index * 100`, so a secondary's `PORT` is a number Copse never derived. Copse deliberately hands foreman an offset base, so no secondary is ever given the `web` process's own port.

In development Copse also sets `default_url_options` for routes and Action Mailer. It stays out of the way otherwise: not in other environments, not under a plain `bin/rails server`, and not when your app set its own `host`. Puma still prints `Listening on http://127.0.0.1:5368` — that's the address it bound; Copse's line is the name to visit.

`VITE_RUBY_PORT` is picked up by `vite_ruby` automatically. Vite is the only bundler that needs it: esbuild via `jsbundling-rails`, `cssbundling-rails`, `tailwindcss-rails`, Propshaft, and importmap have no port at all.

## Databases

A hostname and a port keep two worktrees from colliding in the browser; they still share one schema. So in **development**, a linked worktree also gets its own database — named after the same slug the hostname uses, with `_` instead of `-`:

```
~/code/cora             on main         →  cora_development
~/code/cora-fix-billing on fix-billing  →  cora_development_fix_billing
```

**A main worktree keeps the database it already has**, which is what makes this safe to add to an existing app: the database you've been using never moves. `config/database.yml` is not modified — Copse renames the loaded configuration at boot.

Copse doesn't create it. Rails already tells you when a database is missing, and creating one is not something `bin/dev` should do behind your back:

```sh
bin/rails db:prepare
```

That works because the rename is derived from the checkout on disk, not from the environment `bin/dev` exports — so `db:prepare`, `bin/rails console`, and `bin/dev` all reach the same database, whether or not Copse started them.

What is left alone:

- **Every environment but development.** Production has one checkout, and Rails already partitions the test database per parallel worker.
- **SQLite and any other file-backed database.** A linked worktree is its own directory, so `storage/development.sqlite3` is already a separate database; renaming would only move the file.
- **Databases marked `database_tasks: false`** — that's how an app says Rails doesn't own it. Replicas *are* renamed, since they point at the same database as their primary.

Every development entry in a multi-database `database.yml` is renamed, not just `primary`. Names are capped at 63 bytes (PostgreSQL truncates past that with only a notice, MySQL rejects past 64); the suffix is what gets trimmed, so two very long branch names can share a database the same way they can share a hostname.

## foreman

Needed only if `Procfile.dev` has anything besides a `web` line:

```ruby
gem "foreman", group: :development
```

Teardown is verified against **0.90.0+**; older versions warn. Under a version manager gems are per-Ruby-version, so switching Ruby can make foreman vanish with no change to your code.

## overmind

```sh
bin/rails generate copse:install --process-manager=overmind
```

Overmind fixes the debugger the other way: every process gets its own tmux pty, so stdin is never multiplexed and you attach with `overmind connect web`. That makes the foreground-`web` split pointless — under Overmind, Copse contributes only the environment and hands the whole `Procfile.dev` over:

```ruby
exit Copse.start(process_manager: :overmind, args: ARGV)
```

Consequences of Overmind supervising everything, `web` included:

- **`PORT` is Overmind's, `base + index * 100`.** So `web` must be the **first** entry in `Procfile.dev` to get the derived port. Copse warns if it isn't. Every process still gets the derived port under `COPSE_PORT`.
- **The derived port is passed as `-p`, and `OVERMIND_SKIP_ENV=1` is set.** Overmind applies env files *over* the environment it's handed, so a stale `PORT` in one would otherwise win. `-p` is what defeats that — including in `.overmind.env`, which `OVERMIND_SKIP_ENV` doesn't skip. Neither touches your app's own loading: `dotenv-rails` still reads `.env` inside Rails, exactly as on the foreman path.
- `bin/dev`'s arguments go to `overmind start` *after* Copse's, so `bin/dev -l web` works and `bin/dev -p 4000` still overrides the derived port.
- **An explicit `--port` on the `web` line wins, and Copse only warns.** `rails server` honours the flag over `PORT`. The foreman path strips it, but that's Copse building the command itself; here Overmind runs your Procfile, and rewriting it into a copy would mean the file you edit and the file `overmind restart` reloads were different things. Remove the flag.
- No pty problems, so none of the stdin traps below apply.

`bin/dev` is committed, and Overmind is a binary rather than a gem, so it's checked at run time, not generate time: a teammate without Overmind falls back to the foreman session automatically. Which is a reason to keep `foreman` in the Gemfile anyway if `Procfile.dev` has non-`web` entries — that machine will need it.

## Where `*.localhost` resolves

RFC 6761 §6.3 makes `.localhost` special with a *SHOULD*, not a MUST, so support is uneven. Two separate questions: does the client resolve the name, and does it then reach a server bound to IPv4 loopback — which is what Rails binds, while `*.localhost` resolves `::1` first.

Measured on macOS 26.5.2, no `/etc/hosts` entry:

| Client | Resolves | Connects | |
|---|---|---|---|
| Chromium / Chrome / Edge | ✅ | ✅ | **verified here**, nested labels included |
| `curl` 8.2.1 | ✅ | ✅ | **verified here** — falls back past `::1` |
| System resolver | ✅ | — | **verified here** — `["::1", "127.0.0.1"]` |
| Firefox | ✅ | ✅ | *unverified* — built in since Firefox 84 |
| Safari, macOS 26+ | ✅ | ✅ | *unverified* — fix is in the OS resolver, which **is** verified |
| Safari / `curl`, macOS ≤ 15 | ❌ | — | *unverified* — [WebKit #160504](https://bugs.webkit.org/show_bug.cgi?id=160504) |
| Linux + `systemd-resolved` | ✅ | — | *unverified* — `systemd-resolved.service(8)` |
| Linux, bare glibc | ❌ | — | *unverified* — no `.localhost` case in glibc |

Rows marked *unverified* come from primary sources, not from this machine.

For a ❌ row, add a hosts entry — with two caveats:

```
127.0.0.1  fix-billing.cora.localhost
```

Neither glibc nor the macOS resolver supports wildcards, so that's **one line per hostname, meaning one per branch**. And it does nothing for Chrome, which hardcodes `.localhost` and [ignores your hosts file](https://issues.chromium.org/issues/41175806) for these names.

On macOS ≤ 15 or bare-glibc Linux and need Safari or `curl`? Either use zeroconf names below, or puma-dev, whose resolver approach doesn't have this gap.

## Zeroconf (`.local`) names

Two reasons to want this:

- **Other devices reach the app by name.** Your phone, a tablet, a real iOS Safari, a VM running end-to-end tests — all of them resolve it, with no `/etc/hosts` entry on any of them. This is the only way to check a mobile layout, or a JS-heavy page on a slow phone, on the actual device.
- **Clients that don't resolve `.localhost` at all.** Safari and `curl` on macOS before 26 (Tahoe), and bare-glibc Linux — see [the table above](#where-localhost-resolves). On those, `.localhost` isn't a preference, it's a dead end.

`.localhost` is a *SHOULD* that each client decides to honour or not. `.local` is the opposite: [RFC 6762](https://www.rfc-editor.org/rfc/rfc6762) reserves it for multicast DNS, and every desktop and phone already runs a responder for it. Nothing has to special-case the name, because the name gets *answered*.

So Copse can publish the derived hostname over mDNS instead — the technique from [Julik Tarkhanov's write-up](https://blog.julik.nl/2025/05/dev-subdomains-with-zeroconf), using [tenderlove's `zeroconf`](https://github.com/tenderlove/zeroconf) gem:

```ruby
group :development do
  gem "copse"
  gem "zeroconf" # only this mode needs it; Copse itself has no dependencies
end
```

```sh
COPSE_ZEROCONF=1 bin/dev
```

```
~/code/cora             on main         →  http://cora.thicc.local:5368
~/code/cora-fix-billing on fix-billing  →  http://fix-billing.cora.thicc.local:4783
```

**The ports are the same ones.** Only the suffix moved: `.localhost` became `<machine>.local`, where `thicc` is this machine's own Bonjour name.

That machine label is not decoration. mDNS is a shared namespace, so two people on one network working on one repository would otherwise announce the same `fix-billing.cora.local` and whoever spoke last would win — your browser would land on your colleague's laptop.

### Opting in

`COPSE_ZEROCONF=1` in your shell profile, because which naming mode you need is a property of your machine, not of the repository: same branch, Chrome on Linux is fine with `.localhost` and Safari on macOS 15 is not. `bin/dev` is committed and shared; this doesn't touch it.

For a whole team, put it in `bin/dev` instead:

```ruby
exit Copse.start(zeroconf: true)
```

Either way, a machine without the `zeroconf` gem installed says so in one line and boots on `.localhost` — same fallback as a teammate without Overmind. The port doesn't move, so the fallback costs you the name and nothing else.

### What changes

- **The app binds `0.0.0.0`**, via `BINDING`. A `.local` name resolves to this machine's address *on the network*, so a server on loopback would answer at an address the name never points at — unreachable from your phone, and unreachable from your own browser under that name. An inherited `BINDING`, an explicit `-b` on the `web` line, or a `bind` in `config/puma.rb` all still win.
- **`RAILS_DEVELOPMENT_HOSTS` gets `.<host>`.** Rails' development allowlist is `.localhost`, `.test`, and the two IP ranges — which match address literals, not names — so without this every request under the advertised name gets a 403. Anything you already set is kept. Two limits, both Rails': the leading dot covers the host and **one** subdomain level, so `jane.cora.thicc.local` passes and `deep.jane.cora.thicc.local` does not; and an app that *assigns* `config.hosts` in `config/environments/development.rb` replaces the list this was appended to. Appending (`config.hosts <<`) is fine.
- **Everything else is unchanged**: the port, the database suffix, `default_url_options`, foreman, Overmind.

### Being on the network

Reachable by every device is the feature, and it is also the cost: someone browsing Bonjour services on the same café Wi-Fi can see the app and connect to it. Fine on a network you trust; think twice on one you don't.

Advertising stops when the session does, including the goodbye packets that withdraw the names. Under Overmind — which replaces Copse's process, so threads can't do it — the advertiser is forked into a process that watches Overmind's pid and withdraws the names when it exits.

### Several subdomains at once

Under `.localhost` every label resolves for free. mDNS answers only for names something announced, so an app serving one subdomain per tenant has to name them:

```sh
COPSE_SUBDOMAINS=jane,peter,tom COPSE_ZEROCONF=1 bin/dev
```

```
jane.cora.thicc.local   peter.cora.thicc.local   tom.cora.thicc.local
```

All on the same port, all covered by the `RAILS_DEVELOPMENT_HOSTS` entry above. `Copse.start(zeroconf: true, subdomains: %w[jane peter tom])` is the committed form.

### When it doesn't work

- **`.local` is not a secure context, and `.localhost` is.** An origin is [potentially trustworthy](https://w3c.github.io/webappsec-secure-contexts/#is-origin-trustworthy) if it is HTTPS, a loopback address, or a host named `localhost` or ending in `.localhost`. `http://cora.thicc.local` is none of those, so everything [gated on a secure context](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts/features_restricted_to_secure_contexts) turns off: service workers, `getUserMedia`, geolocation, WebAuthn and passkeys, `crypto.subtle`, the async clipboard API, Web Bluetooth/USB/Serial. That bites hardest exactly where this mode is most useful — camera and passkeys are half the reason you wanted the phone. Nothing short of HTTPS fixes it, which is [out of scope](#notes) here; on desktop Chrome you can list the origin in `chrome://flags/#unsafely-treat-insecure-origin-as-secure`, and mobile Safari has no such escape hatch. **If a feature works on `.localhost` and dies on `.local`, this is why** — and switching back is one environment variable.
- **Multicast has to cross your network.** Most do; some routers bridging Wi-Fi and Ethernet drop it.
- **Two interfaces, one machine.** The gem announces on the first interface the system returns — on a Mac, the top of Service Order in System Settings. Wired and wireless on different networks means the name may be announced to the one you're not browsing from. Copse prints the address it announced on; if that isn't the one you expect, that's the reason.
- **`.local` as a corporate search domain.** Windows-era networks sometimes configure it, and those DNS servers then compete with mDNS for the same names.
- **Nothing to announce on.** With no multicast-capable interface up, Copse says so and boots anyway — the app is still on its port.

`dns-sd -B _http._tcp` lists what's being advertised, and the app appears there under a dotless instance name (`fix-billing-cora-thicc-local`) because mDNS instance names can't contain dots. The hostname keeps them.

## Requirements

- Ruby >= 3.2.0 (Rails 8.1's own floor; note 3.2 reached EOL 2026-04-01)
- Rails 7.1+ for the generator and URL options — the derivation itself needs neither Rails nor git
- `foreman` >= 0.90.0, only for apps with non-`web` Procfile entries — or Overmind instead, on the `--process-manager=overmind` path
- `zeroconf` >= 1.2.0, only for [zeroconf names](#zeroconf-local-names) — 1.2.0 is where `instance_name:` arrived, without which a hostname containing dots cannot be advertised at all

Rails 8's development host allowlist already includes `.localhost`, so no `config.hosts` change is needed. Zeroconf names are not in it; Copse passes those through `RAILS_DEVELOPMENT_HOSTS` instead.

## Notes

- `Ctrl-C` can take up to foreman's shutdown timeout (5s default) if a watcher doesn't exit promptly.
- **Coming from Overmind, a bare `tailwindcss --watch` will take your whole session down.** The Tailwind CLI exits when stdin closes; Overmind's pty kept it open, foreman gives it none. The watcher exits **0** a second or two after boot and foreman's cascade ends `web` with it, so a CSS problem reads as an intentional shutdown. Use `--watch=always`. Copse warns when it sees the bare flag.
- Some Procfile lines cannot be made signal-transparent, so Copse warns and leaves them exactly as written rather than rewriting them into something subtly different. Their children may survive teardown; split them into separate entries to fix it. The shapes are a **pipeline** (`a | b`), a **background `&`**, a **command substitution** (`$(...)` or backticks), and a **subshell** (`(...)`). Each keeps a shell in front of the real process, and no `exec` placement collapses that into one signalable pid — `exec (cd x && y)` is not even valid shell syntax.
- Out of scope: reverse proxy, daemon, TLS, port registry, and `/etc/hosts` management.

## History

See [CHANGELOG.md](CHANGELOG.md).

## Contributing

Issues and pull requests are welcome. Especially useful:

- **A `.localhost` row you can verify.** The resolution table above marks rows *unverified* when they come from primary sources rather than a machine — replacing one with a measurement is a real contribution.
- **A Procfile line Copse handles wrongly.** Include the line verbatim.

To get set up:

```sh
git clone https://github.com/kieranklaassen/copse.git
cd copse
bundle install
bundle exec rake test
```

The suite drives real processes rather than mocking them, so it needs `foreman` (a dev dependency) and takes about a minute. Two tests bind a derived port; they fail if something else on your machine already holds it. `BUNDLE_GEMFILE=gemfiles/rails71.gemfile bundle exec rake test` checks the oldest supported Rails.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
