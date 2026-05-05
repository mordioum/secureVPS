#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# BACKUP - Sauvegarde des bases de données Docker
# Détecte automatiquement PostgreSQL, MySQL, MariaDB, MongoDB
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=lib/colors.sh
source "${LIB_DIR}/colors.sh"
# shellcheck source=lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=lib/checks.sh
source "${LIB_DIR}/checks.sh"
# shellcheck source=lib/prompts.sh
source "${LIB_DIR}/prompts.sh"

init_logging
require_root

# Variables
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/root/backups}"
BACKUP_DIR="${BACKUP_BASE_DIR}/$(date +%Y%m%d-%H%M%S)"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

log_section "BACKUP DES BASES DE DONNÉES"

detect_docker

if [[ "${DOCKER_INSTALLED}" != "true" ]]; then
    log_error "Docker non installé"
    exit 1
fi

# Préparer le dossier
mkdir -p "${BACKUP_DIR}"
log_info "Dossier de backup : ${BACKUP_DIR}"

# ═══════════════════════════════════════════════════════════════════
# DÉTECTION DES CONTAINERS DB
# ═══════════════════════════════════════════════════════════════════

log_step "1. Détection des containers DB"

# Détection multi-critères (env vars > image > nom). Cumul des trois pour
# attraper les containers nommés sans convention (ex: fhs_jogdb_1 → MySQL).
# Découvert en prod : un MySQL appelé "jogdb" était passé entre les mailles
# de la regex initiale qui ne cherchait que "mysql|mariadb" dans le nom.
PG_CONTAINERS=()
MYSQL_CONTAINERS=()
MONGO_CONTAINERS=()

# Détection : on s'appuie d'abord sur l'IMAGE (preuve du type de service).
# Les env vars MYSQL_*/POSTGRES_*/MONGO_* ne sont PAS suffisantes : Docker
# Compose les propage souvent aux apps clientes (ex : une app Joget a
# MYSQL_USER/MYSQL_HOST/MYSQL_DATABASE pour se connecter au serveur, pas pour
# servir). Elles ont aussi MYSQL_ROOT_PASSWORD parfois quand l'orchestration
# leur passe la même variable d'environnement. Conclusion : seules l'image et
# le nom sont des indicateurs sûrs du type de service offert.
is_pg_container() {
    local image="$1" name="$2"
    echo "${image}" | grep -qiE '(^|/)(postgres|postgis|timescale)(:|$)' && return 0
    echo "${name}" | grep -qiE '(postgres|postgis)(_|-|$|^)' && return 0
    return 1
}

is_mysql_container() {
    local image="$1" name="$2"
    echo "${image}" | grep -qiE '(^|/)(mysql|mariadb|percona)(:|$)' && return 0
    echo "${name}" | grep -qiE '(mysql|mariadb|percona)(_|-|$|^)' && return 0
    return 1
}

is_mongo_container() {
    local image="$1" name="$2"
    echo "${image}" | grep -qiE '(^|/)mongo(:|$)' && return 0
    echo "${name}" | grep -qiE 'mongo(_|-|$|^)' && return 0
    return 1
}

while IFS= read -r container; do
    [[ -n "${container}" ]] || continue
    image="$(docker inspect "${container}" --format '{{.Config.Image}}' 2>/dev/null)"

    if is_pg_container "${image}" "${container}"; then
        PG_CONTAINERS+=("${container}")
    elif is_mysql_container "${image}" "${container}"; then
        MYSQL_CONTAINERS+=("${container}")
    elif is_mongo_container "${image}" "${container}"; then
        MONGO_CONTAINERS+=("${container}")
    fi
done < <(docker ps --format '{{.Names}}')

# Récap
echo ""
echo -e "${BOLD}Containers détectés :${RESET}"
echo -e "  PostgreSQL/PostGIS : ${#PG_CONTAINERS[@]}"
echo -e "  MySQL/MariaDB      : ${#MYSQL_CONTAINERS[@]}"
echo -e "  MongoDB            : ${#MONGO_CONTAINERS[@]}"

