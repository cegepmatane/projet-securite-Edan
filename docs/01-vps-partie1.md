# 01 — VPS : durcissement, Apache, HTTPS et Fail2ban

> Produit avec l'aide d'une intelligence artificielle générative.

| Élément | Valeur |
|---|---|
| Fournisseur | Linode (Akamai) |
| IP publique | `172.105.11.146` |
| Nom d'hôte | `candyshop-demo` |
| OS | Ubuntu 24.04.5 LTS |
| Pile | Apache 2.4.58, PHP 8.3, MariaDB 10.11 (écoute sur `127.0.0.1` seulement) |
| Site du projet | `https://secu.candyshop.click`, une copie de CandyShop (cours de Transaction Web) |
| Port SSH | **870** |

> Ce VPS sert aussi de staging pour le cours de Transaction Web (`demo.candyshop.click`). Le site du projet est **isolé** : il a son propre VirtualHost, son propre dossier, sa propre base de données et son propre utilisateur MariaDB.

---

## 1. Sauvegarde et inventaire avant les modifications

```bash
sudo tar czf ~/avant-projet-$(date +%F).tgz /etc/ssh /etc/apache2 /etc/ufw /etc/fail2ban
sudo mysqldump --all-databases > ~/avant-projet-$(date +%F).sql
```

| Élément | État initial |
|---|---|
| SSH | Port 22, connexion par mot de passe, `PermitRootLogin no` déjà présent |
| SSH (démarrage) | Activation par socket (`ssh.socket`), propre à Ubuntu 24.04 |
| UFW | Actif ; 22, 80 et 443 ouverts |
| Fail2ban | Actif, une prison `sshd` (port 22, 5 essais, 5 min, 8 h) |
| phpMyAdmin | Installé |
| Clés SSH | Aucune |

## 2. Mises à jour

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot     # si un nouveau noyau a été installé
```

À refaire régulièrement pendant tout le projet.

---

## 3. SSH

Toute la configuration propre au projet se trouve dans **un seul fichier** : `/etc/ssh/sshd_config.d/10-projet-securite.conf`. Le fichier `sshd_config` d'origine n'est pas modifié, et les changements du projet se repèrent facilement.

### 3.1 Clé RSA 4096 bits avec passphrase

⚠️ La clé se génère **sur le poste client** (le portable), jamais sur le serveur. Une clé privée ne doit pas se trouver sur la machine qu'elle protège.

Sur le portable :

```bash
ssh-keygen -t rsa -b 4096 -C "edan-secu-A2026" -f ~/.ssh/id_rsa_secu   # passphrase obligatoire
ssh-copy-id -p 870 -i ~/.ssh/id_rsa_secu.pub edan@172.105.11.146
```

Raccourci dans `~/.ssh/config` du portable :

```
Host vps-secu
    HostName 172.105.11.146
    User edan
    Port 870
    IdentityFile ~/.ssh/id_rsa_secu
    IdentitiesOnly yes
