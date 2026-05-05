# 🛡️ VPS-Secure

**Script de sécurisation universel pour VPS Ubuntu — Compatible 22.04, 24.04, 26.04**

Sécurise un VPS Ubuntu en quelques minutes : utilisateur non-root, SSH durci, fail2ban, UFW, mises à jour automatiques.

> 💡 Construit à partir de l'expérience réelle de sécurisation de plusieurs VPS Contabo en production avec Dokploy, Tailscale et apps clients critiques.

---

## ✨ Fonctionnalités

- 🔐 **SSH durci** : port custom, désactivation root, authentification par clé uniquement
- 🛡️ **Pare-feu UFW** : 3 modes (strict, web, production avec auto-détection Docker)
- 🚫 **Fail2ban** : whitelist automatique de votre IP **dès le départ** (évite les bannissements accidentels)
- 👤 **Utilisateur non-root** avec sudo et clé SSH
- 🔄 **Mises à jour automatiques** (unattended-upgrades + auto-reboot kernel)
- 🐳 **Détection Docker** : préserve les ports nécessaires aux containers
- 🔒 **Tailscale-aware** : adapte la stratégie si Tailscale est détecté
- 📊 **Audit complet** avant/après avec score de sécurité
- 🔧 **Modes interactif et automatisé** (paramètres CLI)
- ⚠️ **Validations critiques** : l'humain valide chaque étape importante
- 📝 **Logs détaillés** : tout est tracé dans `/var/log/`

---

## 🚀 Installation rapide

### Méthode 1 : Clone du repo

```bash
# Cloner le repo
git clone https://github.com/mordioum/secureVPS.git
cd secureVPS

# Lancer le script principal
sudo ./vps-secure.sh
```

### Méthode 2 : One-liner (curl)

```bash
curl -sSL https://raw.githubusercontent.com/mordioum/secureVPS/main/install.sh | sudo bash
```

> ⚠️ **Conseil pro** : avant de faire `curl | bash` sur un VPS en production, **lisez le script** pour comprendre ce qu'il fait. C'est votre serveur, vous êtes responsable.

---

## 📋 Prérequis

- ✅ Ubuntu 22.04, 24.04 ou 26.04
- ✅ Accès root (ou sudo)
- ✅ Une clé SSH publique (recommandé : Ed25519)
- ✅ Connaître votre IP publique (pour la whitelist fail2ban)

### Comment générer une clé SSH (sur votre Mac/Linux/Windows)

```bash
# Création d'une clé Ed25519 (recommandé)
ssh-keygen -t ed25519 -C "votre@email.com"

# Récupérer la clé publique pour la coller
cat ~/.ssh/id_ed25519.pub
```

### Comment trouver votre IP publique

```bash
curl -4 ifconfig.me
```

---

## 🎯 Usage

### Mode interactif (recommandé pour débuter)

```bash
sudo ./vps-secure.sh
```

Le script vous posera toutes les questions nécessaires.

### Mode automatisé

```bash
sudo ./vps-secure.sh \
    --user mor \
    --port 2222 \
    --ip 196.207.227.109 \
    --mode production
```

### Modules individuels

Si vous voulez exécuter une seule étape :

```bash
# Audit seul (lecture seule, ne modifie rien)
sudo ./modules/00-audit.sh

# Création utilisateur seule
sudo ./modules/01-create-user.sh

# Durcissement SSH seul
sudo ./modules/02-ssh-harden.sh

# Fail2ban seul
sudo ./modules/03-fail2ban.sh

# UFW seul
sudo ./modules/04-ufw.sh

# Mises à jour seules
sudo ./modules/05-updates.sh
```

---

## 🔧 Options du script principal

```
Options principales:
  --user USERNAME       Nom de l'utilisateur non-root à créer
  --port PORT           Port SSH secondaire (défaut: 2222)
  --ip IP               Votre IP publique pour whitelist fail2ban
  --pubkey "KEY"        Clé SSH publique à autoriser
  --mode MODE           Mode UFW: strict|web|production (défaut: production)

Options de skip (utilisation modulaire):
  --skip-audit          Sauter l'audit initial
  --skip-user           Sauter la création d'utilisateur
  --skip-ssh            Sauter le durcissement SSH
  --skip-fail2ban       Sauter fail2ban
  --skip-ufw            Sauter UFW
  --skip-updates        Sauter les MAJ système

Autres:
  --dry-run             Simuler sans rien modifier
  -h, --help            Afficher cette aide
```

---

## 📦 Scripts complémentaires

### 🐳 docker-install.sh

Installe Docker + Docker Compose, optionnellement Dokploy.

```bash
sudo ./docker-install.sh
```

### 💾 backup.sh

Backup automatique des bases de données Docker (PostgreSQL, MySQL, MariaDB, MongoDB).

