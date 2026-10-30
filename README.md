# samba-roms

Compilation automatique de Samba « roms » pour **Debian 12 (bookworm)** et **Debian 13 (trixie)** : le packaging Debian appliqué au tarball officiel de Samba, avec les patches roms. Les paquets sont testés, puis publiés dans un dépôt APT signé :

**https://groupe-gefor.github.io/samba-roms**

## Compiler une version

Onglet **Actions** → **Compilation Samba roms** → **Run workflow** :

| Paramètre | Exemple | Rôle |
|---|---|---|
| `samba_version` | `4.24.8` | version upstream ([download.samba.org](https://download.samba.org/pub/samba/stable/)) |
| `roms_rev` | `1` | révision roms ; à augmenter pour recompiler une version déjà publiée |
| `targets` | `bookworm,trixie` | distributions |
| `donor` | *(vide)* | version Debian du packaging à utiliser à la place de [`targets.conf`](targets.conf) |
| `publish` | coché | crée la Release GitHub et met à jour le dépôt APT |

En ligne de commande :

```bash
gh workflow run build.yml -R GROUPE-GEFOR/samba-roms -f samba_version=4.24.8 -f roms_rev=1 -f targets=bookworm,trixie
```

Paquets produits : `2:<version>-roms-<révision>+deb12` (bookworm) et `+deb13` (trixie), par exemple `2:4.24.8-roms-1+deb12`.
- Ces versions sont supérieures aux versions roms précédentes, compilées à la main au format `2:<version>-roms-<n>`.
- `+deb13` est supérieur à `+deb12` : le passage d'un serveur en Debian 13 remplace le paquet bookworm par le paquet trixie.
- ldb, talloc, tdb et tevent sont compilés avec Samba (ex. `libldb2 2:2.11.0+samba4.22.4-roms-3+deb12`).

## Veille automatique des versions

L'action **Veille des versions de Samba** ([`veille.yml`](.github/workflows/veille.yml), script [`scripts/veille.sh`](scripts/veille.sh)) tourne chaque jour à 05h17 UTC :

- **Branches suivies**, c'est-à-dire celles de [`targets.conf`](targets.conf) (4.22 à 4.25) : si upstream publie une version plus récente que la dernière Release, la veille lance la compilation **avec publication**, pour Debian 12 et 13. Les compilations passent l'une après l'autre.
- **Nouvelle branche** (4.26 ou plus) :
  - compilation d'essai **sans publication**, avec la configuration (packaging Debian, profils) de la branche suivie la plus récente ;
  - puis un ticket « Nouvelle branche Samba 4.26 (4.26.x) » donne le résultat et les étapes pour suivre cette branche.
- **Échec d'une compilation automatique** : un ticket « Échec de compilation de Samba x.y.z » est créé, une seule fois tant qu'il reste ouvert. La veille ne relance pas une version en échec : il faut la corriger, puis relancer la compilation à la main.

Les tickets mentionnent le compte indiqué dans la variable de dépôt `VEILLE_MENTION` (Settings → Secrets and variables → Actions → Variables). GitHub envoie donc un **e-mail** à ce compte.

Pour un essai à blanc de la veille, qui affiche ce qui serait fait sans rien compiler ni publier :

```bash
gh workflow run veille.yml -R GROUPE-GEFOR/samba-roms -f dry_run=true
```

## Page du dépôt APT

La page [groupe-gefor.github.io/samba-roms](https://groupe-gefor.github.io/samba-roms) liste automatiquement les branches de Samba :
- **branches suivies** : statut Samba (actuelle, maintenance, sécurité seulement, fin de vie), dernière version upstream et sa date, et paquets roms publiés pour chaque distribution. Une version upstream pas encore publiée est signalée ;
- **nouvelle branche** (ex. 4.26) : elle apparaît dès sa sortie, marquée « pas encore suivie » ;
- **branche à venir** : la suivante, avec sa date de sortie probable (une branche tous les 6 mois environ).

Sa partie **Installation** propose un choix de branche (par défaut la plus récente publiée) qui met à jour les commandes, et un bouton **Copier les commandes** pour les coller dans le terminal du serveur. Les liens de la colonne « Composant APT » sélectionnent la branche ; un lien direct comme `https://groupe-gefor.github.io/samba-roms/#samba-4.22` ouvre la page avec la branche choisie.

Elle est générée par [`scripts/page.sh`](scripts/page.sh) à partir de [`apt/index.html`](apt/index.html), à chaque publication et chaque jour après la veille (tâche `page` de `veille.yml`). Les mêmes données sont dans [`versions.json`](https://groupe-gefor.github.io/samba-roms/versions.json). Les dates sont celles des tarballs sur download.samba.org.

## Ce que fait l'action

1. **Compilation** ([`scripts/build.sh`](scripts/build.sh)), dans un conteneur `debian:<distribution>` :
   - elle télécharge le paquet source Debian donneur indiqué dans [`targets.conf`](targets.conf), depuis deb.debian.org ou, s'il a quitté l'archive, depuis snapshot.debian.org ;
   - elle télécharge le tarball officiel de Samba et vérifie sa signature : clé « Samba Distribution Verification Key », empreinte `81F5E2832BD2545A1897B713AA99442FB680B620` ;
   - elle reprend le répertoire `debian/` du donneur et y ajoute les patches de [`patches/`](patches/) dans l'ordre de [`patches/series.roms`](patches/series.roms) ;
   - si un **patch Debian** est déjà intégré dans la version upstream, elle le retire et le signale. Quand la correction upstream a une autre forme, le patch ne s'applique plus : il faut alors le déclarer dans [`patches/debian-retires.conf`](patches/debian-retires.conf), comme `libads-fix-get_kdc_ip_string.patch` pour la 4.22.4 ;
   - si un **patch roms** ne s'applique plus, la compilation s'arrête : il faut mettre ce patch à jour dans `patches/` ;
   - elle met le suffixe `roms` dans `VERSION`, puis lance `dpkg-buildpackage -b` avec les profils de `targets.conf` (tests Samba désactivés : `nocheck`).
2. **Test** ([`scripts/smoke-test.sh`](scripts/smoke-test.sh)), dans un conteneur neuf de la même distribution :
   - installation depuis un dépôt local épinglé ;
   - vérification des versions et du suffixe `roms` ;
   - création d'un domaine AD de test ;
   - bind LDAP simple **sans royaume**, qui vérifie le patch `ldap_bind` ;
   - `smbclient -L`, `wbinfo -u` et `samba-tool dbcheck`.
3. **Publication** ([`scripts/publish-apt.sh`](scripts/publish-apt.sh)) :
   - Release GitHub `v<version>-roms-<révision>` avec tous les paquets, y compris les `-dbgsym`, ainsi que les `.changes` et `.buildinfo` ;
   - dépôt APT signé (reprepro) sur la branche `gh-pages`, sans les `-dbgsym`, dans le composant de la branche (`samba-4.22`…). Le dépôt APT ne garde que la dernière version de chaque branche ; les versions précédentes restent téléchargeables dans les Releases (retour arrière : `apt install ./paquet.deb …`).

Les patches tels qu'ils ont été appliqués (rafraîchis par quilt) se trouvent dans l'artefact `debs-<distribution>`, dossier `patches/`.

## Installer sur un serveur

Chaque branche de Samba a son propre composant : `samba-4.22`, `samba-4.23`, `samba-4.24`, `samba-4.25` (liste à jour sur la page du dépôt). Un serveur ne suit que la branche choisie, et `apt upgrade` ne le fait jamais passer à une autre. Pour changer de branche, il faut modifier `Components:` volontairement.

```bash
BRANCHE=samba-4.22     # branche à suivre
install -d /etc/apt/keyrings
curl -fsSL https://groupe-gefor.github.io/samba-roms/samba-roms.gpg -o /etc/apt/keyrings/samba-roms.gpg

cat > /etc/apt/sources.list.d/samba-roms.sources <<EOF
Types: deb
URIs: https://groupe-gefor.github.io/samba-roms
Suites: $(. /etc/os-release; echo $VERSION_CODENAME)
Components: $BRANCHE
Signed-By: /etc/apt/keyrings/samba-roms.gpg
EOF

# Priorité au dépôt roms : sinon, un Samba Debian plus récent remplacerait la version roms
cat > /etc/apt/preferences.d/samba-roms <<EOF
Package: *
Pin: release o=samba-roms
Pin-Priority: 1001
EOF

apt update && apt list --upgradable
```

## Les patches roms

| Patch | Effet | Statut |
|---|---|---|
| `roms-samba4-ldap_bind.patch` | Bind LDAP simple sans royaume (« user » devient « user@REALM »), comme sous Windows | appliqué |
| `roms-samba4-winbindd_util.patch` | winbind : ne force pas `can_assume = false` sur un contrôleur AD | appliqué |
| `roms-samba4-samba_upgradedns.patch` | `samba_upgradedns` : capture toutes les exceptions lors de la recherche des partitions DNS | appliqué |
| `roms-samba4-trim-ldb_dn-crlf-4.18.patch` | ldb : ignore les CR/LF autour des composants d'un DN | appliqué |
| `roms-samba4-Fix-Security-Tab-bugs-14213.patch` | Résolution des SID prédéfinis comme Windows (onglet Sécurité, [bug 14213](https://bugzilla.samba.org/show_bug.cgi?id=14213)) | désactivé : intégré dans Samba avant la 4.22 |
| `roms-samba4-cmd_user_modify.patch` | `samba-tool user modify` | désactivé depuis 4.22 (`samba-tool user edit`) |

## Dates d'origine des patches

Git ne conserve pas les dates de modification. Elles sont donc enregistrées dans [`patches/HORODATAGE.tsv`](patches/HORODATAGE.tsv), avec le md5 de chaque fichier. Pour les remettre après un `git clone` :

```bash
bash scripts/restaurer-dates.sh
```

Les patches ont aussi été importés par des commits datés de leur modification d'origine, ce qui permet de les retrouver avec `git log --format='%ad %s' -- patches/`.

## Clé de signature du dépôt APT

Empreinte : `52E0 E325 F141 722D 6B78  0E6B 582C F979 3575 9528` (RSA 4096, « samba-roms APT (GROUPE-GEFOR) »).

La clé privée se trouve uniquement dans le secret `APT_GPG_PRIVATE_KEY` du dépôt GitHub. La clé publique est publiée sur `https://groupe-gefor.github.io/samba-roms/samba-roms.gpg`. Pour changer de clé :
1. générer une nouvelle clé sans phrase de passe ;
2. remplacer le secret (`gh secret set APT_GPG_PRIVATE_KEY -R GROUPE-GEFOR/samba-roms < cle.asc`) ;
3. relancer une publication ;
4. redéployer `samba-roms.gpg` sur les serveurs.
