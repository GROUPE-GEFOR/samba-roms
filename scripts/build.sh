#!/bin/bash
# Compile Samba roms pour une distribution Debian.
# À lancer en root dans un conteneur debian:<distribution> propre, depuis la racine du dépôt.
#
#   scripts/build.sh <version Samba> <révision roms> <distribution> [version Debian du donneur]
#   ex. : scripts/build.sh 4.24.8 1 trixie
#
# Résultat : out/<distribution>/*.deb, *.changes, *.buildinfo, plus patches/ (patches roms rafraîchis).
set -euo pipefail

VERSION=${1:?version Samba}
REV=${2:?révision roms}
DIST=${3:?distribution}
DONOR_OVERRIDE=${4:-}

# Clé « Samba Distribution Verification Key » attendue sur le tarball upstream
SAMBA_KEY_FPR=81F5E2832BD2545A1897B713AA99442FB680B620

ROOT=$(pwd)
BRANCH=$(echo "$VERSION" | cut -d. -f1,2)
case $DIST in
  bookworm) DEBN=12 ;;
  trixie)   DEBN=13 ;;
  forky)    DEBN=14 ;;
  *) echo "distribution inconnue : $DIST" >&2; exit 1 ;;
esac

log() { echo; echo "===== $* ====="; }
die() { echo "::error::$*" >&2; exit 1; }

# --- cible dans targets.conf
read -r _ _ DONOR PROFILES EXTRA_SUITE < <(awk -v b="$BRANCH" -v d="$DIST" '$1==b && $2==d' "$ROOT/targets.conf") \
  || die "aucune ligne « $BRANCH $DIST » dans targets.conf"
[ -n "$DONOR_OVERRIDE" ] && DONOR=$DONOR_OVERRIDE
[ "$PROFILES" = "-" ] && PROFILES=""
[ "$EXTRA_SUITE" = "-" ] && EXTRA_SUITE=""
DEB_VERSION="2:${VERSION}-roms-${REV}+deb${DEBN}"

log "Samba $VERSION → $DEB_VERSION ($DIST), donneur Debian $DONOR, profils « ${PROFILES:-aucun} », dépôt en plus « ${EXTRA_SUITE:-aucun} »"

# --- APT : sources deb-src (+ backports si demandé)
log "Préparation d'APT"
SUITES="$DIST $DIST-updates"
[ -n "$EXTRA_SUITE" ] && SUITES="$SUITES $EXTRA_SUITE"
cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: $SUITES
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: http://deb.debian.org/debian-security
Suites: $DIST-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
  build-essential devscripts quilt curl ca-certificates gpg gpgv jq xz-utils

WORK=$(mktemp -d /tmp/samba-roms.XXXXXX)
cd "$WORK"

# --- téléchargement du donneur : deb.debian.org, sinon snapshot.debian.org
fetch_debian() {   # $1 = nom de fichier
  if curl -fsSL --retry 3 -o "$1" "https://deb.debian.org/debian/pool/main/s/samba/$1"; then
    return 0
  fi
  echo "$1 absent de deb.debian.org, recherche sur snapshot.debian.org"
  local hash
  hash=$(curl -fsSL --retry 3 "https://snapshot.debian.org/mr/package/samba/${DONOR}/srcfiles?fileinfo=1" \
         | jq -r --arg n "$1" '.fileinfo | to_entries[] | select(any(.value[]; .name == $n)) | .key' | head -1)
  [ -n "$hash" ] || die "$1 introuvable sur snapshot.debian.org"
  curl -fsSL --retry 3 -o "$1" "https://snapshot.debian.org/file/$hash"
}

log "Téléchargement du packaging Debian $DONOR"
DSC="samba_${DONOR#*:}.dsc"
fetch_debian "$DSC"
read -r DEBTAR_SHA DEBTAR < <(awk '/^Checksums-Sha256:/{f=1;next} /^[^ ]/{f=0} f && $3 ~ /\.debian\.tar\./{print $1, $3}' "$DSC")
[ -n "${DEBTAR:-}" ] || die "pas de debian.tar.* dans $DSC"
fetch_debian "$DEBTAR"
echo "$DEBTAR_SHA  $DEBTAR" | sha256sum -c -

log "Téléchargement de samba-$VERSION.tar.gz et vérification de sa signature"
UP=https://download.samba.org/pub/samba/stable
curl -fsSL --retry 3 -O "$UP/samba-$VERSION.tar.gz"
curl -fsSL --retry 3 -O "$UP/samba-$VERSION.tar.asc"

SRC="samba-${VERSION}-roms"
mkdir "$SRC"
tar -xzf "samba-$VERSION.tar.gz" -C "$SRC" --strip-components=1
tar -xf "$DEBTAR" -C "$SRC"
ln -s "samba-$VERSION.tar.gz" "samba_${VERSION}-roms.orig.tar.gz"