```bash
# Backup ponctuel
sudo ./backup.sh

# Backup automatique (cron)
sudo crontab -e
# Ajouter : 0 2 * * * /chemin/vers/backup.sh > /var/log/backup.log 2>&1
```

---

## 🎓 Modes UFW

### Mode `strict`
SSH uniquement. Pour serveurs sans services publics ou avec Tailscale.

### Mode `web`
SSH + ports 80/443. Pour serveur web standard.

### Mode `production`
SSH + 80/443 + détection automatique des ports Docker. Pour serveurs avec apps Docker (Dokploy, Nginx Proxy Manager, etc.).

---

## 🛡️ Sécurités intégrées

Basé sur des expériences réelles de production, le script intègre :

- ✅ **Whitelist IP DÈS LE DÉBUT** dans fail2ban (évite l'auto-bannissement)
- ✅ **Détection socket activation** Ubuntu 24+/26+ (gère le cas spécial)
- ✅ **Détection cloud-init** qui peut override SSH
- ✅ **Filet de sécurité** : port 22 maintenu en parallèle du nouveau port
- ✅ **Validation `sshd -T`** AVANT reload SSH
- ✅ **Backup config SSH** avant modifications
- ✅ **Détection Tailscale** : adapte la stratégie UFW
- ✅ **Détection Docker** : préserve les ports des containers
- ✅ **Confirmations multiples** sur les actions critiques

---

## 🆘 En cas de problème

### Si vous perdez l'accès SSH

1. **Connectez-vous via la console VNC** de votre fournisseur (Contabo, OVH, Hetzner, etc.)
2. **Restaurez la configuration SSH** :
   ```bash
   sudo cp -r /root/ssh-backup-*/sshd_config* /etc/ssh/
   sudo systemctl reload ssh
   ```
3. **Désactivez UFW si bloqué** :
   ```bash
   sudo ufw disable
   ```
4. **Débannissez votre IP de fail2ban** :
   ```bash
   sudo fail2ban-client unban <VOTRE_IP>
   ```

### Si fail2ban vous bannit

```bash
# Voir les IPs bannies
sudo fail2ban-client status sshd

# Débannir une IP
sudo fail2ban-client unban <IP>

# Ajouter votre IP à la whitelist (dans /etc/fail2ban/jail.local)
sudo nano /etc/fail2ban/jail.local
# Modifier la ligne : ignoreip = 127.0.0.1/8 ::1 <VOTRE_IP>
sudo systemctl reload fail2ban
```

---

## 📝 Logs

Tous les actions sont loggées dans :
```
/var/log/vps-secure-YYYYMMDD-HHMMSS.log
```

---

## 🗂️ Structure du projet

```
vps-secure/
├── vps-secure.sh             # Script principal (orchestrateur)
├── docker-install.sh         # Installation Docker
├── backup.sh                 # Backup auto des DBs Docker
├── README.md                 # Cette documentation
├── LICENSE                   # MIT
│
├── lib/                      # Fonctions communes
│   ├── colors.sh             # Couleurs terminal
│   ├── logging.sh            # Logs structurés
│   ├── checks.sh             # Vérifications système
│   └── prompts.sh            # Questions interactives
│
└── modules/                  # Modules indépendants
    ├── 00-audit.sh           # Audit initial
    ├── 01-create-user.sh     # Création user + clé SSH
    ├── 02-ssh-harden.sh      # Durcissement SSH
    ├── 03-fail2ban.sh        # Fail2ban + whitelist
    ├── 04-ufw.sh             # UFW pare-feu
    └── 05-updates.sh         # MAJ système
```

---

## 🤝 Contributions

Les contributions sont les bienvenues ! N'hésitez pas à :

- 🐛 Signaler des bugs (Issues)
- 💡 Proposer des améliorations (Pull Requests)
- 📚 Améliorer la documentation
- 🧪 Tester sur d'autres distributions

---

## ⚠️ Disclaimer

Ce script effectue des modifications système importantes. Bien qu'il intègre de nombreux garde-fous :

- 🔍 **Lisez le script avant de l'exécuter** sur un serveur de production
- 💾 **Faites un backup** de vos configurations avant
- 🆘 **Gardez un accès VNC** comme filet de sécurité
- 🧪 **Testez sur un serveur non-critique** avant la prod

L'auteur ne peut être tenu responsable de pertes de données ou d'accès liées à l'utilisation de ce script.

---

## 📜 Licence

MIT — Voir [LICENSE](./LICENSE)

---

## 👤 Auteur

**Mor Dioum**
- GitHub : [@mordioum](https://github.com/mordioum)

---

## 🙏 Crédits

Script inspiré par de nombreuses heures de gestion de VPS Contabo en production avec Dokploy, Cloudflare Tunnel, Tailscale et clients critiques sénégalais (DGCH, SAFRU, BMESURE, etc.).