```

### 3.2 Configuration finale de sshd

**D'abord**, ouvrir le nouveau port dans le pare-feu. Sinon, on se bloque soi-même hors du serveur.

```bash
sudo ufw allow 870/tcp comment 'SSH projet secu'
```

`/etc/ssh/sshd_config.d/10-projet-securite.conf` :

```
# Projet de sécurité A2026 — durcissement SSH
# Port SSH non standard (projet)
Port 870
PermitRootLogin no
PermitEmptyPasswords no
PubkeyAuthentication yes
DenyUsers robert
```

```bash
sudo sshd -t && echo "Syntaxe OK"
sudo systemctl daemon-reload
sudo systemctl restart ssh.socket
sudo ss -tlnp | grep -E ':(22|870)\b'      # seulement 870
```

> **Particularité d'Ubuntu 24.04 :** c'est `ssh.socket` (systemd) qui écoute les ports. `daemon-reload` régénère la configuration du socket à partir de `sshd_config`, puis `restart ssh.socket` l'applique. Un simple `systemctl restart ssh` ne change pas le port.

**Transition sécuritaire utilisée :**
1. On écoute sur 22 **et** 870.
2. On teste le 870 dans un deuxième terminal, en gardant la session ouverte.
3. On retire `Port 22`, puis on supprime la règle UFW : `sudo ufw delete allow 22/tcp`.

### 3.3 Utilisateur `robert` sans accès SSH

Méthode retenue : la directive `DenyUsers robert`.

```bash
sudo adduser robert
```

Pourquoi cette méthode :
- `robert` reste un compte normal : il peut se connecter en local, par exemple à la console.
- Le refus est explicite et **écrit dans les journaux**, contrairement à un shell `nologin`, qui bloquerait aussi la console.

Vérification :

```bash
sudo sshd -T | grep -i denyusers                     # denyusers robert
ssh -p 870 robert@172.105.11.146                     # (portable, bon mot de passe) → Permission denied
sudo grep robert /var/log/auth.log | tail
# → User robert from <ip> not allowed because listed in DenyUsers
```

### 3.4 Compte de l'enseignant

```bash
sudo adduser david
sudo usermod -aG sudo david
```

### 3.5 Authentification par clé seulement *(quand l'enseignant aura déployé sa clé)*

```bash
sudo cat /home/david/.ssh/authorized_keys        # sa clé doit être présente
echo "PasswordAuthentication no" | sudo tee -a /etc/ssh/sshd_config.d/10-projet-securite.conf
echo "KbdInteractiveAuthentication no" | sudo tee -a /etc/ssh/sshd_config.d/10-projet-securite.conf
sudo sshd -t && sudo systemctl restart ssh
sudo sshd -T | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication)'   # no / no
```

---

## 4. Pare-feu (UFW)

```
[ 1] 80/tcp      ALLOW IN    Anywhere
[ 2] 443/tcp     ALLOW IN    Anywhere
[ 3] 870/tcp     ALLOW IN    Anywhere     # SSH projet secu
(+ équivalents v6)
```

Politique par défaut : `deny (incoming)`, `allow (outgoing)`.

```bash
sudo ufw status verbose          # Status: active
sudo systemctl is-enabled ufw    # enabled : démarre avec le système
```

---

## 5. Apache

### 5.1 Réglages globaux

`/etc/apache2/conf-available/security.conf` :

```
ServerTokens Prod       # en-tête « Server: Apache », sans version ni OS
ServerSignature Off     # pas de signature au bas des pages d'erreur
```

`/etc/apache2/apache2.conf`, bloc `<Directory /var/www/>` :

```
Options -Indexes +FollowSymLinks    # pas de liste du contenu des répertoires
```

```bash
sudo sed -i 's/^ServerTokens .*/ServerTokens Prod/; s/^ServerSignature .*/ServerSignature Off/' /etc/apache2/conf-available/security.conf
sudo sed -i '/<Directory \/var\/www\/>/,/<\/Directory>/ s/Options Indexes FollowSymLinks/Options -Indexes +FollowSymLinks/' /etc/apache2/apache2.conf
echo "ServerName candyshop-demo" | sudo tee /etc/apache2/conf-available/servername.conf
sudo a2enconf servername
sudo apache2ctl configtest && sudo systemctl reload apache2
```

### 5.2 Site du projet (copie de CandyShop)

```bash
sudo rsync -a /var/www/demo.candyshop.click/ /var/www/secu.candyshop.click/
```

**Base de données séparée, avec un utilisateur aux droits minimaux :**

```bash
sudo mysql -e "CREATE DATABASE candyshop_secu CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysqldump candyshop | sudo mysql candyshop_secu

SECU_PASS=$(openssl rand -hex 16)                 # jamais affiché à l'écran
sudo mysql -e "CREATE USER 'secu_user'@'localhost' IDENTIFIED BY '$SECU_PASS';
GRANT SELECT, INSERT, UPDATE, DELETE ON candyshop_secu.* TO 'secu_user'@'localhost';
FLUSH PRIVILEGES;"

F=/var/www/secu.candyshop.click/accesseur/Accesseur.php
sudo cp "$F" ~/Accesseur.php.orig                 # sauvegarde HORS du site Web
sudo sed -i -e "s/dbname=candyshop;/dbname=candyshop_secu;/" \
            -e "s/\(\$usager *= *'\)[^']*'/\1secu_user'/" \
            -e "s/\(\$motdepasse *= *'\)[^']*'/\1$SECU_PASS'/" "$F"
unset SECU_PASS
```

> **Principe du moindre privilège :** `secu_user` peut seulement lire et modifier les données de `candyshop_secu`. Il ne peut ni supprimer de tables, ni toucher à la base `candyshop` du staging, ni créer d'utilisateurs.

> La sauvegarde d'`Accesseur.php` est faite dans le dossier personnel, **pas dans `/var/www`**. Un fichier `.php.orig` placé dans le site serait servi tel quel, avec les identifiants de la base.

### 5.3 Répertoire `partage` : navigable, mais protégé par mot de passe

```bash
sudo mkdir -p /var/www/secu.candyshop.click/partage
sudo chown -R www-data:www-data /var/www/secu.candyshop.click/partage

sudo htpasswd -c /etc/apache2/.htpasswd-partage edan
sudo chown root:www-data /etc/apache2/.htpasswd-partage
sudo chmod 640 /etc/apache2/.htpasswd-partage
```

> Le fichier de mots de passe est placé **en dehors** de `/var/www`, pour qu'il ne soit jamais téléchargeable par le Web.

`/etc/apache2/sites-available/secu.candyshop.click.conf` :

```apache
<VirtualHost *:80>
    ServerName secu.candyshop.click
    DocumentRoot /var/www/secu.candyshop.click

    # Pas de liste du contenu des répertoires
    <Directory /var/www/secu.candyshop.click>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # Exception : « partage » est navigable, mais protégé par mot de passe
    <Directory /var/www/secu.candyshop.click/partage>
        Options +Indexes
        AuthType Basic
        AuthName "Partage - acces restreint"
        AuthUserFile /etc/apache2/.htpasswd-partage
        Require valid-user
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/secu.candyshop.click_error.log
    CustomLog ${APACHE_LOG_DIR}/secu.candyshop.click_access.log combined
