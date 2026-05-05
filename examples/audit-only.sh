#!/usr/bin/env bash
# Exemple : Audit seul (lecture seule, ne modifie rien)
# 
# Utile pour évaluer la sécurité d'un VPS avant de décider quoi faire

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
sudo ./modules/00-audit.sh
