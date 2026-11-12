#!/bin/bash
# =============================================================================
# sauvegarde.sh — Knox
# Va chercher (« pull ») les sauvegardes du VPS :
#   - /var/www et /home au complet (propriétaires et permissions conservés)
#   - un dump de la base candyshop_secu
#
# Chaque exécution crée un instantané daté dans /srv/sauvegardes.
# Les fichiers identiques à ceux de l'instantané précédent sont des liens
# physiques (« hard links ») : chaque instantané est complet, mais n'occupe
# que l'espace des fichiers modifiés depuis le précédent.
#
# Produit avec l'aide d'une intelligence artificielle générative.
# =============================================================================
set -euo pipefail                       # arrêt à la première erreur, y compris dans un pipe

VPS="vps"                               # alias défini dans /root/.ssh/config (port 870, clé, knoxbackup)
DEST="/srv/sauvegardes"                 # dossier des instantanés sur Knox
GARDER=7                                # nombre d'instantanés conservés
LOG="/opt/knox/sauvegarde.log"          # journal des exécutions
DATE=$(date +%Y-%m-%d_%H%M)             # nom de l'instantané, p. ex. 2026-11-09_1400
SNAP="$DEST/$DATE"                      # dossier de l'instantané en cours
DERNIER="$DEST/dernier"                 # lien symbolique vers l'instantané le plus récent

# Écrit un message horodaté à l'écran et dans le journal
journal() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

# En cas d'erreur, on l'inscrit au journal avant de quitter
trap 'journal "ERREUR : la sauvegarde a échoué (ligne $LINENO)"' ERR

journal "=== Début de la sauvegarde $DATE ==="
mkdir -p "$SNAP/db"

# --- 1. Fichiers : /var/www et /home -----------------------------------------
for SRC in /var/www /home; do
    LIEN=""
    if [ -d "$DERNIER$SRC" ]; then
        LIEN="--link-dest=$DERNIER$SRC"  # fichiers inchangés = liens vers l'instantané précédent
    fi
    mkdir -p "$SNAP$SRC"
    journal "rsync $SRC"
    # -a : récursif + permissions, dates, propriétaires, groupes, liens symboliques
    # -H : liens physiques   -A : ACL   -X : attributs étendus
    # --numeric-ids : garde les UID/GID du VPS tels quels (les comptes n'existent pas sur Knox)
    # --rsync-path : côté VPS, rsync est lancé avec sudo (autorisé en lecture seule par sudoers)
    rsync -aHAX --numeric-ids --delete $LIEN \
          --rsync-path="sudo rsync" \
          "$VPS:$SRC/" "$SNAP$SRC/"
done

# --- 2. Base de données ------------------------------------------------------
journal "dump de la base candyshop_secu"
ssh "$VPS" "sudo mysqldump --single-transaction --routines --databases candyshop_secu" \
    | gzip > "$SNAP/db/candyshop_secu.sql.gz"

# --- 3. Mise à jour du lien « dernier » et rotation --------------------------
ln -sfn "$SNAP" "$DERNIER"
ls -1d "$DEST"/20*/ | sort | head -n -"$GARDER" | xargs -r rm -rf

journal "Instantané : $SNAP ($(du -sh "$SNAP" | cut -f1)) — conservés : $(ls -1d "$DEST"/20*/ | wc -l)"
journal "=== Fin de la sauvegarde ==="