</VirtualHost>
```

```bash
sudo a2ensite secu.candyshop.click
sudo apache2ctl configtest && sudo systemctl reload apache2
```

### 5.4 HTTPS (Let's Encrypt)

DNS (Namecheap) : enregistrement `A secu → 172.105.11.146`.

```bash
dig +short secu.candyshop.click                  # 172.105.11.146
sudo certbot --apache -d secu.candyshop.click    # Redirect HTTP → HTTPS
```

Certbot crée `secu.candyshop.click-le-ssl.conf`, qui reprend les blocs `<Directory>`. La protection de `partage` s'applique donc aussi en HTTPS. Le renouvellement est automatique (tâche planifiée de certbot).

### 5.5 Vérifications

```bash
curl -sI https://secu.candyshop.click/ | grep -i '^server'            # Server: Apache
curl -sI https://secu.candyshop.click/partage/ | head -1              # 401 Unauthorized
curl -s -u edan https://secu.candyshop.click/partage/ | grep lisezmoi # liste visible
curl -sL https://secu.candyshop.click/page-inexistante | tail -5      # 404 sans signature
```

---

## 6. Fail2ban (VPS partie 2)

Comportement exigé : **4 tentatives ratées en 15 minutes entraînent un bannissement de 6 heures**, pour SSH et pour phpMyAdmin.

### 6.1 phpMyAdmin : écrire les échecs dans syslog

Par défaut (`AuthLog = 'auto'`), aucun échec de connexion n'apparaissait dans `/var/log/auth.log`. On force l'écriture dans syslog :

```bash
echo "<?php \$cfg['AuthLog'] = 'syslog';" | sudo tee /etc/phpmyadmin/conf.d/90-fail2ban.php
```

Ligne obtenue dans `auth.log` après un essai raté :

```
phpMyAdmin[21316]: user denied: root (mysql-denied) from 205.237.231.60
```

### 6.2 `/etc/fail2ban/jail.local`

```ini
[DEFAULT]
ignoreip  = 127.0.0.1/8 ::1
allowipv6 = auto
maxretry  = 4
findtime  = 15m
bantime   = 6h

[sshd]
enabled  = true
backend  = auto
port     = 870
filter   = sshd
logpath  = /var/log/auth.log

[phpmyadmin-syslog]
enabled  = true
backend  = auto
port     = http,https
filter   = phpmyadmin-syslog
logpath  = /var/log/auth.log
```

```bash
sudo fail2ban-client -t && sudo systemctl restart fail2ban
sudo fail2ban-client status                        # Jail list: phpmyadmin-syslog, sshd
sudo fail2ban-client status sshd
sudo fail2ban-client status phpmyadmin-syslog
sudo fail2ban-client set <prison> unbanip <ip>     # débannir
```

> **`port = 870` :** la valeur par défaut `port = ssh` correspond au port 22. Une IP bannie pourrait donc continuer d'essayer sur le 870.

> **`backend = auto` dans chaque prison :** le fichier `jail.d/defaults-debian.conf` d'Ubuntu impose `backend = systemd` à sshd, avec le filtre `_SYSTEMD_UNIT=sshd.service`. Sur Ubuntu 24.04, le service s'appelle `ssh.service`, donc aucune tentative n'était détectée. Avec `backend = auto`, Fail2ban lit `/var/log/auth.log`. Le réglage est mis dans chaque prison, parce qu'une valeur placée dans `[DEFAULT]` serait écrasée par `defaults-debian.conf`.

> ⚠️ La prison phpMyAdmin bloque les ports **80 et 443**. Si l'IP du cégep est bannie, tout le cégep perd l'accès aux sites pendant 6 heures. Les tests de bannissement se font depuis une autre IP (partage de connexion du cellulaire).

---

## 7. Problèmes rencontrés

| Problème | Cause | Solution |
|---|---|---|
| Le portable demande encore le mot de passe malgré la clé | La clé avait été générée **sur le VPS** | Clé supprimée du VPS (privée et `authorized_keys`), puis régénérée sur le portable |
| Fail2ban : `Total failed: 0` malgré des échecs | Filtre du journal sur `sshd.service` au lieu de `ssh.service` (Ubuntu 24.04) | `backend = auto` + `logpath = /var/log/auth.log` |
| `Connection refused` sur le port 870 après des tests | **Notre propre IP bannie** par Fail2ban | Console **Lish** de Linode (hors SSH), puis `unbanip` |
| `ERROR 1396` à la création de `secu_user` | L'utilisateur existait déjà (essai précédent) | `DROP USER IF EXISTS` avant `CREATE USER` |
| Prison phpMyAdmin : 0 ligne détectée | phpMyAdmin n'écrivait pas ses échecs dans syslog | `$cfg['AuthLog'] = 'syslog'` dans `conf.d/90-fail2ban.php` |

> **Accès de secours :** la console **Lish** (Linode Cloud Manager → *Launch LISH Console*) ne passe pas par SSH. Ni Fail2ban ni UFW ne peuvent la bloquer.
