#!/bin/bash
# =============================================================================
# surveillance.sh — Knox
# Surveille l'intégrité de fichiers de configuration du VPS.
# Chaque fichier est copié du VPS vers Knox, puis son empreinte SHA-256 est
# calculée SUR KNOX (on ne fait pas confiance au VPS pour calculer lui-même
# l'empreinte : s'il était compromis, sa commande sha256sum pourrait mentir).
# Toute différence avec l'empreinte de référence est écrite dans monitor.log.
#
# Usage : surveillance.sh          → compare aux empreintes de référence
#         surveillance.sh --init   → (re)crée les empreintes de référence
#
# Produit avec l'aide d'une intelligence artificielle générative.
# =============================================================================
set -uo pipefail

VPS="vps"                               # alias de /root/.ssh/config
DIR="/opt/knox"
REF="$DIR/empreintes.ref"               # empreintes de référence (hash + chemin)
LOG="$DIR/monitor.log"                  # journal des vérifications et alertes

FICHIERS=(
    "/etc/apache2/sites-available/secu.candyshop.click.conf"         # VHOST HTTP
    "/etc/apache2/sites-available/secu.candyshop.click-le-ssl.conf"  # VHOST HTTPS (certbot)
    "/etc/ssh/sshd_config"                                           # config principale SSH
    "/etc/ssh/sshd_config.d/10-projet-securite.conf"                 # config SSH du projet
)

# Écrit une ligne horodatée dans monitor.log
journal() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# Copie un fichier du VPS dans un fichier temporaire et affiche son SHA-256
empreinte() {
    local tmp h
    tmp=$(mktemp)
    if ssh "$VPS" "cat '$1'" > "$tmp" 2>/dev/null; then
        h=$(sha256sum "$tmp" | cut -d' ' -f1)
        rm -f "$tmp"
        echo "$h"
    else
        rm -f "$tmp"
        return 1
    fi
}

# --- Mode initialisation : enregistre les empreintes de référence -----------
if [ "${1:-}" = "--init" ]; then
    : > "$REF.tmp"
    for f in "${FICHIERS[@]}"; do
        if ! h=$(empreinte "$f"); then
            echo "Impossible de lire $f sur le VPS" >&2
            rm -f "$REF.tmp"
            exit 1
        fi
        echo "$h  $f" >> "$REF.tmp"
    done
    mv "$REF.tmp" "$REF"
    chmod 600 "$REF"
    journal "INIT : empreintes de référence enregistrées (${#FICHIERS[@]} fichiers)"
    cat "$REF"
    exit 0
fi

# --- Mode vérification ------------------------------------------------------
if [ ! -f "$REF" ]; then
    journal "ERREUR : aucune référence, lancer $0 --init"
    exit 1
fi

alertes=0
for f in "${FICHIERS[@]}"; do
    attendu=$(awk -v f="$f" '$2 == f {print $1}' "$REF")
    if ! actuel=$(empreinte "$f"); then
        journal "ERREUR : impossible de lire $f sur le VPS"
        alertes=$((alertes + 1))
        continue
    fi
    if [ -z "$attendu" ]; then
        journal "AVERTISSEMENT : $f absent de la référence (lancer --init)"
        alertes=$((alertes + 1))
    elif [ "$actuel" != "$attendu" ]; then
        journal "ALERTE : $f a été modifié ! référence=${attendu:0:16}… actuel=${actuel:0:16}…"
        alertes=$((alertes + 1))
    fi
done

if [ "$alertes" -eq 0 ]; then
    journal "OK : ${#FICHIERS[@]} fichiers intacts"
fi
exit 0
