#!/usr/bin/env bash
#
# incus-claude.sh — launch an Arch Linux Incus container with a folder mounted
# in, ready to use Claude Code (auto-logged-in by sharing ~/.claude) and running
# inside a persistent tmux session.
#
# Usage:
#   ./incus-claude.sh [options] <folder | user@host:/remote/path> [-- claude args...]
#
# Options:
#   --rm                 Destroy the container (and any host sshfs mount) for the
#                        given path, then exit.
#   --list, --ls         List the claude containers that currently exist (name,
#                        status, and the workspace each was launched against), then
#                        exit. Takes no folder argument. Use it to find which
#                        container to --rm.
#   --name NAME          Override the auto-derived container name.
#   -w, --worktree NAME  Run against a git worktree of the target repo instead of
#                        the repo itself. Mirrors Claude's native layout: a
#                        worktree at <repo>/.claude/worktrees/<NAME> on branch
#                        worktree-<NAME> (created if absent) becomes the workspace,
#                        so it gets its OWN container + tmux session and runs fully
#                        in parallel with other worktrees of the same repo. Local
#                        git repos only. With --rm, also removes the worktree
#                        (refuses if it has uncommitted changes).
#   --mount-home         Mount all of $HOME instead of just ~/.claude + ~/.claude.json
#                        (fully faithful, avoids the .claude.json staleness caveat,
#                        but exposes your whole home to the container).
#   --pkg "PKG..."       Extra pacman packages, in addition to packages.txt.
#                        Repeatable; values accumulate.
#   --with NAME          Install a curated tool by name. Repeatable. Known recipes:
#                          uv, bun, deno, rust, go, pnpm
#   --run 'CMD'          Arbitrary provisioning command, run as the container user.
#                        Repeatable; runs after packages/recipes. Escape hatch for
#                        anything --pkg/--with don't cover.
#   --yolo               Start Claude with --dangerously-skip-permissions, so it
#                        auto-accepts every tool use and edit with no prompts. Safe
#                        here because the container is an isolated sandbox. Shorthand
#                        for: -- --dangerously-skip-permissions
#   --no-attach          Provision only; print the launch command instead of attaching.
#   -h, --help           Show this help.
#   -- claude args...    Everything after `--` is passed verbatim to `claude` on
#                        launch, e.g. `-- --permission-mode acceptEdits --model opus`
#                        or a starting prompt. (Applied only when the tmux session is
#                        first created; ignored when reattaching to a running one.)
#
# Packages:
#   The base package set lives in `packages.txt` next to this script (one pacman
#   package per line, '#' comments allowed). Edit it and re-run to add packages to
#   an existing container — packages.txt and --pkg/--with/--run are re-applied
#   idempotently on EVERY launch.
#
# Image cache (fast boot):
#   The first launch provisions a throwaway builder (full pacman upgrade,
#   packages.txt, the host-matching user, and Claude Code) and publishes it as a
#   local Incus image named `incus-claude-<hash>`, where <hash> covers packages.txt,
#   the always-installed essentials, and your host identity. Every later container
#   is created straight from that image — no pacman or curl on boot. Change
#   packages.txt and the hash changes, so the image is rebuilt once and stale ones
#   are pruned. Images survive `--rm`; delete one by hand with `incus image delete`.
#
# Design notes:
#   * Auth works by bind-mounting your host ~/.claude (and ~/.claude.json) into the
#     container at the IDENTICAL path, under a container user whose uid/gid/name
#     match the host (auto-detected; override with HOST_UID/HOST_GID/HOST_USER/
#     HOST_HOME env vars). No tokens are copied or extracted.
#   * Mounts use idmapped mounts (disk device shift=true) so host files appear with
#     their real ids inside an UNPRIVILEGED container — no raw.idmap, no /etc/subuid
#     edits.
#   * Claude runs inside tmux (session 'claude'). Detach with Ctrl-b d; re-running
#     this script reattaches to the same session with Claude still running.
#   * WORKTREES (-w NAME): mirrors Claude's native worktree layout
#     (<repo>/.claude/worktrees/<NAME>, branch worktree-<NAME>). Each -w session is
#     a separate worktree → a separate container + tmux session, so multiple
#     worktrees of one repo run in parallel. The whole repo is bind-mounted at its
#     real path (cwd set to the worktree) so git works inside the container.
#   * CONCURRENCY: containers and host Claude share ~/.claude/__store.db,
#     sessions/, history.jsonl and .credentials.json at the same path. Running
#     several at once (multiple containers, the host, or a mix) is fine — it's the
#     same risk class as running multiple host Claude instances side by side, which
#     Claude Code tolerates. Containers run on the same host kernel and a bind mount
#     is the same inode, so SQLite locking/WAL coordination applies across them just
#     as it does across host processes. Sessions/history are shared state, so
#     concurrent instances see and may interleave each other's.
#
set -euo pipefail

