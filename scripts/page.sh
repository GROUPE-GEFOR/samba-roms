#!/bin/bash
# Génère la page d'accueil du dépôt APT (index.html, à partir de apt/index.html) et versions.json :
# branches de Samba suivies, nouvelles et à venir, avec la dernière version upstream, sa date et
# les paquets roms publiés.
#
#   scripts/page.sh <dossier gh-pages>
#
# Lancé à chaque publication (publish-apt.sh) et chaque jour par la veille (.github/workflows/veille.yml).
# Sources :
#   - versions et dates : liste des tarballs de download.samba.org (date du fichier = date de sortie) ;
#   - paquets publiés : dists/<distribution>/<composant>/binary-amd64/Packages du dépôt APT ;
#   - dates de publication roms : Releases GitHub (si gh est disponible).
set -euo pipefail

SITE=$(realpath "${1:?dossier gh-pages}")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${GITHUB_REPOSITORY:-GROUPE-GEFOR/samba-roms}
SAMBA_MIRRORS="https://download.samba.org/pub/samba/stable https://ftp.funet.fi/pub/mirrors/samba.org/pub/samba/stable"
MOIS=(janvier février mars avril mai juin juillet août septembre octobre novembre décembre)

date_fr() {   # 2026-07-22 -> 22 juillet 2026
  local j=$((10#${1:8:2}))
  [ "$j" = 1 ] && j=1er
  echo "$j ${MOIS[$((10#${1:5:2} - 1))]} ${1:0:4}"
}
mois_fr() { echo "${MOIS[$((10#${1:5:2} - 1))]} ${1:0:4}"; }   # 2027-03 -> mars 2027

# --- versions upstream : « version date »
UP=""
for base in $SAMBA_MIRRORS; do
  if page=$(curl -fsSL --retry 3 --retry-all-errors --retry-delay 15 "$base/"); then
    UP=$(echo "$page" | sed -nE 's/.*href="samba-(4\.[0-9]+\.[0-9]+)\.tar\.gz".*[^0-9]([0-9]{4}-[0-9]{2}-[0-9]{2})[^0-9].*/\1 \2/p' \
         | sort -u -k1,1V)
    [ -n "$UP" ] && break
  fi
done
[ -n "$UP" ] || { echo "::error::liste des versions de Samba illisible" >&2; exit 1; }

up_latest() { echo "$UP" | grep -E "^${1//./\\.}\.[0-9]+ " | tail -1 || true; }   # « version date »
up_date()   { echo "$UP" | awk -v v="$1" '$1 == v {print $2}'; }

DISTS=$(awk '/^Codename:/ {print $2}' "$ROOT/apt/distributions")
FOLLOWED=$(awk '!/^#/ && NF {print $1}' "$ROOT/targets.conf" | sort -uV)
MIN_FOLLOWED=$(echo "$FOLLOWED" | head -1)
UP_BRANCHES=$(echo "$UP" | awk '{print $1}' | sed -E 's/\.[0-9]+$//' | sort -uV)
NEWEST=$(echo "$UP_BRANCHES" | tail -1)
# branches affichées : celles suivies et toutes les branches upstream plus récentes que la plus ancienne suivie
BRANCHES=$( { echo "$FOLLOWED"; echo "$UP_BRANCHES" | while read -r b; do
              [ "$(printf '%s\n%s\n' "$b" "$MIN_FOLLOWED" | sort -V | head -1)" = "$MIN_FOLLOWED" ] && echo "$b"; done; } | sort -uV)

RELEASES=""
if command -v gh > /dev/null && [ -n "${GH_TOKEN:-}" ]; then
  RELEASES=$(gh release list -R "$REPO" -L 300 --json tagName,publishedAt --jq '.[] | "\(.tagName) \(.publishedAt[0:10])"' || true)
fi

# statut selon le cycle habituel de Samba : 3 branches maintenues (actuelle, maintenance, sécurité)
statut() {
  local rang
  rang=$(echo "$UP_BRANCHES" | sort -rV | grep -nxF "$1" | cut -d: -f1 || true)
  case $rang in
    1) echo "actuelle|actuelle" ;;
    2) echo "maintenance|maintenance" ;;
    3) echo "securite|sécurité seulement" ;;
    "") echo "inconnue|?" ;;
    *) echo "fin|fin de vie" ;;
  esac
}

