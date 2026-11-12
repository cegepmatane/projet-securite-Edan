# 00 — Préparation de l'environnement

> Produit avec l'aide d'une intelligence artificielle générative.

Cette procédure couvre :

1. La connexion au Proxmox
2. La création des deux VM (`<user>-knox` et `<user>-canary`)
3. L'installation d'Ubuntu Server 24.04 LTS
4. La préparation après l'installation (mises à jour, qemu-guest-agent, compte `david`)
5. L'état initial du VPS (serveur de staging de Transaction Web)

Dans tout le document, `<user>` est le nom d'utilisateur Proxmox (prénom + première lettre du nom de famille, p. ex. `davidt`).

---

## 1. Connexion au Proxmox

1. Se brancher au réseau **filaire** d'un des locaux O-106, O-155 ou O-157.
2. Ouvrir `https://10.1.106.200:8006` dans le navigateur.
   - Le certificat n'est pas reconnu par le navigateur : accepter l'avertissement et continuer.
3. Se connecter :
   - **User :** `<user>`
   - **Password :** `pm<No de DA>` (p. ex. `pm9999999`)
   - **Realm :** `Proxmox VE authentication server` ⚠️ obligatoire, sinon la connexion échoue.

> Le Proxmox garde la trace de toutes les opérations et de leur auteur. Ne touchez qu'à vos propres VM.

---

## 2. Création des machines virtuelles

Cliquer sur **Create VM** (en haut à droite) et remplir les onglets ci-dessous. Si un champ n'est pas mentionné, garder la valeur par défaut.

| Onglet | Champ | Knox | Canary |
|---|---|---|---|
| General | Node | `pve1` | `pve2` (on répartit la charge) |
| General | VM ID | Valeur proposée (en cas d'erreur, l'augmenter de 1) | idem |
| General | Name | `<user>-knox` | `<user>-canary` |
| OS | ISO image | Ubuntu **24.04.5 LTS** (storage `local`) | idem |
| System | Qemu Agent | ☑ coché | ☑ coché |
| Disks | Storage | `VMStorage1` (correspond à pve1) | `VMStorage2` (correspond à pve2) |
| Disks | Disk size | **25** Go | **25** Go |
| Disks | Discard | ☑ coché (support TRIM pour SSD) | ☑ coché |
| CPU | Cores | **1** | **1** |
| CPU | Type | **Nehalem** ⚠️ | **Nehalem** ⚠️ |
| Memory | Memory (MiB) | **2048** | **2048** |
| Network | — | Défaut | Défaut |

> **Pourquoi Nehalem ?** Les nœuds utilisent des Xeon série 5500, qui ne prennent pas en charge certains jeux d'instructions récents. Sans ce réglage, la VM ne démarre pas.

> **Règle Storage ↔ Node :** pve1 → VMStorage1, pve2 → VMStorage2.

Confirmer, puis démarrer la VM : clic droit sur la VM → **Start**, puis ouvrir l'onglet **Console**.

---

## 3. Installation d'Ubuntu Server 24.04 LTS

Faire l'installation depuis la **Console** Proxmox.

| Écran | Choix |
|---|---|
| Language | English (ou Français) |
| Keyboard | French (Canada) : vérifier en tapant `é`, `/`, `|` dans le champ de test |
| Type of install | Ubuntu Server (pas la version *minimized*) |
| Network | DHCP (par défaut). **Noter l'adresse IP** affichée. |
| Proxy / Mirror | Défaut |
| Storage | Use an entire disk + Set up this disk as an LVM group (défaut) |
| Profile | Your name : `<Votre nom>` · Server name : `<user>-knox` **ou** `<user>-canary` · Username : votre compte personnel · Password : robuste |
| Ubuntu Pro | Skip for now |
| **SSH** | **Knox : NE PAS cocher « Install OpenSSH server »** ❗ · **Canary : cocher** |
| Featured snaps | Aucun |

> ❗ **Knox ne doit avoir aucun service SSHD installé.** Il n'est accessible que par la console Proxmox. Un SSHD présent sur Knox coûte **3 points**.

À la fin : **Reboot Now**. Si la console affiche « Please remove the installation medium », appuyer sur Entrée.

### 3.1 Agrandir le volume LVM (recommandé)

