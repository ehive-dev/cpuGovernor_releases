#!/usr/bin/env bash
# cpuGovernor Installer/Updater (Debian/Ubuntu)
#
# Main functions:
# - api / get_release_json_*: GitHub Release Auswahl (stable/pre oder per Tag)
# - pick_deb_from_release: passendes .deb Asset über Regex auswählen
# - detect_pkg_and_service_from_deb: Paketname + Service-Unit aus dem .deb ableiten
# - install_deb_with_fixbroken: dpkg -i mit apt --fix-broken Fallback
#
# Usage:
#   sudo bash install.sh                 # newest STABLE (fallback to PRE if no stable)
#   sudo bash install.sh --pre           # newest PRE-RELEASE (fallback to stable if no pre)
#   sudo bash install.sh --tag v0.1.1    # specific tag
#   sudo bash install.sh --repo owner/repo
#
# Optional:
#   export GITHUB_TOKEN=...              # higher API limits / private repos
#   export CPU_GOVERNOR_ASSET_REGEX='^cpuGovernor_.*_(all|arm64|amd64)\.deb$'
#   export CPU_GOVERNOR_SERVICE='cpuGovernor.service'   # override service unit name
#   export CPU_GOVERNOR_PACKAGE='cpugovernor'           # override dpkg package name

set -euo pipefail
umask 022

APP_DISPLAY="cpuGovernor"
REPO="${REPO:-ehive-dev/cpu_governor}"
CHANNEL="stable"     # stable | pre
TAG="${TAG:-}"       # vX.Y.Z

ASSET_REGEX="${CPU_GOVERNOR_ASSET_REGEX:-^cpuGovernor_.*_(all|arm64|amd64)\\.deb$}"
OVERRIDE_SERVICE="${CPU_GOVERNOR_SERVICE:-}"
OVERRIDE_PACKAGE="${CPU_GOVERNOR_PACKAGE:-}"

# ---------- CLI-Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pre) CHANNEL="pre"; shift ;;
    --stable) CHANNEL="stable"; shift ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --asset-regex) ASSET_REGEX="${2:-}"; shift 2 ;;
    --service) OVERRIDE_SERVICE="${2:-}"; shift 2 ;;
    --package) OVERRIDE_PACKAGE="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: sudo $0 [--pre|--stable] [--tag vX.Y.Z] [--repo owner/repo]
               [--asset-regex 'regex'] [--service cpuGovernor.service] [--package pkgname]
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
  local pkg="$1"
  dpkg-query -W -f='${Version}\n' "$pkg" 2>/dev/null || true
}

# ---------- Release selection ----------
get_release_json_by_tag(){
  api "https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
}

get_release_json_auto(){
  local releases
  releases="$(api "https://api.github.com/repos/${REPO}/releases?per_page=50")"

  # Prefer channel, fallback to the other
  printf '%s' "$releases" | jq -c --arg ch "$CHANNEL" '
    [ .[] | select(.draft==false) ] as $r
    | if $ch=="pre"
      then ( $r | map(select(.prerelease==true)) | .[0] ) // ( $r | map(select(.prerelease==false)) | .[0] )
      else ( $r | map(select(.prerelease==false)) | .[0] ) // ( $r | map(select(.prerelease==true)) | .[0] )
      end
  '
}

pick_deb_from_release(){
  jq -r --arg re "$ASSET_REGEX" '
    .assets // []
    | map(select(.name | test($re)))
    | .[0].browser_download_url // empty
  '
}

