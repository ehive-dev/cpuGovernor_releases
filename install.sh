#!/usr/bin/env bash
# cpuGovernor Installer/Updater (Debian/Ubuntu)
# Main functions:
# - need_root / need_tools: prerequisites
# - api: GitHub API fetch with optional token
# - get_release_json_auto / get_release_json_by_tag: release selection (stable/pre/tag)
# - pick_deb_from_release: choose .deb asset from release JSON
# - install_deb: dpkg install with apt --fix-broken fallback
# - service_restart_and_check: enable/restart service and verify it is active
#
# Usage:
#   sudo bash install.sh                   # newest STABLE (fallback to PRE if no stable)
#   sudo bash install.sh --pre             # newest PRE (fallback to stable if no pre)
#   sudo bash install.sh --tag v0.1.2      # specific tag
#   sudo bash install.sh --repo owner/repo # override repo
#
# Optional env:
#   export GITHUB_TOKEN=...                # higher API limits / private repos
#   export CPU_GOVERNOR_ASSET_REGEX='^cpuGovernor_.*_arm64\.deb$'
#   export CPU_GOVERNOR_SERVICE='cpuGovernor'
#   export CPU_GOVERNOR_PKG='cpuGovernor'

set -euo pipefail
umask 022

APP_DISPLAY="cpuGovernor"

# Defaults (can be overridden)
REPO="${REPO:-ehive-dev/cpuGovernor-releases}"
CHANNEL="stable"     # stable | pre
TAG="${TAG:-}"       # vX.Y.Z

SERVICE_NAME="${CPU_GOVERNOR_SERVICE:-cpuGovernor}"
PKG_NAME="${CPU_GOVERNOR_PKG:-cpuGovernor}"

# Match both common naming styles (cpuGovernor_... or cpugovernor_...)
ASSET_REGEX="${CPU_GOVERNOR_ASSET_REGEX:-^(cpuGovernor|cpugovernor)_.*_(all|arm64|amd64)\\.deb$}"

# ---------- CLI Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pre) CHANNEL="pre"; shift ;;
    --stable) CHANNEL="stable"; shift ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --service) SERVICE_NAME="${2:-}"; shift 2 ;;
    --pkg) PKG_NAME="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: sudo $0 [--pre|--stable] [--tag vX.Y.Z] [--repo owner/repo] [--service NAME] [--pkg NAME]