# ----- constants ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Base image is fixed: all provisioning (packages.txt, --pkg, recipes) is pacman-only,
# so only an Arch-based image works.
IMAGE="images:archlinux"
PACKAGES_FILE="${SCRIPT_DIR}/packages.txt"
# Essentials the launch mechanism always needs (independent of packages.txt). Baked
# into the cached image; kept in a constant so it can also feed the image cache key.
ESSENTIALS="base-devel curl tmux git ca-certificates which less"
# Bump when the provisioning logic below changes in a way that should invalidate
# already-built cache images (it's mixed into the image hash).
IMG_SCHEMA=1
# Host identity: auto-detected from the invoking user, overridable via env.
# These are bind-mounted into the container as a matching user so mounted files
# (your ~/.claude, your workspace) keep their real ownership inside the box.
HOST_UID="${HOST_UID:-$(id -u)}"
HOST_GID="${HOST_GID:-$(id -g)}"
HOST_USER="${HOST_USER:-$(id -un)}"
HOST_HOME="${HOST_HOME:-$HOME}"
CACHE_DIR="${HOME}/.cache/incus-claude"
PROVISION_MARKER="${HOST_HOME}/.incus-claude-provisioned"

# ----- helpers --------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; }

# ----- arg parsing ----------------------------------------------------------
TARGET=""
CT_NAME=""
DO_RM=0
DO_LIST=0
WORKTREE=""     # -w NAME: run against a git worktree (sibling dir) of the repo
MOUNT_HOME=0
ATTACH=1
EXTRA_PKG=()    # extra pacman packages (in addition to packages.txt)
WITH=()         # curated recipe names
RUN=()          # arbitrary commands
CLAUDE_ARGS=()  # args forwarded verbatim to `claude` on launch

KNOWN_RECIPES="uv bun deno rust go pnpm"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rm)         DO_RM=1; shift ;;
    --list|--ls)  DO_LIST=1; shift ;;
    --name)       CT_NAME="${2:?--name needs a value}"; shift 2 ;;
    -w|--worktree) WORKTREE="${2:?-w/--worktree needs a name}"; shift 2 ;;
    --mount-home) MOUNT_HOME=1; shift ;;
    --pkg)        read -r -a _pkgs <<<"${2:?--pkg needs package name(s)}"
                  EXTRA_PKG+=("${_pkgs[@]}"); shift 2 ;;
    --with)       WITH+=("${2:?--with needs a recipe name}"); shift 2 ;;
    --run)        RUN+=("${2:?--run needs a command}"); shift 2 ;;
    --yolo)       CLAUDE_ARGS+=(--dangerously-skip-permissions); shift ;;
    --no-attach)  ATTACH=0; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; CLAUDE_ARGS+=("$@"); break ;;
    -*)           die "unknown option: $1 (try --help)" ;;
    *)
      [[ -n "$TARGET" ]] && die "only one folder/path argument is allowed"
      TARGET="$1"; shift ;;
  esac
