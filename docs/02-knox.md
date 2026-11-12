# 02 — Knox : sauvegardes et surveillance de l'intégrité

> Produit avec l'aide d'une intelligence artificielle générative.

| Élément | Valeur |
|---|---|
| VM | `edanf-knox` (Proxmox, pve1), Ubuntu 24.04 LTS |
| Accès | **Console Proxmox seulement**, aucun SSHD installé |
| Rôle | Va chercher (*pull*) les sauvegardes du VPS et surveille l'intégrité de fichiers de configuration |
| Scripts | `/opt/knox/sauvegarde.sh`, `/opt/knox/surveillance.sh` |
| Sauvegardes | `/srv/sauvegardes/AAAA-MM-JJ_HHMM/` + lien `dernier` |
| Journaux | `/opt/knox/sauvegarde.log`, `/opt/knox/monitor.log` |

## Principe

```
   Knox (cégep, 205.237.231.60)                 VPS (172.105.11.146:870)
   ┌──────────────────────────┐   SSH, clé      ┌─────────────────────────────┐
   │ root : sauvegarde.sh     │ ──────────────▶ │ knoxbackup (sans mot de     │
   │        surveillance.sh   │   Knox initie   │ passe, sudo limité à        │
   │ /srv/sauvegardes         │ ◀────────────── │ rsync --sender + mysqldump) │
   └──────────────────────────┘   données       └─────────────────────────────┘
```

- C'est **toujours Knox qui initie la connexion**. Knox n'a aucun serveur SSH : le VPS, même compromis, ne peut pas l'atteindre ni effacer ses sauvegardes.
- Le compte `knoxbackup` du VPS est en **lecture seule** : il peut seulement envoyer des fichiers (`rsync --server --sender`) et faire un dump de la base `candyshop_secu`.

---

## 1. Préparation de Knox

- Installation : voir `00-preparation-environnement.md` (sans OpenSSH server).
- Console série xterm.js pour le copier-coller (section 4.3.1 du document 00).
- Vérifier que le réseau laisse sortir le port 870 et noter l'IP publique de sortie :

```bash
nc -vz -w 5 172.105.11.146 870      # succeeded
curl -s https://ifconfig.me         # 205.237.231.60
```

## 2. Sur le VPS : compte `knoxbackup`

```bash
sudo adduser --disabled-password --gecos "Sauvegardes Knox" knoxbackup

sudo tee /etc/sudoers.d/knoxbackup > /dev/null <<'EOF'
# Knox : sauvegardes en lecture seule (rsync en mode envoi + dump de la base)
knoxbackup ALL=(root) NOPASSWD: /usr/bin/rsync --server --sender *
knoxbackup ALL=(root) NOPASSWD: /usr/bin/mysqldump --single-transaction --routines --databases candyshop_secu
EOF
sudo chmod 440 /etc/sudoers.d/knoxbackup
sudo visudo -cf /etc/sudoers.d/knoxbackup        # parsed OK
```

| Mesure | Raison |
|---|---|
| `--disabled-password` | Aucun mot de passe : rien à deviner ni à voler |
| `sudo` limité à 2 commandes | Les droits root sont nécessaires pour lire tout `/home` et conserver les propriétaires, mais seulement pour ces deux opérations |
| `rsync --server --sender` | Le VPS peut seulement **envoyer** des fichiers. Knox ne peut rien écrire sur le VPS |
| `mysqldump` avec arguments fixes | Dump de `candyshop_secu` seulement |

## 3. Sur Knox : clé du script (sans passphrase)

Le script tourne par cron, sans humain : sa clé ne peut pas avoir de passphrase. Elle est protégée par ces mesures :
- elle est stockée dans `/root/.ssh`, en mode 600 ;
- Knox n'a pas de SSHD, donc personne ne peut s'y connecter à distance pour la voler ;
- côté VPS, elle est restreinte (section 4).

```bash
sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh
sudo ssh-keygen -t rsa -b 4096 -N "" -C "knox-backup" -f /root/.ssh/id_rsa_knox

sudo tee /root/.ssh/config > /dev/null <<'EOF'
Host vps
    HostName 172.105.11.146
    Port 870
    User knoxbackup
    IdentityFile /root/.ssh/id_rsa_knox
    IdentitiesOnly yes
EOF
sudo chmod 600 /root/.ssh/config
```

## 4. Installer la clé sur le VPS, avec restrictions

Transfert de la clé publique sans recopie manuelle. Le compte `edan` accepte encore les mots de passe à ce moment-là :

