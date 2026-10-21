#!/bin/bash
# Ajoute les paquets compilés au dépôt APT signé (contenu de la branche gh-pages).
#
#   APT_GPG_PRIVATE_KEY=... scripts/publish-apt.sh <dossier gh-pages> <dossier des artefacts debs-*>
#
# Les paquets -dbgsym ne sont pas publiés dans le dépôt APT (ils restent dans les Releases GitHub).
# reprepro refuse de republier une version déjà présente avec un contenu différent :
# dans ce cas, relancer la compilation avec une révision roms supérieure.
set -euo pipefail

SITE=$(realpath "${1:?dossier gh-pages}")
DL=$(realpath "${2:?dossier des artefacts}")
ROOT=$(pwd)

[ -n "${APT_GPG_PRIVATE_KEY:-}" ] || { echo "::error::secret APT_GPG_PRIVATE_KEY absent" >&2; exit 1; }
export GNUPGHOME=$(mktemp -d)
trap 'rm -rf "$GNUPGHOME"' EXIT
echo "$APT_GPG_PRIVATE_KEY" | gpg --batch --quiet --import
KEYID=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')
echo "Clé de signature : $KEYID"

REPREPRO=(reprepro --basedir "$SITE/.reprepro" --outdir "$SITE")
mkdir -p "$SITE/.reprepro/conf"
sed "s/@KEYID@/$KEYID/" "$ROOT/apt/distributions" > "$SITE/.reprepro/conf/distributions"

# Un composant par branche (samba-4.22, samba-4.24…) : un serveur ne suit que sa branche
for dir in "$DL"/debs-*; do
  dist=${dir##*/debs-}
  samba_version=$(. "$dir/build-info.txt"; echo "$samba_version")
  comp="samba-${samba_version%.*}"
  grep -q -E "^Components:.* $comp( |\$)" "$ROOT/apt/distributions" \
    || { echo "::error::composant $comp absent de apt/distributions" >&2; exit 1; }
  mapfile -t debs < <(ls "$dir"/*.deb | grep -v -- '-dbgsym_')
  echo "--- $dist / $comp : ${#debs[@]} paquets"
  "${REPREPRO[@]}" -C "$comp" includedeb "$dist" "${debs[@]}"
done
"${REPREPRO[@]}" export

gpg --export "$KEYID" > "$SITE/samba-roms.gpg"
gpg --armor --export "$KEYID" > "$SITE/samba-roms.asc"
cp "$ROOT/apt/index.html" "$SITE/index.html"
touch "$SITE/.nojekyll"
{
  for dist in $(awk '/^Codename:/ {print $2}' "$ROOT/apt/distributions"); do
    echo "== $dist"
    "${REPREPRO[@]}" list "$dist" || true
  done
} > "$SITE/paquets.txt"
cat "$SITE/paquets.txt"