done

# validate --with recipes up front (fail fast, before touching any container)
for r in "${WITH[@]}"; do
  case " $KNOWN_RECIPES " in
    *" $r "*) : ;;
    *) die "unknown --with recipe: '$r'. Known: $KNOWN_RECIPES (or use --pkg / --run)" ;;
  esac
done

# ----- list path ------------------------------------------------------------
# Enumerate the claude containers that currently exist. Names are SHA-derived, so
# we read back the workspace each was launched against from the metadata stamped
# on it at creation time (user.incus-claude.target). Takes no target argument.
if [[ "$DO_LIST" -eq 1 ]]; then
  command -v incus >/dev/null 2>&1 || die "incus is not installed or not on PATH"
  incus info >/dev/null 2>&1 \
    || die "incus daemon not reachable. Set up and start incus first, then retry."
  found=0
  while IFS=, read -r name status; do
    [[ -z "$name" ]] && continue
    target="$(incus config get "$name" user.incus-claude.target 2>/dev/null || true)"
    # Show our containers only: those carrying our metadata, or (for ones made by
    # an older version of this script) those matching the claude-<hash> name.
    [[ -z "$target" && ! "$name" =~ ^claude-[0-9a-f]{8}$ ]] && continue
    if [[ "$found" -eq 0 ]]; then
      printf '%-22s  %-9s  %s\n' "CONTAINER" "STATUS" "WORKSPACE"
      found=1
    fi
    wt="$(incus config get "$name" user.incus-claude.worktree 2>/dev/null || true)"
    label="${target:-(unknown — created by an older version)}"
    [[ -n "$wt" ]] && label="$label  [worktree: $wt]"
    printf '%-22s  %-9s  %s\n' "$name" "$status" "$label"
  done < <(incus list --format csv -c n,s 2>/dev/null)
  [[ "$found" -eq 1 ]] || log "No claude containers found."
  exit 0
fi

