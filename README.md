# Projet de sécurité — Renforcement d'un environnement et piège pour attaquant

**Cours :** Sécurité informatique — Automne 2026
**Équipe :** Edan Francoeur
**Remise :** 13 novembre 2026

> Documentation produite avec l'aide d'une intelligence artificielle générative.

## Architecture

| Serveur | Hébergement | Rôle | SSH |
|---|---|---|---|
| **VPS** | VPS externe (même serveur que le staging de Transaction Web) | Site Web LAMP + BD, durci (SSH, UFW, Apache, HTTPS, Fail2ban) | Oui, port **870**, clé seulement |
| **Knox** | VM Proxmox (`edanf-knox`) | Va chercher les sauvegardes du VPS et surveille l'intégrité de 2 fichiers | **Non** : console Proxmox seulement |
| **Canary** | VM Proxmox (`edanf-canary`) | Pot de miel OpenCanary (serveur Web Linux + MySQL, portscan, alertes courriel) | Oui (administration) |

```
            Internet
                │
        ┌───────┴────────┐
        │      VPS       │  Apache/PHP/MySQL, SSH:870, UFW, Fail2ban
        └───────▲────────┘
                │  rsync/ssh -p 870 (initié par Knox)
   ─ ─ ─ ─ ─ ─ ─│─ ─ ─ ─ ─ ─ Réseau du cégep (filaire O-106 / O-155 / O-157)
        ┌───────┴────────┐        ┌────────────────┐
        │      Knox      │        │     Canary     │
        │ sauvegardes +  │        │  OpenCanary    │
        │ empreintes     │        │  (pot de miel) │
        └────────────────┘        └────────────────┘
              Proxmox 10.1.106.200 (pve1 / pve2)
```

## Procédures (dans l'ordre)

1. [Préparation de l'environnement](docs/00-preparation-environnement.md) : VM Proxmox, Ubuntu Server 24.04, console série, compte `david`
2. [VPS](docs/01-vps-partie1.md) : SSH (port 870, clé RSA, root interdit, robert), UFW, Apache (`partage`, signatures), HTTPS, base séparée, Fail2ban (sshd + phpMyAdmin)
3. [Knox](docs/02-knox.md) : sauvegardes (rsync + liens physiques, permissions conservées), surveillance de l'intégrité (SHA-256), cron, restauration
4. [Canary](docs/03-canary.md) : OpenCanary (Web Linux, MySQL, portscan), service systemd, alertes par courriel

## Scripts

| Script | Machine | Rôle |
|---|---|---|
| [`scripts/knox/sauvegarde.sh`](scripts/knox/sauvegarde.sh) | Knox | Sauvegarde de `/var/www`, `/home` et de la base `candyshop_secu` |
| [`scripts/knox/surveillance.sh`](scripts/knox/surveillance.sh) | Knox | Empreintes SHA-256 de 4 fichiers de configuration du VPS → `monitor.log` |

## Vidéos de démonstration

- Partie 1 : présentation et VPS : <lien>
- Partie 2 : Knox : <lien>
- Partie 3 : Canary : <lien>

## Arborescence du dépôt

```
.
├── README.md
├── docs/          # procédures d'installation et de configuration
├── scripts/       # scripts (sauvegarde, empreintes, etc.)
└── config/        # extraits de fichiers de configuration (sans secrets)
```