# version du paquet samba publié dans le dépôt APT : 2:4.25.1-roms-1+deb12 -> 4.25.1-roms-1
roms_version() {   # $1 distribution, $2 composant
  local f="$SITE/dists/$1/$2/binary-amd64/Packages"
  [ -f "$f" ] || return 0
  awk '/^Package: / {p = ($2 == "samba")} p && /^Version: / {print $2; exit}' "$f" | sed -E 's/^[0-9]+://; s/\+deb[0-9]+$//'
}

debian() { case $1 in bookworm) echo "Debian 12" ;; trixie) echo "Debian 13" ;; *) echo "$1" ;; esac; }
date_court() { echo "${1:8:2}/${1:5:2}/${1:0:4}"; }   # 2026-10-30 -> 30/10/2026

ROWS=""
JSON=""
OPTIONS=""        # « composant|libellé » des branches publiées, pour le choix de la branche à installer
for b in $BRANCHES; do
  read -r v d <<< "$(up_latest "$b")"
  IFS='|' read -r st_code st_txt <<< "$(statut "$b")"
  suivie=false; echo "$FOLLOWED" | grep -qxF "$b" && suivie=true
  comp="samba-$b"; jcomp=""; [ "$suivie" = true ] && jcomp=$comp

  derniere="—"
  [ -n "$v" ] && derniere="<strong>$v</strong> du $(date_fr "$d")"

  roms=""; jroms=""; manque=false; publiee=""
  if [ "$suivie" = true ]; then
    # versions par distribution, regroupées quand elles sont identiques (cas habituel)
    declare -A par_version=()
    ordre=()
    for dist in $DISTS; do
      rv=$(roms_version "$dist" "$comp")
      jroms+="${jroms:+, }\"$dist\": \"$rv\""
      [ -n "$rv" ] || { manque=true; continue; }
      [ "${rv%-roms-*}" = "$v" ] || manque=true
      [ -n "${par_version[$rv]:-}" ] || ordre+=("$rv")
      nom=$(debian "$dist")
      case ${par_version[$rv]:-} in
        "") par_version[$rv]=$nom ;;
        Debian*) [ "${nom#Debian }" != "$nom" ] && par_version[$rv]+=" et ${nom#Debian }" || par_version[$rv]+=" et $nom" ;;   # Debian 12 et 13
        *) par_version[$rv]+=" et $nom" ;;
      esac
      publiee=$rv
    done
    for rv in "${ordre[@]}"; do
      rel=$(echo "$RELEASES" | awk -v t="v$rv" '$1 == t {print $2; exit}')
      roms+="<div><code>$rv</code> <span class=\"muted petit\">${par_version[$rv]}${rel:+ · publié le $(date_court "$rel")}</span></div>"
    done
    unset par_version
    [ -n "$roms" ] || roms="<span class=\"muted\">non publié</span>"
    [ "$manque" = true ] && [ -n "$v" ] && roms+="<div class=\"attente\">$v : compilation en attente ou en échec</div>"
    if [ -n "$publiee" ]; then
      composant="<a href=\"#$comp\" title=\"Commandes d'installation pour cette branche\"><code>$comp</code></a>"
      OPTIONS+="$comp|$b · $st_txt · $publiee