Par défaut, l'installateur n'attribue qu'une partie du disque de 25 Go au volume racine. Comme Knox stocke les sauvegardes, il faut récupérer l'espace restant :

```bash
df -h /                                                  # avant
sudo lvextend -l +100%FREE -r /dev/ubuntu-vg/ubuntu-lv   # -r agrandit aussi le système de fichiers
df -h /                                                  # après : ~23 Go
```

---

## 4. Préparation après l'installation (Knox et Canary)

Se connecter dans la console avec votre compte personnel.

### 4.1 Mises à jour

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot        # si un nouveau noyau a été installé
```

> Cette opération est à refaire régulièrement pendant tout le projet.

### 4.2 Fuseau horaire

Utile pour que les journaux, `cron` et `monitor.log` affichent l'heure locale :

```bash
sudo timedatectl set-timezone America/Toronto
timedatectl
```

### 4.3 qemu-guest-agent

```bash
sudo apt install -y qemu-guest-agent
sudo systemctl start qemu-guest-agent
systemctl status qemu-guest-agent
```

> Sur Ubuntu 24.04, `systemctl enable qemu-guest-agent` peut répondre que l'unité est *static*. C'est normal : le service démarre automatiquement grâce à udev lorsque l'option *Qemu Agent* est activée dans Proxmox.

**Vérification :** dans Proxmox, onglet **Summary** de la VM, l'adresse IP doit maintenant s'afficher. Si ce n'est pas le cas, faire un **Shutdown** puis un **Start** (un simple *Reboot* ne suffit pas).

### 4.3.1 Console série xterm.js (copier-coller sans SSH)

La console noVNC ne permet pas le copier-coller. Comme Knox n'a pas (et ne doit pas avoir) de SSHD, on ajoute une **console série**. Ce n'est pas un service réseau : rien n'écoute sur le réseau, donc l'exigence « Knox accessible seulement physiquement » est respectée.

1. Proxmox → VM → **Hardware** → **Add** → **Serial Port** → numéro `0` → **Add**.
2. **Shutdown** complet de la VM, puis **Start**. Un *Reboot* ne suffit pas : le nouveau matériel n'est appliqué qu'au démarrage à froid.
3. Dans la console noVNC :
   ```bash
   ls -l /dev/ttyS0                                          # le port doit exister
   sudo systemctl enable --now serial-getty@ttyS0.service
   systemctl status serial-getty@ttyS0.service               # enabled + active (running)
   ```
4. Bouton **Console ▾** → **xterm.js**, puis appuyer sur Entrée pour voir l'invite de connexion. Coller avec Ctrl+Shift+V ou un clic droit.

> Problème rencontré : `Dependency failed for serial-getty@ttyS0.service`. Cause : `/dev/ttyS0` n'existait pas, car la VM avait seulement été redémarrée après l'ajout du port. Solution : Shutdown puis Start, et ensuite `enable --now`.

### 4.4 Compte sudo `david` (enseignant)

À faire sur **chaque serveur** : Knox, Canary **et** VPS.

```bash
sudo adduser david              # mot de passe robuste et unique
sudo usermod -aG sudo david
groups david                    # doit afficher : david : david sudo
```

Envoyer les mots de passe par courriel à **turcottedavid@cgmatane.qc.ca**. ⚠️ Ne jamais les mettre dans le dépôt GitHub.

### 4.5 Vérifications propres à chaque VM

**Knox : confirmer l'absence de SSHD**

```bash
dpkg -l | grep openssh-server   # ne doit rien afficher
ss -tlnp                        # aucun service en écoute sur le port 22
```

Si `openssh-server` est présent :

```bash
sudo apt purge -y openssh-server && sudo apt autoremove -y
```

> `openssh-client` (la commande `ssh`) **doit rester installé** : Knox s'en sert pour aller chercher les sauvegardes sur le VPS.

**Knox : vérifier que le réseau du cégep laisse sortir le port 870**

Knox devra joindre le VPS sur le port 870. Pour vérifier que la sortie n'est pas bloquée avant même d'avoir configuré le VPS (`portquiz.net` répond sur tous les ports) :

```bash
nc -vz portquiz.net 870
```

**Canary : SSH fonctionnel**

```bash
systemctl status ssh
```

Depuis votre poste, sur le réseau filaire : `ssh <compte>@<ip-canary>`

### 4.5.1 Problèmes rencontrés sur Canary

- **`qemu-guest-agent` : « Erreur temporaire de résolution »** pendant l'installation. Cause : le `full-upgrade` venait de redémarrer `systemd-resolved` et `systemd-networkd`, donc le DNS était indisponible quelques secondes. Solution : `sudo reboot`, ce qui charge aussi le nouveau noyau, puis relancer l'installation.
- **« No route to host » après un redémarrage.** Cause : l'IP est attribuée par DHCP et change d'un redémarrage à l'autre (.82 → .39). Solution : vérifier l'IP dans le **Summary** de Proxmox avant chaque connexion SSH.
- **Disque de 11,5 Go au lieu de 25 Go** : agrandi avec `lvextend` (voir la section 3.1).

### 4.6 Snapshot de référence

Dans Proxmox → VM → **Snapshots** → **Take Snapshot** :

- Name : `base-install`
- Description : « Ubuntu 24.04 à jour, qemu-agent, compte david »

Ce snapshot permet de revenir en arrière avant de tester une configuration risquée.

---

## 5. VPS : état initial

Le VPS du projet est **le même serveur que le staging de Transaction Web**. La pile LAMP et un site avec base de données y sont donc probablement déjà en place. Avant de durcir quoi que ce soit, il faut faire l'inventaire et prendre une sauvegarde, pour ne pas casser le staging.

### 5.1 Sauvegarde avant les modifications

- Prendre un snapshot ou une sauvegarde chez le fournisseur du VPS, si l'option existe.
- Sinon, au minimum :

```bash
sudo tar czf ~/avant-projet-$(date +%F).tgz /etc/ssh /etc/apache2 /etc/ufw
sudo mysqldump --all-databases > ~/avant-projet-$(date +%F).sql
```

### 5.2 Inventaire

```bash
lsb_release -a                          # version d'Ubuntu
apache2 -v; php -v; mysql --version     # pile LAMP
sudo ufw status verbose                 # pare-feu
sudo ss -tlnp                           # services en écoute
ls /etc/apache2/sites-enabled/          # VHOST(s) actif(s)
ls /etc/ssh/sshd_config.d/              # fichiers qui peuvent redéfinir la config SSH
systemctl status fail2ban               # déjà installé ?
```

Noter dans ce document :

- Le nom de domaine ou sous-domaine du site : `<a compléter>`
- Le nom de la base de données : `<a compléter>`
- Le chemin du site : `/var/www/<a compléter>`

### 5.3 ⚠️ Ce qui peut affecter le staging de Transaction Web

| Changement du projet | Impact possible | À vérifier |
|---|---|---|
| SSH sur le port **870** | Les déploiements par SSH (GitHub Actions, scripts, VS Code Remote) qui visent le port 22 cessent de fonctionner | Mettre à jour le port dans les secrets et workflows CI et dans `~/.ssh/config` |
| SSH **par clé seulement** | Tout déploiement par mot de passe échoue | Le pipeline doit utiliser une clé |
| Interdiction de `root` en SSH | Un déploiement qui se connecte en `root` échoue | Utiliser un compte dédié |
| UFW activé | Un port oublié (p. ex. MySQL à distance) est bloqué | Comparer avec le `ss -tlnp` ci-dessus |
| Fail2ban | Une IP de CI ou de collègue peut être bannie | Utiliser `ignoreip` au besoin |

### 5.4 Mises à jour et compte `david`

```bash
sudo apt update && sudo apt full-upgrade -y
```

Puis créer le compte `david` (voir la section 4.4).

---

## Liste de vérification

- [ ] `<user>-knox` créée (1 vCPU, Nehalem, 2048 Mo, 25 Go, Qemu Agent)
- [ ] `<user>-canary` créée (mêmes paramètres)
- [ ] Ubuntu Server 24.04 installé sur les deux VM
- [ ] **Aucun** `openssh-server` sur Knox
- [ ] qemu-guest-agent actif : l'IP s'affiche dans le Summary
- [ ] Compte `david` sudo sur Knox, Canary et VPS, mots de passe envoyés par courriel
- [ ] Snapshot `base-install` pris sur les deux VM
- [ ] Inventaire et sauvegarde du VPS faits
- [ ] Sortie vers le port 870 testée depuis Knox
