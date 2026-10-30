#!/bin/bash
# Veille des versions de Samba (lancée chaque jour par .github/workflows/veille.yml).
#
# - Branches suivies (celles de targets.conf, ex. 4.22 à 4.25) : si une version plus récente que la
#   dernière Release publiée existe, lance la compilation avec publication.
# - Nouvelle branche (plus récente que toutes celles de targets.conf, ex. 4.26) : compilation d'essai
#   SANS publication avec la configuration de la branche précédente, puis ticket d'information.
# - Échec d'une compilation automatique : ticket d'information (un seul par version).
#
# Les compilations sont lancées une par une : la publication dans le dépôt APT n'en supporte qu'une à la fois.
# Variables : GH_TOKEN, GITHUB_REPOSITORY, VEILLE_MENTION (ex. « @utilisateur », notifié par e-mail),
#             DRY_RUN=true pour seulement afficher ce qui serait fait.
set -euo pipefail

REPO=${GITHUB_REPOSITORY:?}
MENTION=${VEILLE_MENTION:-}
DRY_RUN=${DRY_RUN:-false}
TARGETS=bookworm,trixie
SAMBA_MIRRORS="https://download.samba.org/pub/samba/stable https://ftp.funet.fi/pub/mirrors/samba.org/pub/samba/stable"

# --- versions publiées par Samba
LIST=""
for base in $SAMBA_MIRRORS; do
  if page=$(curl -fsSL --retry 3 --retry-all-errors --retry-delay 15 "$base/"); then
    LIST=$(echo "$page" | grep -o 'samba-4\.[0-9]*\.[0-9]*\.tar\.gz' | sed -e 's/^samba-//' -e 's/\.tar\.gz$//' | sort -uV)
    [ -n "$LIST" ] && { echo "Versions lues sur $base"; break; }
  fi
done
[ -n "$LIST" ] || { echo "::error::liste des versions de Samba illisible"; exit 1; }

latest_of() { echo "$LIST" | grep -E "^${1//./\\.}\.[0-9]+$" | tail -1 || true; }
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }   # $1 > $2 ?

FOLLOWED=$(awk '!/^#/ && NF {print $1}' targets.conf | sort -uV)
MAX_FOLLOWED=$(echo "$FOLLOWED" | tail -1)
PUBLISHED=$(gh release list -R "$REPO" -L 300 --json tagName --jq '.[].tagName')
RUNS=$(gh run list -R "$REPO" --workflow build.yml -L 300 --json databaseId,displayTitle,status,conclusion,url)

# état de la dernière compilation d'une version : aucune | en_cours | success | failure | cancelled…
run_state() {
  echo "$RUNS" | jq -r --arg p "Samba $1-roms-" '
    [.[] | select(.displayTitle | startswith($p))] | first
    | if . == null then "aucune" elif .status != "completed" then "en_cours" else .conclusion end'
}
run_url() {
  echo "$RUNS" | jq -r --arg p "Samba $1-roms-" '[.[] | select(.displayTitle | startswith($p))] | first | .url // ""'
}

# ticket d'information (créé une seule fois, tant qu'il est ouvert)
ensure_issue() {   # $1 titre, $2 corps
  if [ -n "$(gh issue list -R "$REPO" --state open --search "in:title \"$1\"" --json number --jq '.[].number')" ]; then
    echo "ticket déjà ouvert : $1"
  elif [ "$DRY_RUN" = true ]; then
    echo "[essai à blanc] ticket : $1"
  else
    gh issue create -R "$REPO" --title "$1" --body "$2" > /dev/null && echo "ticket créé : $1"
  fi
}

# --- ce qu'il faut compiler
declare -a TODO=()        # éléments « version publier(true|false) »
for b in $FOLLOWED; do
  v=$(latest_of "$b")
  if [ -z "$v" ]; then echo "$b : aucune version upstream"; continue; fi
  if echo "$PUBLISHED" | grep -q "^v${v//./\\.}-roms-"; then echo "$b : $v déjà publiée"; continue; fi
  st=$(run_state "$v")
  case $st in
    en_cours) echo "$b : $v en cours de compilation" ;;
    failure)
      echo "$b : $v en échec"
      ensure_issue "Échec de compilation de Samba $v" \