TOTAL=$(( ${#PG_CONTAINERS[@]} + ${#MYSQL_CONTAINERS[@]} + ${#MONGO_CONTAINERS[@]} ))
if [[ "${TOTAL}" -eq 0 ]]; then
    log_warn "Aucun container DB détecté"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════
# DUMP POSTGRESQL
# ═══════════════════════════════════════════════════════════════════

if [[ ${#PG_CONTAINERS[@]} -gt 0 ]]; then
    log_step "2. Backup PostgreSQL"
    
    for container in "${PG_CONTAINERS[@]}"; do
        # Récupérer les variables
        PG_USER="$(docker inspect "${container}" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^POSTGRES_USER=" | cut -d= -f2)"
        PG_PASS="$(docker inspect "${container}" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^POSTGRES_PASSWORD=" | cut -d= -f2)"
        PG_DB="$(docker inspect "${container}" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^POSTGRES_DB=" | cut -d= -f2)"
        
        # Defaults si pas trouvés
        PG_USER="${PG_USER:-postgres}"
        PG_DB="${PG_DB:-${PG_USER}}"
        
        # Nom du fichier (clean container name)
        SAFE_NAME="$(echo "${container}" | tr '/.' '__' | cut -c1-50)"
        OUT_FILE="${BACKUP_DIR}/postgres_${SAFE_NAME}.sql"
        LOG_FILE_OUT="${BACKUP_DIR}/postgres_${SAFE_NAME}.log"
        
        log_info "Dump ${container} (user=${PG_USER}, db=${PG_DB})..."
        
        if [[ -n "${PG_PASS}" ]]; then
            docker exec -e PGPASSWORD="${PG_PASS}" "${container}" \
                pg_dump -U "${PG_USER}" "${PG_DB}" > "${OUT_FILE}" 2>"${LOG_FILE_OUT}" || \
                log_warn "Erreur dump ${container} (voir ${LOG_FILE_OUT})"
        else
            docker exec "${container}" \
                pg_dump -U "${PG_USER}" "${PG_DB}" > "${OUT_FILE}" 2>"${LOG_FILE_OUT}" || \
                log_warn "Erreur dump ${container}"
        fi
        
        if [[ -s "${OUT_FILE}" ]]; then
            SIZE="$(du -h "${OUT_FILE}" | awk '{print $1}')"
            log_success "  ✓ ${SAFE_NAME} : ${SIZE}"
        fi
    done
fi

# ═══════════════════════════════════════════════════════════════════
# DUMP MYSQL/MARIADB
# ═══════════════════════════════════════════════════════════════════

if [[ ${#MYSQL_CONTAINERS[@]} -gt 0 ]]; then
    log_step "3. Backup MySQL/MariaDB"
    
    for container in "${MYSQL_CONTAINERS[@]}"; do
        MYSQL_PASS="$(docker inspect "${container}" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E "^(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD)=" | head -1 | cut -d= -f2)"
        
        SAFE_NAME="$(echo "${container}" | tr '/.' '__' | cut -c1-50)"
        OUT_FILE="${BACKUP_DIR}/mysql_${SAFE_NAME}.sql"
        LOG_FILE_OUT="${BACKUP_DIR}/mysql_${SAFE_NAME}.log"
        
        log_info "Dump ${container}..."
        
        docker exec -e MYSQL_PWD="${MYSQL_PASS}" "${container}" \
            mysqldump -u root --all-databases --single-transaction \
            > "${OUT_FILE}" 2>"${LOG_FILE_OUT}" || \
            log_warn "Erreur dump ${container} (voir ${LOG_FILE_OUT})"
        
        if [[ -s "${OUT_FILE}" ]]; then
            SIZE="$(du -h "${OUT_FILE}" | awk '{print $1}')"
            log_success "  ✓ ${SAFE_NAME} : ${SIZE}"
        fi
    done
fi

# ═══════════════════════════════════════════════════════════════════
# DUMP MONGODB
# ═══════════════════════════════════════════════════════════════════

if [[ ${#MONGO_CONTAINERS[@]} -gt 0 ]]; then
    log_step "4. Backup MongoDB"
    
    for container in "${MONGO_CONTAINERS[@]}"; do
        SAFE_NAME="$(echo "${container}" | tr '/.' '__' | cut -c1-50)"
        OUT_FILE="${BACKUP_DIR}/mongo_${SAFE_NAME}.archive.gz"
        LOG_FILE_OUT="${BACKUP_DIR}/mongo_${SAFE_NAME}.log"
        
        log_info "Dump ${container}..."
        
        docker exec "${container}" \
            mongodump --archive --gzip > "${OUT_FILE}" 2>"${LOG_FILE_OUT}" || \
            log_warn "Erreur dump ${container} (voir ${LOG_FILE_OUT})"
        
        if [[ -s "${OUT_FILE}" ]]; then
            SIZE="$(du -h "${OUT_FILE}" | awk '{print $1}')"
            log_success "  ✓ ${SAFE_NAME} : ${SIZE}"
        fi
    done
fi

# ═══════════════════════════════════════════════════════════════════
# RÉCAP
# ═══════════════════════════════════════════════════════════════════

log_step "5. Récapitulatif"

echo ""
echo -e "${BOLD}Fichiers de backup créés :${RESET}"
# `ls -lh` est volontaire : on veut le format humain (taille lisible).
# shellcheck disable=SC2012
ls -lh "${BACKUP_DIR}"/*.sql "${BACKUP_DIR}"/*.archive.gz 2>/dev/null | sed 's/^/  /' || true

echo ""
echo -e "${BOLD}Taille totale :${RESET}"
du -sh "${BACKUP_DIR}" | sed 's/^/  /'

# Rotation des anciens backups
echo ""
log_step "6. Rotation des anciens backups (> ${RETENTION_DAYS} jours)"

OLD_BACKUPS_COUNT="$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" 2>/dev/null | wc -l)"
if [[ "${OLD_BACKUPS_COUNT}" -gt 0 ]]; then
    log_info "${OLD_BACKUPS_COUNT} anciens backups détectés"
    
    if ask_yes_no "Supprimer les backups de plus de ${RETENTION_DAYS} jours ?" "y"; then
        find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -exec rm -rf {} \;
        log_success "Anciens backups supprimés"
    fi
else
    log_info "Aucun ancien backup à supprimer"
fi

log_section "BACKUP TERMINÉ"
log_info "Dossier : ${BACKUP_DIR}"
log_info "Pour transférer ailleurs (R2, autre VPS, Mac) :"
echo -e "  ${DIM}rsync -avz ${BACKUP_DIR}/ user@destination:~/backups/${RESET}"
echo ""