# ----- assemble package list (packages.txt + --pkg) -------------------------
# FILE_PKGS  = packages.txt only — baked into the cached image and part of its hash.
# PKGS       = FILE_PKGS + --pkg — the full set re-applied idempotently each launch.
FILE_PKGS=()
if [[ -f "$PACKAGES_FILE" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"            # strip inline comments
    read -r -a _toks <<<"$line"   # split + trim whitespace
    [[ ${#_toks[@]} -gt 0 ]] && FILE_PKGS+=("${_toks[@]}")
  done < "$PACKAGES_FILE"
fi
PKGS=("${FILE_PKGS[@]}" "${EXTRA_PKG[@]}")

[[ -n "$TARGET" ]] || { usage; die "missing <folder | user@host:/path> argument"; }

# ----- classify target: local folder vs ssh path ---------------------------
# An ssh path looks like  user@host:/path  or  host:/path  (but NOT an absolute
# local path, and NOT something with a leading slash before the colon).
IS_SSH=0
SSH_SPEC=""        # user@host:/remote/path
SSH_REMOTE_PATH=""  # /remote/path
GUEST_PATH=""       # path the folder is mounted at inside the container
HOST_SOURCE=""      # what we bind-mount from the host

if [[ "$TARGET" =~ ^[^/:][^:]*:/.+ ]]; then
  IS_SSH=1
  SSH_SPEC="$TARGET"
  SSH_REMOTE_PATH="${TARGET#*:}"
  GUEST_PATH="$SSH_REMOTE_PATH"
else
  # local folder — normalize to absolute
  [[ -d "$TARGET" ]] || die "local folder does not exist: $TARGET"
  HOST_SOURCE="$(cd "$TARGET" && pwd -P)"
  GUEST_PATH="$HOST_SOURCE"
fi

# ----- optional git worktree (-w) -------------------------------------------
# Mirror Claude Code's native worktree layout: a worktree at
# <repo>/.claude/worktrees/<NAME> on branch worktree-<NAME> becomes the session's
# working dir (created with `git worktree add` if absent). We bind-mount the WHOLE
# repo at its real path — so .git, project .claude settings and the worktree are
# all present and git works inside the container — and set the container's cwd to
# the worktree. The container name is keyed off the worktree path, so each -w
# session gets its own container + tmux session and runs in parallel with other
# worktrees of the same repo.
REPO_TOP=""
WT_PATH=""
WORKDIR=""
if [[ -n "$WORKTREE" ]]; then
  [[ "$IS_SSH" -eq 1 ]] && die "-w/--worktree works only with a local git repo, not an ssh path"
  git -C "$HOST_SOURCE" rev-parse --git-dir >/dev/null 2>&1 \
    || die "-w/--worktree requires the target to be inside a git repo: $HOST_SOURCE"
  REPO_TOP="$(git -C "$HOST_SOURCE" rev-parse --show-toplevel)"
  SAFE_WT="${WORKTREE//\//-}"                              # filesystem-safe name
  WT_PATH="${REPO_TOP%/}/.claude/worktrees/${SAFE_WT}"     # native: <repo>/.claude/worktrees/<name>
  WT_BRANCH="worktree-${WORKTREE}"                         # native branch name
  if [[ "$DO_RM" -ne 1 && ! -d "$WT_PATH" ]]; then
    log "Creating git worktree $WT_PATH (branch $WT_BRANCH)"
    mkdir -p "${REPO_TOP%/}/.claude/worktrees"
    if git -C "$REPO_TOP" show-ref --verify --quiet "refs/heads/$WT_BRANCH"; then
      git -C "$REPO_TOP" worktree add "$WT_PATH" "$WT_BRANCH"        # attach existing branch
    else
      git -C "$REPO_TOP" worktree add -b "$WT_BRANCH" "$WT_PATH"     # create new branch
    fi
  fi
  HOST_SOURCE="$REPO_TOP"    # mount the whole repo (covers .git + the worktree)
  GUEST_PATH="$REPO_TOP"     # at its real host path
  WORKDIR="$WT_PATH"         # but start Claude inside the worktree
fi
# cwd inside the container: the worktree for -w, else the mounted workspace root.
: "${WORKDIR:=$GUEST_PATH}"

# ----- derive deterministic container name ----------------------------------
# Worktree sessions append the worktree path so each gets its own container even
# though they all mount the same repo root.
hash_input="${IS_SSH:+ssh:}${SSH_SPEC}${HOST_SOURCE}${WORKTREE:+|wt:${WT_PATH}}"
SHA8="$(printf '%s' "$hash_input" | sha256sum | cut -c1-8)"
CT="${CT_NAME:-claude-${SHA8}}"
SSHFS_MNT="${CACHE_DIR}/${SHA8}/mnt"

# ----- teardown path --------------------------------------------------------
if [[ "$DO_RM" -eq 1 ]]; then
  if incus info "$CT" >/dev/null 2>&1; then
    log "Deleting container $CT"
    incus delete -f "$CT"
  else
    warn "No container named $CT"
  fi
  if mountpoint -q "$SSHFS_MNT" 2>/dev/null; then
    log "Unmounting host sshfs at $SSHFS_MNT"
    fusermount3 -u "$SSHFS_MNT" || fusermount -u "$SSHFS_MNT" || true
  fi
  rm -rf "${CACHE_DIR:?}/${SHA8}" 2>/dev/null || true
  if [[ -n "$WORKTREE" && -d "$WT_PATH" ]]; then
    log "Removing git worktree $WT_PATH"
    git -C "$REPO_TOP" worktree remove "$WT_PATH" 2>/dev/null \
      || warn "Worktree $WT_PATH kept (uncommitted changes?). Remove manually: git -C '$REPO_TOP' worktree remove --force '$WT_PATH'"
  fi
  exit 0
fi

# ----- preflight ------------------------------------------------------------
command -v incus >/dev/null 2>&1 || die "incus is not installed or not on PATH"

# ----- require a working incus daemon (setup is the user's responsibility) --
incus info >/dev/null 2>&1 \
  || die "incus daemon not reachable. Set up and start incus first (storage pool + network), then retry."

# ----- preflight for remote paths (mount happens after the container exists,
# ----- so we can read its id-map base) --------------------------------------
if [[ "$IS_SSH" -eq 1 ]]; then
  command -v sshfs >/dev/null 2>&1 \
    || die "sshfs not installed on host. Install it (Arch: sudo pacman -S sshfs) and retry."
  # The incus daemon runs as root and must be able to read the sshfs mount to
  # bind it into the container. FUSE hides a mount from everyone but the mounting
  # user unless 'allow_other' is set, which a non-root user may only pass when
  # 'user_allow_other' is enabled in /etc/fuse.conf.
  if ! grep -Eq '^[[:space:]]*user_allow_other' /etc/fuse.conf 2>/dev/null; then
    die "sshfs mounts need 'user_allow_other' enabled so the incus daemon (root) can read them.
    Enable it once:  echo user_allow_other | sudo tee -a /etc/fuse.conf
    then retry."
  fi
fi

# ----- provisioning (shared by the image builder and the per-container path) -
# Installs essentials + packages.txt, creates the host-matching user, installs
# Claude Code, and drops the provisioned marker. Idempotent: safe to re-run.
provision() { # $1 = container to provision
  local ct="$1"
  # wait for network/DNS before pacman+curl
  for _ in $(seq 1 60); do
    incus exec "$ct" -- getent hosts archlinux.org >/dev/null 2>&1 && break
    sleep 1
  done
  incus exec "$ct" -- env \
    H_UID="$HOST_UID" H_GID="$HOST_GID" H_USER="$HOST_USER" H_HOME="$HOST_HOME" \
    MARKER="$PROVISION_MARKER" ESSENTIALS="$ESSENTIALS" BASE_PKGS="${FILE_PKGS[*]:-}" \
    bash -s <<'PROVISION'
set -euo pipefail

# Sync + full upgrade (keeps the day-old image's keyring current) and install the
# essentials the launch mechanism needs (tmux/curl/git/base-devel/…) plus the
# packages.txt base set, so they're all baked into the published cache image.
pacman -Syu --noconfirm --needed $ESSENTIALS ${BASE_PKGS:-}

# user/group matching the host so mounted files are owned correctly
getent group "$H_GID" >/dev/null 2>&1 || groupadd -g "$H_GID" "$H_USER"
if ! getent passwd "$H_UID" >/dev/null 2>&1; then
  useradd -o -u "$H_UID" -g "$H_GID" -d "$H_HOME" -s /bin/bash "$H_USER"
fi
# the home dir is auto-created by the bind mounts at runtime, but the image
# builder has no mounts, so make sure it exists before we chown / install into it.
mkdir -p "$H_HOME"
# own the home dir itself (NOT recursive — mounts underneath keep their ownership)
chown "$H_UID:$H_GID" "$H_HOME"

# install Claude Code as the user, into ~/.local/bin
runuser -u "$H_USER" -- env HOME="$H_HOME" USER="$H_USER" \
  bash -c 'curl -fsSL https://claude.ai/install.sh | bash'

# make `claude` resolvable regardless of PATH/login shell
if [[ -x "$H_HOME/.local/bin/claude" ]]; then
  ln -sf "$H_HOME/.local/bin/claude" /usr/local/bin/claude
fi

touch "$MARKER"
PROVISION
}

# ----- cache image identity (build-and-cache, keyed on packages.txt) ---------
# To avoid re-provisioning on every boot, we provision ONCE into a throwaway
# builder container, publish it as a local image aliased by a hash of everything
# baked in (essentials + packages.txt + host identity + schema), and create all
# future containers straight from that image. While packages.txt is unchanged the
# hash is stable, so the image is simply reused — no pacman/curl on boot.
IMG_KEY="$( { printf '%s\n' "schema:$IMG_SCHEMA" \
                            "essentials:$ESSENTIALS" \
                            "identity:${HOST_UID}:${HOST_GID}:${HOST_USER}:${HOST_HOME}"; \
             [[ -f "$PACKAGES_FILE" ]] && cat "$PACKAGES_FILE"; } \
           | sha256sum | cut -c1-12 )"
CACHE_IMAGE="incus-claude-${IMG_KEY}"

# Build the cached image (idempotent: builds only if this hash isn't present).
build_cache_image() {
  incus image info "$CACHE_IMAGE" >/dev/null 2>&1 && return 0
  local builder="incus-claude-build-${IMG_KEY}"
  log "Building cached image $CACHE_IMAGE — one-time; reused while packages.txt is unchanged"
  incus delete -f "$builder" >/dev/null 2>&1 || true   # clear any stale builder
  incus launch "$IMAGE" "$builder"
  for _ in $(seq 1 60); do incus exec "$builder" -- true >/dev/null 2>&1 && break; sleep 0.5; done
  incus exec "$builder" -- true >/dev/null 2>&1 || die "image builder did not become ready"
  provision "$builder"
  incus stop "$builder"
  log "Publishing image $CACHE_IMAGE"
  incus publish "$builder" --alias "$CACHE_IMAGE" --reuse
  incus delete -f "$builder"
  # Drop superseded cache images left behind by older packages.txt versions.
  for old in $(incus image list --format csv --columns l 2>/dev/null \
               | tr ',' '\n' | sed 's/ (.*)//' \
               | grep -E '^incus-claude-[0-9a-f]{12}$' || true); do
    [[ "$old" == "$CACHE_IMAGE" ]] && continue
    log "Removing superseded cache image $old"
    incus image delete "$old" >/dev/null 2>&1 || true
  done
}

# ----- create container (if missing) ----------------------------------------
# Only build/fetch the cached image when we actually need to create a container;
# reattaching to an existing one touches neither pacman nor the image cache.
if ! incus info "$CT" >/dev/null 2>&1; then
  build_cache_image
  log "Creating container $CT from $CACHE_IMAGE"
  incus create "$CACHE_IMAGE" "$CT"
  # Stamp the workspace this container maps to so --list can report it later
  # (names are SHA-derived and can't be reversed to a path).
  incus config set "$CT" user.incus-claude.target="$TARGET" || true
  [[ -n "$WORKTREE" ]] && incus config set "$CT" user.incus-claude.worktree="$WORKTREE" || true
fi
# Defensive: a container from an older version of this script may carry a
# raw.idmap that breaks startup on hosts without matching /etc/subuid entries.
incus config unset "$CT" raw.idmap 2>/dev/null || true

# ----- host-side sshfs for remote paths -------------------------------------
# A FUSE/sshfs mount cannot be idmapped (a disk device with shift=true fails:
# "idmapping abilities are required but aren't supported"). So instead of letting
# incus shift ids, we make sshfs PRESENT every file as the host uid/gid that this
# unprivileged container maps its own ${HOST_UID}/${HOST_GID} to, then bind-mount
# WITHOUT shift — the container's normal id map translates them straight back.
if [[ "$IS_SSH" -eq 1 ]]; then
  # container uid 0 -> this host uid (the base of the container's id map).
  # .current is only populated once the container has started; .next holds the
  # map that will be applied on the next start and exists right after create.
  IDMAP_RAW="$(incus config get "$CT" volatile.idmap.current 2>/dev/null)"
  [[ -n "$IDMAP_RAW" ]] || IDMAP_RAW="$(incus config get "$CT" volatile.idmap.next 2>/dev/null)"
  IDMAP_BASE="$(printf '%s' "$IDMAP_RAW" | grep -o '"Hostid":[0-9]\+' | head -1 | cut -d: -f2)"
  [[ -n "$IDMAP_BASE" ]] || die "could not determine container id-map base for $CT"
  MAP_UID=$((IDMAP_BASE + HOST_UID))
  MAP_GID=$((IDMAP_BASE + HOST_GID))
  mkdir -p "$SSHFS_MNT"
  if ! mountpoint -q "$SSHFS_MNT"; then
    log "Mounting $SSH_SPEC via sshfs at $SSHFS_MNT (as host ${MAP_UID}:${MAP_GID})"
    # Uses your existing SSH keys/agent/known_hosts. allow_other lets the root
    # incus daemon read the mount; uid/gid present files as the container's
    # mapped ids (see note above).
    sshfs "$SSH_SPEC" "$SSHFS_MNT" \
      -o allow_other,uid="$MAP_UID",gid="$MAP_GID",reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,idmap=none
  fi
  HOST_SOURCE="$SSHFS_MNT"
fi

# ----- attach bind-mount devices (idempotent) -------------------------------
# shift=true uses idmapped mounts so host files (owned by uid ${HOST_UID}/gid
# ${HOST_GID}) appear with the SAME ids inside this unprivileged container — no
# raw.idmap and no /etc/subuid changes required. FUSE/sshfs sources can't be
# idmapped, so a remote workspace is added with shift=false (its ownership is
# already handled by the sshfs uid/gid mapping above).
add_disk() { # name source path [shift=true]
  local name="$1" src="$2" dst="$3" shift_opt="${4:-true}"
  if ! incus config device show "$CT" 2>/dev/null | grep -q "^${name}:"; then
    incus config device add "$CT" "$name" disk source="$src" path="$dst" shift="$shift_opt"
  fi
}

if [[ "$MOUNT_HOME" -eq 1 ]]; then
  add_disk home "$HOST_HOME" "$HOST_HOME"
else
  add_disk claudedir  "${HOST_HOME}/.claude"      "${HOST_HOME}/.claude"
  if [[ -f "${HOST_HOME}/.claude.json" ]]; then
    add_disk claudejson "${HOST_HOME}/.claude.json" "${HOST_HOME}/.claude.json"
  fi
fi
if [[ "$IS_SSH" -eq 1 ]]; then
  add_disk workspace "$HOST_SOURCE" "$GUEST_PATH" false
else
  add_disk workspace "$HOST_SOURCE" "$GUEST_PATH"
fi

# ----- start ----------------------------------------------------------------
if [[ "$(incus info "$CT" | awk -F': ' '/^Status/{print $2}')" != "RUNNING" ]]; then
  log "Starting $CT"
  incus start "$CT"
fi

# wait for exec to be available
log "Waiting for container to be ready"
for _ in $(seq 1 60); do incus exec "$CT" -- true >/dev/null 2>&1 && break; sleep 0.5; done
incus exec "$CT" -- true >/dev/null 2>&1 || die "container $CT did not become ready"

# ----- provision (once) -----------------------------------------------------
# Containers created from the cached image already carry the marker, so this is
# normally a no-op. It still runs for containers whose marker isn't present —
# e.g. --mount-home, where the host home mount shadows the image's baked marker.
if ! incus exec "$CT" -- test -f "$PROVISION_MARKER" >/dev/null 2>&1; then
  log "Provisioning $CT (user, base packages, Claude Code)"
  provision "$CT"
else
  log "Container already provisioned — reusing"
fi

# ----- packages.txt + --with + --run, idempotent, every launch --------------
if [[ ${#PKGS[@]} -gt 0 || ${#WITH[@]} -gt 0 || ${#RUN[@]} -gt 0 ]]; then
  log "Ensuring packages (${#PKGS[@]}) + recipes [${WITH[*]:-}] + ${#RUN[@]} run-cmd(s)"
  incus exec "$CT" -- env \
    H_USER="$HOST_USER" H_HOME="$HOST_HOME" \
    PKGS="${PKGS[*]:-}" \
    WITH="${WITH[*]:-}" \
    RUN_CMDS="$(printf '%s\n' "${RUN[@]:-}")" \
    bash -s <<'EXTRAS'
set -euo pipefail

asuser() { runuser -u "$H_USER" -- env HOME="$H_HOME" USER="$H_USER" PATH="$H_HOME/.local/bin:$H_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" bash -c "$1"; }

# --- pacman packages: install only the ones not already present ----------
if [[ -n "${PKGS// }" ]]; then
  missing=()
  for p in $PKGS; do pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [[ ${#missing[@]} -gt 0 ]]; then
    # -Syu avoids the partial-upgrade breakage that bare -Sy can cause on Arch.
    pacman -Syu --noconfirm --needed "${missing[@]}"
  fi
fi

# --- curated recipes: install only if the tool is absent -----------------
recipe() {
  case "$1" in
    uv)   asuser 'command -v uv   >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh' ;;
    bun)  asuser 'command -v bun  >/dev/null || curl -fsSL https://bun.sh/install | bash' ;;
    deno) asuser 'command -v deno >/dev/null || curl -fsSL https://deno.land/install.sh | sh' ;;
    pnpm) asuser 'command -v pnpm >/dev/null || curl -fsSL https://get.pnpm.io/install.sh | sh -' ;;
    rust) asuser 'command -v cargo >/dev/null || curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y' ;;
    go)   command -v go >/dev/null 2>&1 || pacman -S --noconfirm --needed go ;;
    *)    echo "!! unknown recipe '$1' (skipped)" >&2 ;;
  esac
}
for r in $WITH; do recipe "$r"; done

# --- arbitrary commands (run as the user, every launch) ------------------
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  echo "==> --run: $cmd" >&2
  asuser "$cmd"
done <<<"$RUN_CMDS"
EXTRAS
fi

# ----- concurrency note -----------------------------------------------------
log "Container shares ~/.claude with the host. Running it alongside host/other-container Claude is fine — same risk class as multiple host instances."

# ----- attach or print ------------------------------------------------------
# PATH includes the dirs the curated recipes install into so uv/cargo/bun/etc.
# resolve in the session (incus exec is not a login shell).
SESSION_PATH="${HOST_HOME}/.local/bin:${HOST_HOME}/.cargo/bin:${HOST_HOME}/.bun/bin:${HOST_HOME}/.deno/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENTER=(incus exec "$CT" --user "$HOST_UID" --group "$HOST_GID" --cwd "$WORKDIR"
       --env HOME="$HOST_HOME" --env "USER=$HOST_USER" --env "PATH=$SESSION_PATH"
       --env TERM="${TERM:-xterm}" -t)

# Run Claude inside a persistent tmux session named 'claude'. -A attaches to the
# session if it already exists (so re-running reattaches with Claude still alive),
# else creates it; -c sets the working directory. Any CLAUDE_ARGS (from --yolo or a
# trailing `--`) are appended to `claude` — they take effect only when the session
# is first created; on reattach tmux ignores the command and Claude keeps running.
TMUX_CMD=(tmux new-session -A -s claude -c "$WORKDIR" claude "${CLAUDE_ARGS[@]}")

if [[ "$ATTACH" -eq 1 ]]; then
  log "Launching Claude Code in tmux in $CT (cwd: $WORKDIR; detach: Ctrl-b d)"
  exec "${ENTER[@]}" -- "${TMUX_CMD[@]}"
else
  log "Container ready. To attach to Claude in tmux:"
  printf '    %q ' "${ENTER[@]}" -- "${TMUX_CMD[@]}"; echo
fi