# Clé de signature : celle fournie par Debian dans debian/upstream/, avec contrôle de l'empreinte.
# La clé peut être marquée expirée : seule compte une signature valide de la bonne clé (VALIDSIG).
[ -f "$SRC/debian/upstream/signing-key.asc" ] || die "pas de debian/upstream/signing-key.asc dans le donneur"
gpg --dearmor < "$SRC/debian/upstream/signing-key.asc" > "$WORK/samba-key.gpg"
gzip -dc "samba-$VERSION.tar.gz" | gpgv --status-fd 1 --keyring "$WORK/samba-key.gpg" "samba-$VERSION.tar.asc" - > gpgv.status 2>&1 || true
grep -E "^\[GNUPG:\] VALIDSIG .* ${SAMBA_KEY_FPR}$" gpgv.status \
  || { cat gpgv.status; die "signature du tarball samba-$VERSION invalide"; }

cd "$SRC"

# --- patches : ceux de Debian (retirés s'ils sont déjà dans upstream), puis ceux de roms
log "Application des patches"
export QUILT_PATCHES=debian/patches
export QUILT_REFRESH_ARGS="-p ab --no-timestamps --no-index"
cp "$ROOT"/patches/roms-*.patch debian/patches/   # y compris les patches désactivés, pour mémoire
{ echo; echo "# --- patches roms (dépôt samba-roms)"; grep -v -E '^[[:space:]]*$' "$ROOT/patches/series.roms"; } >> debian/patches/series

ROMS_PATCHES=$(grep -v -E '^[[:space:]]*(#|$)' "$ROOT/patches/series.roms")
while p=$(quilt next 2>/dev/null); do
  p=${p#debian/patches/}
  if quilt push -q > "$WORK/quilt.log" 2>&1; then
    quilt refresh > /dev/null
    continue
  fi
  # quilt push n'a rien laissé d'appliqué : on cherche pourquoi
  if echo "$ROMS_PATCHES" | grep -qxF "$p"; then
    cat "$WORK/quilt.log"
    die "le patch roms $p ne s'applique plus sur Samba $VERSION : à mettre à jour dans patches/"
  fi
  if patch -p1 -R --dry-run -s -f < "debian/patches/$p" > /dev/null 2>&1; then
    echo "::warning::patch Debian $p déjà intégré dans Samba $VERSION : retiré"
    sed -i "s|^${p}\$|#${p}  # déjà intégré dans $VERSION (samba-roms)|" debian/patches/series
  else
    cat "$WORK/quilt.log"
    die "le patch Debian $p ne s'applique pas sur Samba $VERSION : choisir un autre donneur dans targets.conf"
  fi
done
quilt applied | sed 's/^/  appliqué : /'

# Suffixe de version « roms » (VERSION.orig garde l'original)
if [ ! -f VERSION.orig ]; then
  mv VERSION VERSION.orig
  sed -r -e 's/^(SAMBA_VERSION_VENDOR_SUFFIX).*/\1=roms/' VERSION.orig > VERSION
fi

export DEBEMAIL="samba-roms@users.noreply.github.com" DEBFULLNAME="samba-roms CI"
dch --preserve --newversion "$DEB_VERSION" --distribution "$DIST" --force-distribution --force-bad-version \
  "Samba $VERSION, packaging Debian $DONOR, patches roms (révision $REV)."
dch --append "Patches roms : $(echo $ROMS_PATCHES | sed 's/ /, /g')."
[ -n "$PROFILES" ] && dch --append "Profils de compilation : $PROFILES."

# --- dépendances de compilation
log "Installation des dépendances de compilation"
APT_OPTS=()
[ -n "$EXTRA_SUITE" ] && APT_OPTS+=(-t "$EXTRA_SUITE")
[ -n "$PROFILES" ] && APT_OPTS+=(--build-profiles="$PROFILES")
apt-get build-dep -y -q "${APT_OPTS[@]}" ./

# --- compilation
log "Compilation ($(nproc) processeurs)"
export DEB_BUILD_PROFILES="${PROFILES//,/ }"
export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
start=$(date +%s)
dpkg-buildpackage -b -us -uc -nc
echo "Compilation terminée en $(( ($(date +%s) - start) / 60 )) min"

# --- résultats
OUT="$ROOT/out/$DIST"
mkdir -p "$OUT/patches"
mv ../*.deb ../*.changes ../*.buildinfo "$OUT/"
cp debian/patches/series debian/patches/roms-*.patch "$OUT/patches/"
{
  printf 'samba_version=%q\n' "$VERSION"
  printf 'deb_version=%q\n' "$DEB_VERSION"
  printf 'distribution=%q\n' "$DIST"
  printf 'donor=%q\n' "$DONOR"
  printf 'profiles=%q\n' "${PROFILES:--}"
  printf 'extra_suite=%q\n' "${EXTRA_SUITE:--}"
  printf 'roms_patches=%q\n' "$(echo $ROMS_PATCHES)"
} > "$OUT/build-info.txt"
ls -la "$OUT"