"${MENTION:+$MENTION }La compilation automatique de Samba **$v** (branche $b) a échoué : $(run_url "$v")

Corriger (patch roms, targets.conf, patches/debian-retires.conf…) puis relancer l'action **Compilation Samba roms** à la main. Fermer ce ticket une fois la version publiée." ;;
    *) echo "$b : nouvelle version $v (dernière compilation : $st)"; TODO+=("$v true") ;;
  esac
done

for b in $(echo "$LIST" | sed -E 's/\.[0-9]+$//' | sort -uV); do
  newer "$b" "$MAX_FOLLOWED" || continue
  v=$(latest_of "$b")
  [ -n "$v" ] || continue          # pas de version stable x.y.z dans cette branche
  st=$(run_state "$v")
  if [ "$st" = aucune ]; then
    echo "nouvelle branche $b ($v) : compilation d'essai"
    TODO+=("$v false")
  else
    echo "nouvelle branche $b ($v) : essai déjà fait ($st)"
  fi
done

# --- compilations, une par une
for item in "${TODO[@]}"; do
  read -r v publish <<< "$item"
  b=${v%.*}
  title="Samba $v-roms-1 ($TARGETS)$([ "$publish" = true ] || echo ' sans publication')"
  if [ "$DRY_RUN" = true ]; then echo "[essai à blanc] lancerait : $title"; continue; fi

  echo "::group::$title"
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gh workflow run build.yml -R "$REPO" -f samba_version="$v" -f roms_rev=1 -f targets="$TARGETS" -f publish="$publish"
  id=""
  for _ in $(seq 1 30); do
    sleep 10
    id=$(gh run list -R "$REPO" --workflow build.yml -L 10 --json databaseId,displayTitle,createdAt 2>/dev/null \
         | jq -r --arg t "$title" --arg s "$since" '[.[] | select(.displayTitle == $t and .createdAt >= $s)] | first | .databaseId // empty' || true)
    [ -n "$id" ] && break
  done
  [ -n "$id" ] || { echo "::error::exécution introuvable pour « $title »"; echo "::endgroup::"; continue; }
  url="https://github.com/$REPO/actions/runs/$id"
  echo "exécution : $url"
  gh run watch "$id" -R "$REPO" --interval 60 > /dev/null 2>&1 || true
  concl=$(gh run view "$id" -R "$REPO" --json conclusion --jq .conclusion)
  echo "résultat : $concl"
  echo "::endgroup::"

  if [ "$publish" = true ]; then
    [ "$concl" = success ] || ensure_issue "Échec de compilation de Samba $v" \
"${MENTION:+$MENTION }La compilation automatique de Samba **$v** (branche $b) a échoué : $url

Corriger (patch roms, targets.conf, patches/debian-retires.conf…) puis relancer l'action **Compilation Samba roms** à la main. Fermer ce ticket une fois la version publiée."
  else
    if [ "$concl" = success ]; then
      result="✅ La compilation d'essai et les tests **ont réussi** pour Debian 12 et 13 avec la configuration de la branche $MAX_FOLLOWED : $url"
    else
      result="❌ La compilation d'essai avec la configuration de la branche $MAX_FOLLOWED **a échoué** : $url"
    fi
    ensure_issue "Nouvelle branche Samba $b ($v)" \
"${MENTION:+$MENTION }Samba **$b** est sortie (version $v). Elle n'est pas encore suivie par samba-roms.

$result

Rien n'a été publié. Pour suivre cette branche :
1. ajouter les lignes \`$b bookworm …\` et \`$b trixie …\` dans \`targets.conf\` (packaging Debian $b s'il existe : https://snapshot.debian.org/package/samba/) ;
2. ajouter le composant \`samba-$b\` dans \`apt/distributions\` ;
3. lancer **Compilation Samba roms** avec \`samba_version=$v\` et publication.

La veille compilera ensuite automatiquement les versions suivantes de cette branche."
  fi
done
echo "Veille terminée."
