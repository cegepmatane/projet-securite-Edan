# 03 — Canary : pot de miel OpenCanary

> Produit avec l'aide d'une intelligence artificielle générative.

| Élément | Valeur |
|---|---|
| VM | `edanf-canary` (Proxmox, pve2), Ubuntu 24.04 LTS |
| IP | Attribuée par DHCP (p. ex. `10.1.106.39`), visible dans le **Summary** de Proxmox |
| Logiciel | OpenCanary 0.9.10 (https://github.com/thinkst/opencanary) |
| Leurres | Serveur Web Linux (port 80), MySQL (port 3306), détection des balayages de ports |
| Configuration | `/etc/opencanaryd/opencanary.conf` (mode 600) |
| Journal | `/var/log/opencanary.log` (+ `/var/log/kern.log` pour le portscan) |
| Service | `opencanary.service` (systemd, démarre avec le système) |
| Alertes | Courriel via Gmail (SMTP, port 587) |

## Principe

Un pot de miel est un faux serveur qui n'a **aucun usage légitime**. Personne n'a de raison de s'y connecter : **toute** connexion est donc suspecte et déclenche une alerte. Canary se fait passer pour un serveur Linux avec un site Web et une base MySQL, ce qui attire un attaquant déjà présent sur le réseau et révèle sa présence.

---

## 1. Installation

OpenCanary est installé avec `pip` dans un **environnement virtuel** (`/opt/opencanary`), séparé des paquets Python du système.

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y python3-dev python3-venv build-essential libssl-dev libffi-dev libpcap-dev iptables
sudo python3 -m venv /opt/opencanary
sudo /opt/opencanary/bin/pip install --upgrade pip setuptools wheel
sudo /opt/opencanary/bin/pip install opencanary scapy pcapy-ng
```

Vérification et création de la configuration par défaut :

```bash
sudo env "PATH=/opt/opencanary/bin:$PATH" opencanaryd --version      # 0.9.10
sudo env "PATH=/opt/opencanary/bin:$PATH" opencanaryd --copyconfig   # → /etc/opencanaryd/opencanary.conf
```

> `opencanaryd` est un script qui lance le premier `python3` trouvé dans le `PATH`. Sans `/opt/opencanary/bin` en tête du `PATH`, il prend le Python du système, qui ne connaît pas OpenCanary (`No module named 'opencanary'`).

## 2. Configuration des leurres

On désactive **tous** les services, puis on active seulement ceux que l'énoncé demande. Un script Python modifie le JSON, ce qui évite les erreurs de syntaxe d'une édition à la main :

```bash
sudo python3 - <<'EOF'
import json
p = "/etc/opencanaryd/opencanary.conf"
c = json.load(open(p))
for cle in c:
    if cle.endswith(".enabled"):
        c[cle] = False
c.update({
    "device.node_id": "edanf-canary",
    "http.enabled": True,
    "http.port": 80,
    "http.skin": "nasLogin",
    "http.banner": "Apache/2.4.58 (Ubuntu)",
    "mysql.enabled": True,
    "mysql.port": 3306,
    "mysql.banner": "5.7.42-0ubuntu0.18.04.1",
    "portscan.enabled": True,
    "portscan.logfile": "/var/log/kern.log",
    "portscan.ignore_localhost": False,
})
c["logger"]["kwargs"]["handlers"]["file"]["filename"] = "/var/log/opencanary.log"
json.dump(c, open(p, "w"), indent=4)
EOF
sudo python3 -m json.tool /etc/opencanaryd/opencanary.conf > /dev/null && echo "JSON valide"
```

Extrait de la configuration obtenue :

```json
"device.node_id": "edanf-canary",
"http.enabled": true,
"http.port": 80,
"http.skin": "nasLogin",
"http.banner": "Apache/2.4.58 (Ubuntu)",
"mysql.enabled": true,
"mysql.port": 3306,
"mysql.banner": "5.7.42-0ubuntu0.18.04.1",
"portscan.enabled": true,
"portscan.logfile": "/var/log/kern.log",
"portscan.ignore_localhost": false,
```

| Réglage | Rôle |
|---|---|
| `http.*` | Faux serveur Web : page de connexion, bannière `Apache/2.4.58 (Ubuntu)` pour imiter un serveur Linux |
| `mysql.*` | Faux serveur MySQL : enregistre l'utilisateur et l'empreinte du mot de passe essayés |
| `portscan.*` | OpenCanary ajoute des règles `iptables` qui journalisent les paquets suspects (préfixes `canaryfw`, `canarynmap`, etc.) dans `kern.log`, puis les analyse |

Le vrai SSH de Canary (port 22) reste actif pour l'administration. Il rend aussi le leurre plus crédible.

## 3. Démarrage automatique (systemd)

`/etc/systemd/system/opencanary.service` :

```ini
[Unit]
Description=OpenCanary - pot de miel
After=network-online.target rsyslog.service
Wants=network-online.target

[Service]
Type=simple
Environment="PATH=/opt/opencanary/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/opt/opencanary/bin/opencanaryd --dev
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now opencanary
systemctl status opencanary                              # enabled + active (running)
sudo ss -tlnp | grep -E ':(80|3306)\b'                   # 80 et 3306 en écoute
sudo iptables-legacy -t mangle -L PREROUTING -n | grep canary
```

> `--dev` lance OpenCanary au premier plan : systemd le surveille et le relance en cas de plantage (`Restart=on-failure`).

> Les règles du portscan sont créées avec `iptables-legacy`. La commande `iptables` standard (nftables) ne les montre pas.

## 4. Alertes par courriel (boni)

Prérequis : un compte Gmail avec la validation en deux étapes et un **mot de passe d'application** (myaccount.google.com/apppasswords).

Le script demande l'adresse et le mot de passe d'application **au clavier** (masqué). Le secret ne se retrouve ni à l'écran ni dans l'historique du shell :

```bash
cat > ~/config-courriel.py <<'EOF'
import json, getpass
p = "/etc/opencanaryd/opencanary.conf"
c = json.load(open(p))
adresse = input("Adresse Gmail (expéditeur et destinataire) : ").strip()
mdp = getpass.getpass("Mot de passe d'application (16 lettres) : ").replace(" ", "")
c["logger"]["kwargs"]["handlers"]["SMTP"] = {
    "class": "logging.handlers.SMTPHandler",
    "mailhost": ["smtp.gmail.com", 587],
    "fromaddr": adresse,
    "toaddrs": [adresse],
    "subject": "ALERTE OpenCanary - edanf-canary",
    "credentials": [adresse, mdp],
    "secure": []
}
json.dump(c, open(p, "w"), indent=4)
EOF
sudo python3 ~/config-courriel.py
rm ~/config-courriel.py
sudo chmod 600 /etc/opencanaryd/opencanary.conf      # contient le mot de passe d'application
sudo systemctl restart opencanary
```

> `"secure": []` active STARTTLS sur le port 587 : la connexion à Gmail est chiffrée.

> OpenCanary envoie **un courriel par événement**. Un balayage `nmap` produit donc plusieurs courriels.

## 5. Tests (depuis le portable, `10.1.106.58`)

| Test | Commande | Alerte (`logtype`) |
|---|---|---|
| Balayage de ports | `sudo nmap -sS -Pn 10.1.106.39` | **5001** + lignes `canaryfw:` dans `kern.log` |
| Page Web | Ouvrir `http://10.1.106.39` | **3000** (visite) |
| Connexion Web | Faux utilisateur et mot de passe | **3001** (identifiants tapés) |
| MySQL | `mysql -h 10.1.106.39 -u root -p` | **8001** (utilisateur + empreinte du mot de passe) |

```bash
sudo grep -v '"logtype": 1001' /var/log/opencanary.log | tail      # alertes (sans les messages de démarrage)
sudo grep canaryfw /var/log/kern.log | tail -3
```

Exemple d'alerte de connexion Web :

```json
{"dst_host": "10.1.106.39", "dst_port": 80,
 "logdata": {"PASSWORD": "asd;cfklmfmdal", "USERNAME": "qkalsc", "SKIN": "nasLogin", "PATH": "/index.html", ...},
 "logtype": 3001, "node_id": "edanf-canary", "src_host": "10.1.106.58", ...}
```

`src_host` identifie l'attaquant, et les identifiants qu'il a essayés sont enregistrés. Le même JSON arrive par courriel (sujet « ALERTE OpenCanary - edanf-canary »).

## 6. Problèmes rencontrés

| Problème | Cause | Solution |
|---|---|---|
| `opencanaryd --version` : `No module named 'opencanary'` | Le script utilisait le Python du système | `PATH=/opt/opencanary/bin:$PATH` (aussi dans le service systemd) |
| Page Web : « Processing Failed » | L'apparence `basicLogin` du paquet pip n'a pas de `redirect.html` (`FileNotFoundError`) | `http.skin = "nasLogin"`, qui est complète |
| Le script de courriel ne laissait rien taper (`EOFError`) | Avec `python3 - <<EOF`, l'entrée standard est le script lui-même, donc `input()` ne lit rien | Écrire le script dans un fichier, puis l'exécuter |
| `iptables -L` ne montre pas les règles `canaryfw` | Règles créées avec `iptables-legacy` | `sudo iptables-legacy -t mangle -L PREROUTING -n` |
