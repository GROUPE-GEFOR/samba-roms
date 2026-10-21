#!/bin/bash
# Git ne conserve pas les dates des fichiers : ce script remet aux fichiers importés leur date de
# modification d'origine, d'après HORODATAGE.tsv. À lancer depuis la racine du dépôt.
# Un fichier modifié depuis l'import (md5 différent) garde sa date actuelle.
set -euo pipefail

TSV=${1:-}
if [ -z "$TSV" ]; then
  for f in patches/HORODATAGE.tsv archive/HORODATAGE.tsv; do [ -f "$f" ] && { TSV=$f; break; }; done
fi
[ -n "$TSV" ] && [ -f "$TSV" ] || { echo "HORODATAGE.tsv introuvable" >&2; exit 1; }

ok=0; ignores=0
while IFS=$'\t' read -r date md5 chemin _; do
  case $date in '#'*|date|'') continue ;; esac
  if [ -f "$chemin" ] && [ "$(md5sum < "$chemin" | cut -c1-32)" = "$md5" ]; then
    touch -d "$date" "$chemin"
    ok=$((ok + 1))
  else
    echo "modifié ou absent, date non restaurée : $chemin"
    ignores=$((ignores + 1))
  fi
done < "$TSV"
echo "$ok dates restaurées, $ignores ignorées ($TSV)"
