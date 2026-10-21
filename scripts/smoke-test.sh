#!/bin/bash
# Teste les paquets compilés dans un conteneur debian:<distribution> neuf, lancé avec --privileged
# (attributs étendus nécessaires au provisioning AD) :
#
#   docker run --rm --privileged --hostname dc1 -v "$PWD:/src" -w /src debian:<distribution> \
#     bash scripts/smoke-test.sh <distribution>
#
# Installe les paquets depuis un dépôt local, crée un domaine AD de test et vérifie
# notamment le patch roms-samba4-ldap_bind (bind LDAP simple sans royaume).
set -euo pipefail

DIST=${1:?distribution}
OUT=/src/out/$DIST
REALM=CI.SAMBA-ROMS.TEST
DOMAIN=CIROMS
BASE="DC=ci,DC=samba-roms,DC=test"
ADMINPASS='Ci-samba-roms-2026!'   # domaine de test jetable, détruit avec le conteneur

ok()   { echo "OK   $*"; }
fail() { echo "::error::ÉCHEC $*" >&2; exit 1; }
. "$OUT/build-info.txt"

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends dpkg-dev ca-certificates

# Dépôt local prioritaire, comme le dépôt samba-roms sur les contrôleurs
(cd "$OUT" && dpkg-scanpackages --multiversion . > Packages)
echo "deb [trusted=yes] file:$OUT ./" > /etc/apt/sources.list.d/local.list
printf 'Package: *\nPin: origin ""\nPin-Priority: 1001\n' > /etc/apt/preferences.d/local
apt-get update -q
apt-get install -y -q samba samba-ad-dc samba-ad-provision winbind smbclient ldb-tools ldap-utils

echo "--- paquets installés"
dpkg-query -W -f '${Package} ${Version}\n' | grep -E 'samba|winbind|smbclient|ldb|talloc|tevent|tdb' | sort
# ldb, talloc, tdb et tevent ont leur propre version, suffixée par +samba<version roms>
bad=$(dpkg-query -W -f '${Package} ${Version} ${source:Package}\n' | awk -v v="$deb_version" '
  BEGIN { s = v; sub(/^[0-9]+:/, "", s); s = "+samba" s }
  $3 == "samba" && $2 != v && substr($2, length($2) - length(s) + 1) != s')
[ -z "$bad" ] || fail "paquets Samba qui ne viennent pas de cette compilation : $bad"
ok "tous les paquets du source samba sont en $deb_version"

samba -V | tee /dev/stderr | grep -q roms || fail "samba -V n'affiche pas « roms »"
ok "samba -V : $(samba -V)"

echo "--- provisioning du domaine de test $REALM"
rm -f /etc/samba/smb.conf
samba-tool domain provision --realm="$REALM" --domain="$DOMAIN" --server-role=dc \
  --dns-backend=SAMBA_INTERNAL --use-rfc2307 --adminpass="$ADMINPASS" > /tmp/provision.log 2>&1 \
  || { cat /tmp/provision.log; fail "samba-tool domain provision"; }
ok "domaine $REALM créé"

samba -D
export LDAPTLS_REQCERT=never
for i in $(seq 1 60); do
  ldapsearch -LLL -x -H ldaps://127.0.0.1 -b "" -s base namingContexts > /dev/null 2>&1 && break
  sleep 2
done
ok "samba démarré, LDAPS répond"

ldapsearch -LLL -x -H ldaps://127.0.0.1 -D "administrator@$REALM" -w "$ADMINPASS" -b "$BASE" -s base dn > /dev/null \
  || fail "bind LDAP simple avec administrator@$REALM"
ok "bind LDAP simple avec royaume (administrator@$REALM)"

ldapsearch -LLL -x -H ldaps://127.0.0.1 -D "administrator" -w "$ADMINPASS" -b "$BASE" -s base dn > /dev/null \
  || fail "bind LDAP simple SANS royaume (« administrator ») : patch roms-samba4-ldap_bind inactif"
ok "bind LDAP simple sans royaume (administrator) : patch ldap_bind actif"

samba-tool user list | grep -qix administrator || fail "samba-tool user list"
ok "samba-tool user list"

smbclient -L 127.0.0.1 -U "administrator%$ADMINPASS" 2>&1 | tee /tmp/smbclient.log | grep -q -i sysvol \
  || { cat /tmp/smbclient.log; fail "smbclient -L (partage sysvol absent)"; }
ok "smbclient -L : partages sysvol et netlogon"

for i in $(seq 1 30); do wbinfo -u 2>/dev/null | grep -qi administrator && break; sleep 2; done
wbinfo -u | grep -qi administrator || fail "wbinfo -u"
ok "winbind : wbinfo -u"

samba-tool dbcheck --cross-ncs > /tmp/dbcheck.log 2>&1 || { cat /tmp/dbcheck.log; fail "samba-tool dbcheck"; }
ok "samba-tool dbcheck : $(tail -1 /tmp/dbcheck.log)"

echo
echo "Tous les tests sont passés pour $deb_version ($DIST)."
