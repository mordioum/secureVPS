#!/usr/bin/env bash
# Exemple : Sécurisation d'un VPS de production avec Docker
#
# Pour serveur avec apps clients (Dokploy, Nginx Proxy Manager, etc.)
# - Mode production (auto-détection ports Docker)
# - Garde port 22 ouvert pour transition safe
# - IP de l'admin whitelistée dans fail2ban

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# IMPORTANT : remplacez par VOS valeurs
ADMIN_IP="$(curl -4 -s ifconfig.me)"  # ou hardcoder votre IP

echo "Votre IP détectée : ${ADMIN_IP}"
read -p "Confirmer cette IP ? [O/n] " -n 1 -r
echo

if [[ -z "${REPLY}" ]] || [[ ${REPLY} =~ ^[OoYy]$ ]]; then
    sudo ./vps-secure.sh \
        --user mor \
        --port 2222 \
        --ip "${ADMIN_IP}" \
        --mode production
else
    echo "Annulé"
    exit 1
fi