```bash
# Sur Knox
sudo cat /root/.ssh/id_rsa_knox.pub | ssh -p 870 edan@172.105.11.146 'cat > ~/knox.pub'

# Sur le VPS
sudo mkdir -p /home/knoxbackup/.ssh
echo "from=\"205.237.231.60\",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding $(cat ~/knox.pub)" \
  | sudo tee /home/knoxbackup/.ssh/authorized_keys > /dev/null
rm ~/knox.pub
sudo chown -R knoxbackup:knoxbackup /home/knoxbackup/.ssh
sudo chmod 700 /home/knoxbackup/.ssh
sudo chmod 600 /home/knoxbackup/.ssh/authorized_keys
sudo ssh-keygen -lf /home/knoxbackup/.ssh/authorized_keys   # même empreinte que sur Knox
```

| Option | Effet |
|---|---|
| `from="205.237.231.60"` | Clé utilisable seulement depuis l'IP du cégep. Volée, elle ne sert à rien ailleurs |
| `no-pty` | Pas de terminal interactif |
| `no-port-forwarding`, `no-agent-forwarding`, `no-X11-forwarding` | Impossible d'utiliser le VPS comme relais |

Test sur Knox :

```bash
sudo ssh vps "sudo mysqldump --single-transaction --routines --databases candyshop_secu" | head -5
```

---

## 5. Script de sauvegarde — `/opt/knox/sauvegarde.sh`

Voir `scripts/knox/sauvegarde.sh`.

| Étape | Détail |
|---|---|
| Fichiers | `rsync -aHAX --numeric-ids --delete --rsync-path="sudo rsync"` pour `/var/www` et `/home` |
| Versions | Un instantané daté par exécution. `--link-dest` crée des liens physiques vers l'instantané précédent pour les fichiers inchangés |
| Base | `mysqldump` à distance, compressé dans `db/candyshop_secu.sql.gz` |
| Rotation | Les 7 instantanés les plus récents sont conservés |
| Journal | `/opt/knox/sauvegarde.log` ; une erreur est inscrite grâce à `trap ... ERR` |

```bash
sudo mkdir -p /opt/knox /srv/sauvegardes
sudo chmod 700 /opt/knox /srv/sauvegardes
# copier le script dans /opt/knox/sauvegarde.sh
sudo chmod 700 /opt/knox/sauvegarde.sh
sudo /opt/knox/sauvegarde.sh
```

### Point boni : propriétaires et permissions conservés

`--numeric-ids` garde les UID/GID du VPS tels quels, même si ces comptes n'existent pas sur Knox. Comme le script tourne en root sur Knox, il peut attribuer ces propriétaires.

```bash
# Knox
sudo stat -c '%u:%g %a %n' /srv/sauvegardes/dernier/home/edan/.ssh/authorized_keys \
                           /srv/sauvegardes/dernier/var/www/secu.candyshop.click/accesseur/Accesseur.php
# VPS
sudo stat -c '%u:%g %a %n' /home/edan/.ssh/authorized_keys \
                           /var/www/secu.candyshop.click/accesseur/Accesseur.php
```

| Fichier | VPS | Knox |
|---|---|---|
| `/home/edan/.ssh/authorized_keys` | `1001:1001 600` | `1001:1001 600` ✅ |
| `.../accesseur/Accesseur.php` | `33:33 644` | `33:33 644` ✅ |

> Ce test a aussi révélé que `Accesseur.php` (identifiants de la base) était lisible par tous les comptes du VPS. Correction : `sudo chmod 640 /var/www/secu.candyshop.click/accesseur/Accesseur.php`.

---

## 6. Script de surveillance — `/opt/knox/surveillance.sh`

Voir `scripts/knox/surveillance.sh`.

Fichiers surveillés :

| Fichier | Pourquoi |
|---|---|
| `/etc/apache2/sites-available/secu.candyshop.click.conf` | VHOST du site (HTTP) |
| `/etc/apache2/sites-available/secu.candyshop.click-le-ssl.conf` | VHOST du site (HTTPS, généré par certbot) |
| `/etc/ssh/sshd_config` | Configuration principale du service SSH |
| `/etc/ssh/sshd_config.d/10-projet-securite.conf` | Les réglages SSH du projet (port, root, robert) |

Fonctionnement :
1. Chaque fichier est **copié du VPS vers Knox**, et son SHA-256 est calculé **sur Knox**. On ne fait pas confiance au VPS pour calculer l'empreinte : s'il était compromis, sa commande `sha256sum` pourrait mentir.
2. L'empreinte est comparée à la référence (`/opt/knox/empreintes.ref`).
3. Toute différence entraîne une ligne `ALERTE` dans `/opt/knox/monitor.log`. Sinon, une ligne `OK`.
4. L'alerte se répète à chaque vérification tant que la référence n'est pas mise à jour avec `--init`, après une modification légitime.

```bash
sudo chmod 700 /opt/knox/surveillance.sh
sudo /opt/knox/surveillance.sh --init     # crée la référence
sudo /opt/knox/surveillance.sh            # vérifie
sudo tail /opt/knox/monitor.log
```

