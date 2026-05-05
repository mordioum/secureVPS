# Changelog

Toutes les modifications notables sont documentées ici.

## [1.0.0] - 2026-05-05

### 🎉 Version initiale

Créé après une journée intensive de sécurisation de 4 VPS Contabo en production.

#### Fonctionnalités
- ✅ Audit initial complet du VPS
- ✅ Création utilisateur non-root + sudo + clé SSH
- ✅ Durcissement SSH (port custom, root no, password no, AllowUsers)
- ✅ Gestion socket activation Ubuntu 24+/26+
- ✅ Détection cloud-init qui override SSH
- ✅ Fail2ban avec whitelist IP automatique (leçon SAFRU)
- ✅ UFW intelligent (3 modes : strict, web, production)
- ✅ Détection automatique Docker pour préserver les ports
- ✅ Détection Tailscale pour adapter la stratégie
- ✅ Mises à jour automatiques (unattended-upgrades)
- ✅ Mode interactif et automatisé (paramètres CLI)
- ✅ Logs structurés
- ✅ Backups SSH avant modifications
- ✅ Modules indépendants exécutables séparément

#### Scripts complémentaires
- 🐳 `docker-install.sh` : installation Docker + Dokploy
- 💾 `backup.sh` : backup auto des DBs Docker (PostgreSQL, MySQL, MariaDB, MongoDB)

#### Compatibilité
- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Ubuntu 26.04 LTS

#### Support
- Détection automatique de la version Ubuntu
- Adaptation socket activation selon la version
- Préservation des services en cours
