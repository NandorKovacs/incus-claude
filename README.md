# incus-claude

Spin up a disposable **Arch Linux [Incus](https://linuxcontainers.org/incus/) container** with a folder mounted in, ready to run [Claude Code](https://claude.ai/code) — already logged in, isolated from your host, and living inside a persistent `tmux` session.

The idea: give Claude Code a sandbox to work in. It can install packages, run builds, and touch the filesystem freely without that landing on your host system — but it still operates on your real project folder (bind-mounted in) and reuses your existing Claude login, so there's nothing to set up inside the box.

It works on **local folders** and on **remote folders over SSH** (mounted via `sshfs`).

---

## Why

- **Isolation.** Claude runs as root-capable inside an unprivileged container. It can `pacman -S` whatever it wants, break its own environment, and you just `--rm` and start over. Your host stays clean.
- **Zero auth setup.** Your host `~/.claude` is bind-mounted in at the *same path* under a matching user, so the container is logged in the instant it starts. No token copying, no re-login.
- **Persistent sessions.** Claude runs inside `tmux`. Detach with `Ctrl-b d`, close your terminal, come back later — re-run the script and you reattach to the same running session.
- **Reproducible toolchain.** The package set lives in `packages.txt` and is re-applied idempotently on every launch, so containers are easy to reason about and rebuild.
- **Fast boot.** The first launch bakes a fully-provisioned Incus image (system upgrade, `packages.txt`, the matching user, Claude Code) and caches it keyed on a hash of `packages.txt`. Every later container is created straight from that image — no `pacman` or installer on boot. Change `packages.txt` and it rebuilds once.

---

## Prerequisites

On the **host**:

- **Incus**, installed and with a working daemon — a storage pool and a network must already be configured. Setting up Incus is your responsibility; the script only checks that `incus info` succeeds.
  ```bash
  # Arch example
  sudo pacman -S incus
  sudo systemctl enable --now incus
  incus admin init        # configure storage pool + network if you haven't
  ```
- **sshfs** — only if you mount remote (`user@host:/path`) folders.
  ```bash
  sudo pacman -S sshfs
  echo user_allow_other | sudo tee -a /etc/fuse.conf   # one-time, needed for remote mounts
  ```
No host-identity configuration is needed: the script auto-detects your **uid / gid / username / home** (`id -u`, `id -g`, `id -un`, `$HOME`) and recreates a matching user inside the container so mounted files keep their real ownership. You can override any of these with the `HOST_UID`, `HOST_GID`, `HOST_USER`, `HOST_HOME` environment variables if you need to.

---

## Quick start

```bash
# Launch a container for the current project and drop into Claude Code
./incus-claude.sh .

# ... work in Claude. Detach the tmux session any time with Ctrl-b d.
# Re-running the same command reattaches to the still-running session:
./incus-claude.sh .

# When you're done with this workspace, destroy its container:
./incus-claude.sh --rm .
```

That's the whole loop: **launch → work → detach → reattach → `--rm`**.

---

## Usage

```
./incus-claude.sh [options] <folder | user@host:/remote/path> [-- claude args...]
```

### A local folder

```bash
./incus-claude.sh ~/prg/myproject
```

The folder is bind-mounted into the container at the **identical absolute path** and becomes the working directory Claude starts in.

### A remote folder over SSH

```bash
./incus-claude.sh me@server:/srv/www/app
```

The remote path is mounted on the host with `sshfs` (using your existing SSH keys / agent / `known_hosts`), then bind-mounted into the container at the same remote path. Requires `sshfs` and `user_allow_other` (see Prerequisites).

### Options

| Option | Effect |
| --- | --- |
| `--rm` | Destroy the container (and any host `sshfs` mount) for the given path, then exit. |
| `--name NAME` | Override the auto-derived container name. |
| `--mount-home` | Mount all of `$HOME` instead of just `~/.claude` + `~/.claude.json`. Most faithful, but exposes your whole home to the container. |
| `--pkg "PKG..."` | Extra pacman packages on top of `packages.txt`. Repeatable; values accumulate. |
| `--with NAME` | Install a curated tool by name. Repeatable. Recipes: `uv`, `bun`, `deno`, `rust`, `go`, `pnpm`. |
| `--run 'CMD'` | Arbitrary provisioning command, run as the container user after packages/recipes. Repeatable. Escape hatch for anything the above don't cover. |
| `--yolo` | Start Claude with `--dangerously-skip-permissions` — it auto-accepts **every** tool use and edit, no prompts. Shorthand for `-- --dangerously-skip-permissions`. |
| `--no-attach` | Provision only; print the launch command instead of attaching. |
| `-h`, `--help` | Show built-in help. |
| `-- claude args...` | Everything after `--` is forwarded verbatim to `claude` on launch (see below). |

### Examples

```bash
# Local project with extra packages and the Rust toolchain
./incus-claude.sh --pkg "postgresql redis" --with rust ~/prg/api

# Add uv + a one-off setup command
./incus-claude.sh --with uv --run 'uv sync' ~/prg/ml-thing

# Provision without attaching (e.g. for scripting); prints the attach command
./incus-claude.sh --no-attach ~/prg/myproject

# Tear down a remote workspace's container and unmount its sshfs
./incus-claude.sh --rm me@server:/srv/www/app
```

---

## How Claude starts (passing arguments)

Anything after a `--` separator is forwarded **verbatim** to the `claude` command inside the container — so you can set the model, a starting prompt, the permission mode, extra allowed dirs, or any other flag:

```bash
# Pick a model and hand Claude an opening prompt
./incus-claude.sh ~/prg/myproject -- --model opus "refactor the auth module"

# Auto-accept edits only (still prompts for other tools like Bash)
./incus-claude.sh ~/prg/myproject -- --permission-mode acceptEdits
```

### Auto-accepting every tool use and edit

Yes — pass `--yolo`, which starts Claude with `--dangerously-skip-permissions`. Claude then runs **fully unattended**: every tool call, command, and file edit is accepted with no confirmation prompt.

```bash
./incus-claude.sh --yolo ~/prg/myproject
# identical to:
./incus-claude.sh ~/prg/myproject -- --dangerously-skip-permissions
```

This is normally dangerous, but it's the natural fit here: the container is an **isolated, unprivileged sandbox**, so even if Claude runs something destructive it can only damage the container (throw it away with `--rm`) and the bind-mounted workspace. Claude Code itself recommends this flag only for sandboxes — which is exactly what you've got.

There are two levels to choose from:

| Goal | Flag |
| --- | --- |
| Auto-accept **edits** only, still ask before Bash/etc. | `-- --permission-mode acceptEdits` |
| Auto-accept **everything**, no prompts at all | `--yolo` (i.e. `--dangerously-skip-permissions`) |

> **Note:** startup arguments apply only when the `tmux` session is **first created**. When you re-run the script and reattach to an already-running session, `tmux` ignores the command and the existing Claude process keeps running with whatever flags it started with. To change them, detach and `--rm` (or kill the `claude` tmux session) first.

---

## Managing packages

The base package set lives in [`packages.txt`](packages.txt) — one pacman package per line, `#` comments allowed (whole-line or inline). To add packages to an **existing** container, just edit the file and re-run the script: `packages.txt`, `--pkg`, `--with`, and `--run` are all re-applied idempotently on every launch.

`tmux`, `git`, `curl`, and `base-devel` are always installed by the script itself (the launch mechanism needs them), so you don't list them in `packages.txt`.

---

## How it works (architecture)

The whole thing is a single Bash script. Here's the pipeline it runs on each launch:

```
  ┌─────────────┐   ┌──────────────┐   ┌───────────────┐   ┌───────────────┐   ┌────────────┐   ┌──────────┐
  │ parse args  │──▶│ classify     │──▶│ build/fetch   │──▶│ create / start│──▶│ provision  │──▶│ attach   │
  │ + packages  │   │ target       │   │ cache image   │   │ container     │   │ (once) +   │   │ tmux ▶   │
  │             │   │ local vs ssh │   │ (per pkgs.txt)│   │ + bind mounts │   │ packages   │   │ claude   │
  └─────────────┘   └──────────────┘   └───────────────┘   └───────────────┘   └────────────┘   └──────────┘
```

### 1. Deterministic container naming

The container name is derived from a SHA-256 of the resolved target path: `claude-<8 hex>`. The same folder always maps to the same container, which is what makes "re-run to reattach" work and what `--rm` keys off of. `--name` overrides it.

### 2. Authentication by bind mount (the key trick)

Rather than copying credentials, the script bind-mounts your host `~/.claude` (and `~/.claude.json`) into the container at the **identical path**, owned by a container user whose **uid/gid/name match the host** (auto-detected from the invoking user). Claude Code inside the container reads the exact same auth state your host Claude does — so it's logged in immediately, with no tokens extracted or duplicated.

`--mount-home` instead mounts your entire `$HOME`. That's fully faithful (and sidesteps a `.claude.json` staleness caveat) but exposes everything in your home directory to the container.

### 3. id-mapped mounts, unprivileged container

The container is **unprivileged** (its root maps to a high, unprivileged host uid range). To make host files owned by your uid/gid show up with those *same* ids inside the container, disk devices are attached with `shift=true`, which uses **idmapped mounts**. This avoids `raw.idmap` and `/etc/subuid` editing entirely — there's nothing to configure on the host.

### 4. Local vs. remote targets

The target argument is classified by a regex: anything matching `something:/path` (with no leading slash) is treated as an **SSH path**; otherwise it's a **local folder** (which must exist and is normalized to an absolute path).

- **Local:** bind-mounted directly with `shift=true`.
- **Remote:** FUSE/`sshfs` mounts *cannot* be idmapped (`shift=true` fails on them). So the script reads the container's id-map base, mounts the remote with `sshfs` presenting every file as the **mapped host uid/gid** the container expects, then bind-mounts it with `shift=false`. The container's normal id map translates the ids straight back. `allow_other` lets the root Incus daemon read the FUSE mount; the host-side mount lives under `~/.cache/incus-claude/<hash>/mnt`.

### 5. Image cache (fast boot)

Re-provisioning on every boot is slow, so provisioning happens **once, into an image**:

- The script computes a hash over `packages.txt`, the always-installed essentials, and your host identity (uid/gid/user/home), giving a local image alias `incus-claude-<hash>`.
- **If that image doesn't exist yet**, it provisions a throwaway *builder* container (full `pacman -Syu`, essentials, `packages.txt`, the matching user, Claude Code, marker), `incus publish`es it under the alias, deletes the builder, and prunes superseded `incus-claude-*` images from older `packages.txt` versions.
- **If the image already exists** (packages.txt unchanged), it's reused as-is.
- Every workspace container is then `incus create`d straight from that image, so a normal boot runs **no `pacman` and no installer** — it just starts and attaches.

The image is only built/fetched when a container actually needs creating; reattaching to an existing container touches neither pacman nor the cache. Images survive `--rm` (they're the shared cache); remove one by hand with `incus image delete incus-claude-<hash>`.

### 6. Provisioning

- **First run only** (guarded by a marker file `~/.incus-claude-provisioned`): the steps above run inside the builder and are baked into the image. Containers created from the cached image already carry the marker, so the per-container provisioning step is a no-op. It still runs as a fallback when the marker isn't visible — e.g. `--mount-home`, where the host home mount shadows the image's baked marker.
- **Every run:** apply `packages.txt` + `--pkg` (installing only missing packages — already-baked ones are fast no-ops), `--with` recipes (only if the tool is absent), and `--run` commands. All idempotent.

### 7. The session

Claude runs as `tmux new-session -A -s claude ... claude "${CLAUDE_ARGS[@]}"` — `-A` attaches if the `claude` session already exists, else creates it. That's what gives you a persistent session: detach with `Ctrl-b d`, and re-running the script reattaches with Claude still alive. Any startup args (from `--yolo` or a trailing `--`) are appended to `claude`; because `tmux -A` ignores the command when attaching to an existing session, those args only take effect on first creation. The script `exec`s `incus exec ... -t` as the matching user with a `PATH` that includes the dirs the curated recipes install into (`~/.local/bin`, `~/.cargo/bin`, `~/.bun/bin`, `~/.deno/bin`).

---

## ⚠️ Concurrency caveat

The container shares your host `~/.claude` directory — including `__store.db`, `sessions/`, `history.jsonl`, and `.credentials.json`. **Use the container *instead of* host Claude, not at the same time.** Running both concurrently risks SQLite/state corruption. The script prints this warning on every launch.

---

## Teardown

```bash
./incus-claude.sh --rm <same path you launched with>
```

This deletes the container and, for remote targets, unmounts the host `sshfs` mount and removes its cache directory. It's safe to run even if the container doesn't exist.

The cached `incus-claude-<hash>` image is **not** removed by `--rm` — it's the shared fast-boot cache, reused by every container built from the same `packages.txt`. Superseded images are pruned automatically when a new one is built; to drop one by hand: `incus image delete incus-claude-<hash>` (or `incus image list` to see them).

---

## Files

| File | Purpose |
| --- | --- |
| `incus-claude.sh` | The entire tool. |
| `packages.txt` | Base pacman package set, applied idempotently every launch. |