Env:
  GITHUB_TOKEN
  CPU_GOVERNOR_ASSET_REGEX
  CPU_GOVERNOR_SERVICE
  CPU_GOVERNOR_PKG
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---------- Helpers ----------
info(){ printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok(){   printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; }

need_root(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Bitte als root ausführen (sudo)."
    exit 1
  fi
}

need_tools(){
  command -v curl >/dev/null || { apt-get update -y; apt-get install -y curl; }
  command -v jq   >/dev/null || { apt-get update -y; apt-get install -y jq; }
  command -v dpkg-deb >/dev/null || { apt-get update -y; apt-get install -y dpkg; }
  command -v systemctl >/dev/null || { warn "systemctl nicht gefunden (kein systemd?)"; }
}

api(){
  local url="$1"
  local hdr=(-H "Accept: application/vnd.github+json")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL "${hdr[@]}" "$url"
}

trim_one_line(){
  tr -d '\r' | tr -d '\n' | sed 's/[[:space:]]\+$//'
}

installed_version(){
  # Try a few common package names (dpkg package names are typically lowercase)
  local v=""
  v="$(dpkg-query -W -f='${Version}\n' "$PKG_NAME" 2>/dev/null || true)"
  [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }

  # fallbacks
  v="$(dpkg-query -W -f='${Version}\n' "cpugovernor" 2>/dev/null || true)"
  [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }

  v="$(dpkg-query -W -f='${Version}\n' "cpu-governor" 2>/dev/null || true)"
  [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }

  return 0
}

get_release_json_by_tag(){
  # stdout JSON, non-zero on error
  api "https://api.github.com/repos/${1}/releases/tags/${TAG}"
}

get_release_json_auto(){
  # stdout JSON (single object), non-zero on error
  local repo="$1"
  local releases
  releases="$(api "https://api.github.com/repos/${repo}/releases?per_page=50")"

  # Prefer channel, fallback to other
  printf '%s' "$releases" | jq -c --arg ch "$CHANNEL" '
    [ .[] | select(.draft==false) ] as $r
    | if ($r|length)==0 then null
      else if $ch=="pre"
        then ( $r | map(select(.prerelease==true))  | .[0] ) // ( $r | map(select(.prerelease==false)) | .[0] )
        else ( $r | map(select(.prerelease==false)) | .[0] ) // ( $r | map(select(.prerelease==true))  | .[0] )
      end end
  '
}

pick_deb_from_release(){
  # stdin: release JSON (single object)
  jq -r --arg re "$ASSET_REGEX" '
    .assets // []
    | map(select(.name | test($re)))
    | .[0].browser_download_url // empty
  '
}

repo_candidates(){
  # If the default repo is wrong/missing releases, try common variants automatically.
  # (This prevents issues like cpu_governor vs cpuGovernor vs *-releases vs *_releases)
  cat <<EOF
${REPO}
ehive-dev/cpuGovernor
ehive-dev/cpu_governor
ehive-dev/cpu_governor-releases
ehive-dev/cpuGovernor_releases
ehive-dev/cpu-governor
ehive-dev/cpu-governor-releases
EOF
}

fetch_release_with_fallbacks(){
  local repo
  local rel=""
  local used=""

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue

    set +e
    if [[ -n "$TAG" ]]; then
      rel="$(get_release_json_by_tag "$repo" 2>/dev/null)"
      rc=$?
    else
      rel="$(get_release_json_auto "$repo" 2>/dev/null)"
      rc=$?
    fi
    set -e

    if [[ $rc -eq 0 && -n "${rel:-}" && "${rel}" != "null" ]]; then
      local tag_name
      tag_name="$(printf '%s' "$rel" | jq -r '.tag_name // empty' 2>/dev/null || true)"
      if [[ -n "$tag_name" ]]; then
        used="$repo"
        printf '%s\n' "$used"
        printf '%s\n' "$rel"
        return 0
      fi
    fi
  done < <(repo_candidates)

  return 1
}

install_deb(){
  local deb_file="$1"

  dpkg-deb --info "$deb_file" >/dev/null 2>&1 || { err "Ungültiges .deb"; return 1; }

  info "Installiere Paket ..."
  set +e
  dpkg -i "$deb_file"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    warn "dpkg -i scheiterte — versuche apt --fix-broken"
    apt-get update -y
    apt-get -f install -y
    dpkg -i "$deb_file"
  fi
  return 0
}

service_restart_and_check(){
  local svc="$1"

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl nicht verfügbar → Service-Check übersprungen."
    return 0
  fi

  systemctl daemon-reload || true

  # Enable/restart if unit exists (unit names can be case-sensitive, so keep as provided)
  if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
    systemctl enable "${svc}" >/dev/null 2>&1 || true
    systemctl restart "${svc}" || true
  else
    # Fallback: try lower-case variant
    local svc_lc
    svc_lc="$(printf '%s' "$svc" | tr '[:upper:]' '[:lower:]')"
    if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "${svc_lc}.service"; then
      warn "Service heißt offenbar '${svc_lc}.service' (statt '${svc}.service')"
      systemctl enable "${svc_lc}" >/dev/null 2>&1 || true
      systemctl restart "${svc_lc}" || true
      svc="$svc_lc"
    else
      err "Kein systemd Unit gefunden: ${svc}.service"
      return 1
    fi
  fi

  if systemctl is-active --quiet "${svc}"; then
    ok "Service aktiv: ${svc}.service"
    return 0
  fi

  err "Service ist nicht active: ${svc}.service"
  journalctl -u "${svc}.service" -n 200 --no-pager -o cat || true
  return 1
}

# ---------- Start ----------
need_root
need_tools

OLD_VER="$(installed_version || true)"
if [[ -n "$OLD_VER" ]]; then
  info "Installiert: ${APP_DISPLAY} ${OLD_VER}"
else
  info "Keine bestehende ${APP_DISPLAY}-Installation gefunden."
fi

info "Ermittle Release (${CHANNEL}${TAG:+, tag=$TAG}) ..."
set +e
mapfile -t F < <(fetch_release_with_fallbacks 2>/dev/null)
RC=$?
set -e

if [[ $RC -ne 0 || ${#F[@]} -lt 2 ]]; then
  err "Keine passende Release gefunden."
  err "Ursachen:"
  err "  - falscher Repo-Name (cpu_governor vs cpuGovernor vs *-releases)"
  err "  - im Repo existiert noch keine GitHub Release (nur Tags reichen nicht)"
  err "Fix:"
  err "  - GitHub Release erstellen und .deb Asset anhängen (Name passend zu Regex)."
  err "  - Oder Repo explizit angeben: --repo ehive-dev/cpuGovernor-releases"
  err "Regex aktuell: ${ASSET_REGEX}"
  exit 1
fi

USED_REPO="${F[0]}"
RELEASE_JSON="${F[1]}"

ok "Verwende Repo: ${USED_REPO}"

TAG_NAME="$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name // empty')"
if [[ -z "$TAG_NAME" ]]; then
  err "Release JSON ohne tag_name."
  exit 1
fi
[[ -z "$TAG" ]] && TAG="$TAG_NAME"
VER_CLEAN="${TAG#v}"

DEB_URL_RAW="$(printf '%s' "$RELEASE_JSON" | pick_deb_from_release || true)"
DEB_URL="$(printf '%s' "$DEB_URL_RAW" | trim_one_line)"

if [[ -z "$DEB_URL" ]]; then
  err "Kein .deb Asset passend zu Regex in Release ${TAG} gefunden."
  err "Repo: ${USED_REPO}"
  err "Regex: ${ASSET_REGEX}"
  err "Tipp: Assets listen:"
  err "  curl -fsS \"https://api.github.com/repos/${USED_REPO}/releases/tags/${TAG}\" | jq -r '.assets[].name'"
  exit 1
fi

TMPDIR="$(mktemp -d -t cpuGovernor-install.XXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
DEB_FILE="${TMPDIR}/${APP_DISPLAY}_${VER_CLEAN}.deb"

info "Lade: ${DEB_URL}"
curl -fL --retry 3 --retry-delay 1 -o "$DEB_FILE" "$DEB_URL"

# Stop service if present (postinst will restart)
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-units --type=service 2>/dev/null | grep -qE "^(cpuGovernor|cpugovernor)\.service"; then
    systemctl stop cpuGovernor >/dev/null 2>&1 || true
    systemctl stop cpugovernor >/dev/null 2>&1 || true
  fi
fi

install_deb "$DEB_FILE"
ok "Installiert: ${APP_DISPLAY} ${VER_CLEAN}"

service_restart_and_check "$SERVICE_NAME"

NEW_VER="$(installed_version || echo "$VER_CLEAN")"
ok "Fertig: ${APP_DISPLAY} ${OLD_VER:+${OLD_VER} → }${NEW_VER}"
