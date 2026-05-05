#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# VPS-SECURE - Installer one-liner
# Usage: curl -sSL https://raw.githubusercontent.com/mordioum/secureVPS/main/install.sh | sudo bash
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

REPO_URL="https://github.com/mordioum/secureVPS.git"
INSTALL_DIR="/opt/vps-secure"

echo ""
echo "🛡️  VPS-Secure - Installation"
echo ""

# Vérifier root
if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ Ce script doit être lancé en root (sudo)"
    exit 1
fi

# Installer git si nécessaire
if ! command -v git >/dev/null 2>&1; then
    echo "📦 Installation de git..."
    apt update -qq
    apt install -y git
fi

# Cloner ou mettre à jour le repo
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    echo "🔄 Mise à jour du repo..."
    cd "${INSTALL_DIR}"
    git pull
else
    echo "📥 Téléchargement de vps-secure..."
    rm -rf "${INSTALL_DIR}"
    git clone "${REPO_URL}" "${INSTALL_DIR}"
fi

# Permissions
chmod +x "${INSTALL_DIR}"/*.sh
chmod +x "${INSTALL_DIR}"/modules/*.sh

# Lien symbolique pour usage facile
ln -sf "${INSTALL_DIR}/vps-secure.sh" /usr/local/bin/vps-secure
ln -sf "${INSTALL_DIR}/backup.sh" /usr/local/bin/vps-backup
ln -sf "${INSTALL_DIR}/docker-install.sh" /usr/local/bin/vps-docker-install

echo ""
echo "✅ Installation terminée !"
echo ""
echo "Commandes disponibles :"
echo "  sudo vps-secure              # Sécurisation complète"
echo "  sudo vps-backup              # Backup des DBs"
echo "  sudo vps-docker-install      # Installer Docker"
echo ""
echo "Ou directement :"
echo "  cd ${INSTALL_DIR}"
echo "  sudo ./vps-secure.sh"
echo ""

# Lancer le script principal en interactif si demandé
# Important : ne demander que si stdin est un TTY. Quand l'installer est invoqué
# via `curl -sSL ... | sudo bash`, stdin est un pipe — `read` lit immédiatement EOF
# et REPLY="" déclencherait un auto-lancement non désiré, alors que vps-secure.sh
# a besoin d'un terminal pour ses prompts interactifs.
if [[ -t 0 ]]; then
    read -p "Lancer maintenant la sécurisation ? [O/n] " -n 1 -r
    echo
    if [[ -z "${REPLY}" ]] || [[ ${REPLY} =~ ^[OoYy]$ ]]; then
        "${INSTALL_DIR}/vps-secure.sh"
    fi
else
    echo "💡 Stdin non interactif — relancez manuellement :"
    echo "   sudo ${INSTALL_DIR}/vps-secure.sh"
fi
