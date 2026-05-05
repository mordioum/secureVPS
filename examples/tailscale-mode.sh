#!/usr/bin/env bash
# Exemple : Sécurisation d'un VPS protégé par Tailscale
# 
# Procédure plus rapide car SSH est déjà protégé par le VPN Tailscale
# - Pas besoin de port 2222 (SSH inaccessible publiquement)
# - Pas besoin de whitelist IP fail2ban (Tailscale fait le boulot)
# - UFW en mode strict suffit

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

sudo ./vps-secure.sh \
    --user mor \
    --port 2222 \
    --mode strict