detect_pkg_and_service_from_deb(){
  local deb="$1"
  local pkg=""
  local unit=""

  if [[ -n "$OVERRIDE_PACKAGE" ]]; then
    pkg="$OVERRIDE_PACKAGE"
  else
    pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
  fi

  if [[ -n "$OVERRIDE_SERVICE" ]]; then
    unit="$OVERRIDE_SERVICE"
  else
    # try to discover *.service inside the deb
    mapfile -t svc_files < <(
      dpkg-deb -c "$deb" 2>/dev/null \
        | awk '{print $NF}' \
        | grep -E '\.service$' \
        | xargs -r -n1 basename \
        | sort -u
    )

    if [[ ${#svc_files[@]} -eq 1 ]]; then
      unit="${svc_files[0]}"
    elif [[ ${#svc_files[@]} -gt 1 ]]; then
      # prefer something with "cpu" in name
      for s in "${svc_files[@]}"; do
        if echo "$s" | grep -qi 'cpu'; then
          unit="$s"
          break
        fi
      done
      [[ -z "$unit" ]] && unit="${svc_files[0]}"
    else
      # fallback: assume unit name equals display name
      unit="${APP_DISPLAY}.service"
    fi
  fi

  if [[ -z "$pkg" ]]; then
    err "Konnte Paketname aus .deb nicht ermitteln. (Override mit CPU_GOVERNOR_PACKAGE=...)"
    exit 1
  fi
  if [[ -z "$unit" ]]; then
    err "Konnte Service-Unit nicht ermitteln. (Override mit CPU_GOVERNOR_SERVICE=...)"
    exit 1
  fi

  echo "${pkg}:::${unit}"
}

install_deb_with_fixbroken(){
  local deb="$1"
  local rc=0

  set +e
  dpkg -i "$deb"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    warn "dpkg -i scheiterte — versuche apt --fix-broken"
    apt-get update -y
    apt-get -f install -y
    dpkg -i "$deb"
  fi
}

# ---------- Start ----------
need_root
need_tools

info "Ermittle Release aus ${REPO} (${CHANNEL}${TAG:+, tag=$TAG}) ..."
set +e
if [[ -n "$TAG" ]]; then
  RELEASE_JSON="$(get_release_json_by_tag 2>/dev/null)"
  RC=$?
else
  RELEASE_JSON="$(get_release_json_auto 2>/dev/null)"
  RC=$?
fi
set -e

if [[ $RC -ne 0 || -z "${RELEASE_JSON:-}" || "${RELEASE_JSON}" == "null" ]]; then
  err "Keine passende Release gefunden (Repo: ${REPO})."
  err "Hinweis: Repo-Name prüfen und ggf. GITHUB_TOKEN setzen (limits/private)."
  exit 1
fi

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
  err "Regex: ${ASSET_REGEX}"
  err "Tipp: Assets listen: curl -fsS \"https://api.github.com/repos/${REPO}/releases/tags/${TAG}\" | jq -r '.assets[].name'"
  exit 1
fi

TMPDIR="$(mktemp -d -t cpuGovernor-install.XXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
DEB_FILE="${TMPDIR}/${APP_DISPLAY}_${VER_CLEAN}.deb"

info "Lade: ${DEB_URL}"
curl -fL --retry 3 --retry-delay 1 -o "$DEB_FILE" "$DEB_URL"

dpkg-deb --info "$DEB_FILE" >/dev/null 2>&1 || { err "Ungültiges .deb"; exit 1; }

PKG_AND_UNIT="$(detect_pkg_and_service_from_deb "$DEB_FILE")"
PKG_NAME="${PKG_AND_UNIT%%:::*}"
UNIT_NAME="${PKG_AND_UNIT##*:::}"

OLD_VER="$(installed_version "$PKG_NAME")"
if [[ -n "$OLD_VER" ]]; then
  info "Installiert: ${PKG_NAME} ${OLD_VER}"
else
  info "Keine bestehende ${PKG_NAME}-Installation gefunden."
fi
info "Ziel: ${PKG_NAME} (tag=${TAG}) | Unit: ${UNIT_NAME}"

# Stop service if present (postinst will restart)
if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -Fxq "$UNIT_NAME"; then
  systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || true
fi

info "Installiere Paket ..."
install_deb_with_fixbroken "$DEB_FILE"
ok "Installiert: ${PKG_NAME} ${VER_CLEAN}"

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || true
systemctl restart "$UNIT_NAME" >/dev/null 2>&1 || true

if systemctl is-active --quiet "$UNIT_NAME"; then
  NEW_VER="$(installed_version "$PKG_NAME" || echo "$VER_CLEAN")"
  ok "Fertig: ${PKG_NAME} ${OLD_VER:+${OLD_VER} → }${NEW_VER} (service active: ${UNIT_NAME})"
  exit 0
else
  err "Service ist nicht active: ${UNIT_NAME}"
  journalctl -u "$UNIT_NAME" -n 200 --no-pager -o cat || true
  exit 1
fi