"
    else
      composant="<code>$comp</code>"
    fi
  else
    roms="<span class=\"muted\">nouvelle branche, pas encore suivie : compilation d'essai par la veille, sans publication</span>"
    composant="—"
  fi

  libelle=$b
  [ "$b" = "$NEWEST" ] && [ -n "$v" ] && libelle="$b <span class=\"muted\">(actuelle $v)</span>"
  ROWS+="<tr class=\"$st_code\"><td class=\"branche\">$libelle</td><td data-label=\"Statut\"><span class=\"statut $st_code\">$st_txt</span></td><td data-label=\"Samba\">$derniere</td><td data-label=\"Paquets roms\">$roms</td><td data-label=\"Composant\">$composant</td></tr>
"
  JSON+="${JSON:+,
}    {\"branche\": \"$b\", \"statut\": \"$st_txt\", \"suivie\": $suivie, \"derniere\": \"$v\", \"date\": \"$d\", \"composant\": \"$jcomp\", \"roms\": {${jroms}}}"
done

# prochaine branche : Samba sort une branche environ tous les 6 mois (mars et septembre)
read -r maj min <<< "$(echo "${NEWEST//./ }")"
next="$maj.$((min + 1))"
d0=$(up_date "$NEWEST.0")
attendue=""
[ -n "$d0" ] && attendue=$(date -u -d "$d0 +6 months" +%Y-%m)
ROWS+="<tr class=\"avenir\"><td class=\"branche\">$next</td><td data-label=\"Statut\"><span class=\"statut avenir\">à venir</span></td><td data-label=\"Samba\">${attendue:+attendue vers $(mois_fr "$attendue")}</td><td data-label=\"Paquets roms\">compilation d'essai automatique dès sa sortie, puis ticket d'information</td><td data-label=\"Composant\">—</td></tr>
"
JSON+=",
    {\"branche\": \"$next\", \"statut\": \"à venir\", \"suivie\": false, \"attendue\": \"$attendue\"}"

# choix de la branche à installer : par défaut la plus récente publiée (dernière stable)
[ -n "$OPTIONS" ] || { echo "::error::aucune branche publiée dans le dépôt APT" >&2; exit 1; }
DEFAUT=$(echo "$OPTIONS" | awk -F'|' 'NF {c = $1} END {print c}')
{
  echo '<select id="branche">'
  echo "$OPTIONS" | sort -t'|' -k1,1rV | while IFS='|' read -r c l; do
    [ -n "$c" ] || continue
    echo "    <option value=\"$c\"$([ "$c" = "$DEFAUT" ] && echo ' selected')>$l</option>"
  done
  echo '  </select>'
} > "$SITE/.CHOIX.html"

TABLE="$SITE/.VERSIONS.html"
cat > "$TABLE" <<EOF
<div class="tableau"><table>
<thead><tr><th>Branche</th><th>Statut Samba</th><th>Dernière version Samba</th><th>Paquets roms publiés</th><th>Composant APT</th></tr></thead>
<tbody>
$ROWS</tbody>
</table></div>
<p class="muted" id="maj">Page mise à jour le $(date_fr "$(date -u +%F)") à $(date -u +%H:%M) UTC. Statut selon le cycle de Samba (<a href="https://wiki.samba.org/index.php/Samba_Release_Planning">Samba Release Planning</a>) : trois branches maintenues, l'actuelle, la précédente en maintenance et l'avant-dernière pour la sécurité seulement.</p>
EOF
# @VERSIONS@ et @CHOIX@ (lignes entières) : remplacés par .VERSIONS.html et .CHOIX.html ; @DEFAUT@ : branche par défaut
awk -v dir="$SITE" -v defaut="$DEFAUT" '
  match($0, /@(VERSIONS|CHOIX)@/) { f = dir "/." substr($0, RSTART + 1, RLENGTH - 2) ".html"; while ((getline l < f) > 0) print l; close(f); next }
  { gsub(/@DEFAUT@/, defaut); print }' "$ROOT/apt/index.html" > "$SITE/index.html"
rm -f "$SITE/.VERSIONS.html" "$SITE/.CHOIX.html"

printf '{\n  "branches": [\n%s\n  ]\n}\n' "$JSON" > "$SITE/versions.json"
echo "Page générée : $(echo $BRANCHES) + $next à venir"