Test de détection :

```bash
# VPS : modification
echo "# test intégrité" | sudo tee -a /etc/apache2/sites-available/secu.candyshop.click.conf
# Knox
sudo /opt/knox/surveillance.sh && sudo tail -3 /opt/knox/monitor.log
# → ALERTE : /etc/apache2/sites-available/secu.candyshop.click.conf a été modifié !
# VPS : retour à l'original
sudo sed -i '$d' /etc/apache2/sites-available/secu.candyshop.click.conf
# Knox → OK : 4 fichiers intacts
```

---

## 7. Automatisation (crontab de root sur Knox)

```bash
sudo crontab -l
```

```
# Knox — projet de sécurité A2026
# Sauvegarde complète du VPS tous les jours à 2 h
0 2 * * * /opt/knox/sauvegarde.sh > /dev/null 2>&1
# Vérification de l'intégrité toutes les 5 minutes
*/5 * * * * /opt/knox/surveillance.sh
```

> Les tâches sont dans la crontab de **root**, parce que la clé et `/root/.ssh/config` appartiennent à root.

---

## 8. Restauration d'un fichier

Le compte `knoxbackup` est en **lecture seule**. C'est voulu : le script automatique ne peut jamais écrire sur le VPS. La restauration utilise donc une **deuxième clé**, réservée à cet usage :

| | Clé de sauvegarde | Clé de restauration |
|---|---|---|
| Fichier sur Knox | `/root/.ssh/id_rsa_knox` | `/root/.ssh/id_rsa_restore` |
| Passphrase | Non (utilisée par cron) | **Oui** (utilisée par une personne) |
| Compte sur le VPS | `knoxbackup` (sudo limité à la lecture) | `edan` (sudo complet, avec mot de passe) |
| Alias SSH | `vps` | `vps-restore` |
| Restrictions | `from="205.237.231.60"`, `no-pty`, `no-*-forwarding` | idem |

### 8.1 Mise en place (une seule fois)

Sur Knox. Taper **une commande à la fois** : `ssh-keygen` lit la passphrase au clavier.

```bash
sudo ssh-keygen -t rsa -b 4096 -C "knox-restauration" -f /root/.ssh/id_rsa_restore   # avec passphrase

sudo tee -a /root/.ssh/config > /dev/null <<'EOF'

Host vps-restore
    HostName 172.105.11.146
    Port 870
    User edan
    IdentityFile /root/.ssh/id_rsa_restore
    IdentitiesOnly yes
EOF

# Envoi de la clé publique, avec restrictions (avant de désactiver les mots de passe sur le VPS)
sudo cat /root/.ssh/id_rsa_restore.pub | ssh -p 870 edan@172.105.11.146 \
  'echo "from=\"205.237.231.60\",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding $(cat)" >> ~/.ssh/authorized_keys'
```

### 8.2 Procédure de restauration

**1. Knox : choisir l'instantané et le fichier**

```bash
sudo ls -l /srv/sauvegardes/                     # instantanés datés + lien « dernier »
F=var/www/secu.candyshop.click/partage/lisezmoi.txt
sudo stat -c '%u:%g %a %n' "/srv/sauvegardes/dernier/$F"
```

Pour une version plus ancienne, remplacer `dernier` par le nom de l'instantané, par exemple `2026-11-10_0200`.

**2. Knox : emballer et envoyer le fichier**

```bash
sudo tar -C /srv/sauvegardes/dernier --numeric-owner -cpf - "$F" \
  | sudo ssh vps-restore 'cat > /tmp/restauration.tar'
```

**3. VPS : remettre le fichier en place**

```bash
sudo tar -C / --numeric-owner -xpvf /tmp/restauration.tar
rm /tmp/restauration.tar
sudo stat -c '%U:%G %a %n' /var/www/secu.candyshop.click/partage/lisezmoi.txt
```

> **Pourquoi `tar` ?** Il sert d'emballage pour le transfert : `-p` conserve les permissions et `--numeric-owner` conserve les propriétaires. Une simple copie avec `scp` donnerait le fichier à `edan`, avec les permissions par défaut.

### 8.3 Résultat du test

| Étape | Résultat |
|---|---|
| Avant la suppression (VPS) | `www-data:www-data 644 .../partage/lisezmoi.txt` |
| `sudo rm` sur le VPS | fichier absent de `/partage/` |
| Dans la sauvegarde (Knox) | `33:33 644` (33 = `www-data`) |
| Après la restauration (VPS) | `www-data:www-data 644 .../partage/lisezmoi.txt` ✅ |

Les instantanés `2026-11-10_0200`, `2026-11-11_0200` et `2026-11-12_0200` ont été créés automatiquement par cron, ce qui confirme que la sauvegarde planifiée fonctionne.
