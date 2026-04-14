#!/bin/bash
# =============================================================================
# ripristino_uefi_popos.sh
# Ripristina la entry UEFI di Pop!_OS su nvme2n1 da ambiente Debian Live
# Da eseguire come root dopo boot da USB Debian Live
#
# Uso:
#   sudo bash ripristino_uefi_popos.sh           # modalità reale
#   sudo bash ripristino_uefi_popos.sh --dry-run  # simula senza eseguire
# =============================================================================

set -e

# --- Dry-run flag ---
DRY_RUN=false
if [[ "${1}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

# --- Colori ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR ]${NC} $*"; exit 1; }
drylog()  { echo -e "${MAGENTA}[DRY ]${NC} (simulato) $*"; }

# Esegue il comando oppure lo stampa in dry-run
run() {
    if $DRY_RUN; then
        drylog "$*"
    else
        eval "$*"
    fi
}

# =============================================================================
# MOCK per dry-run: sostituisce comandi che leggono hardware reale
# =============================================================================
mock_lsblk_disk()  { return 0; }   # simula disco presente
mock_lsblk_part()  { return 0; }   # simula partizione presente
mock_mountpoint()  { return 1; }   # simula non ancora montato
mock_efibootmgr_list() {
    echo "BootCurrent: 0000"
    echo "Timeout: 1 seconds"
    echo "BootOrder: 0000,0001"
    echo "Boot0000* Windows Boot Manager"
    echo "Boot0001* Pop_OS"
}
mock_efibootmgr_verbose() {
    mock_efibootmgr_list
    echo "Boot0001* Pop_OS HD(1,GPT,...)/File(\EFI\BOOT\BOOTX64.EFI)"
}
mock_ls_efi() { return 0; }        # simula BOOTX64.EFI presente
mock_efibootmgr_cmd() { drylog "efibootmgr $*"; }

# =============================================================================

# --- Configurazione ---
EFI_DISK="/dev/nvme2n1"
EFI_PART="${EFI_DISK}p1"
EFI_MOUNT="/mnt/efi"
EFI_FILE='\EFI\BOOT\BOOTX64.EFI'
LABEL="Pop_OS"
BACKUP_DIR="/home/user"
BACKUP_FILE="${BACKUP_DIR}/efi-backup-nvme2n1p1.img"

# =============================================================================
echo ""
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}  Ripristino Entry UEFI Pop!_OS             ${NC}"
if $DRY_RUN; then
echo -e "${MAGENTA}  *** MODALITA' DRY-RUN — nessuna modifica ***${NC}"
fi
echo -e "${CYAN}=============================================${NC}"
echo ""

# --- Verifica root (saltata in dry-run per permettere test senza sudo) ---
if ! $DRY_RUN && [[ $EUID -ne 0 ]]; then
    error "Esegui lo script come root: sudo bash $0"
fi
$DRY_RUN && drylog "Controllo root saltato in dry-run."

# --- Verifica disco ---
info "Verifico presenza disco ${EFI_DISK}..."
if $DRY_RUN; then
    mock_lsblk_disk && ok "Disco ${EFI_DISK} trovato. (simulato)"
elif ! lsblk "${EFI_DISK}" &>/dev/null; then
    error "Disco ${EFI_DISK} non trovato! Controlla con: lsblk"
else
    ok "Disco ${EFI_DISK} trovato."
fi

# --- Verifica partizione ---
info "Verifico presenza partizione EFI ${EFI_PART}..."
if $DRY_RUN; then
    mock_lsblk_part && ok "Partizione ${EFI_PART} trovata. (simulato)"
elif ! lsblk "${EFI_PART}" &>/dev/null; then
    error "Partizione ${EFI_PART} non trovata!"
else
    ok "Partizione ${EFI_PART} trovata."
fi

# --- Mount ---
info "Creo punto di mount ${EFI_MOUNT}..."
run "mkdir -p ${EFI_MOUNT}"

if $DRY_RUN; then
    mock_mountpoint || true
    drylog "mount ${EFI_PART} ${EFI_MOUNT}"
    ok "Partizione montata. (simulato)"
elif mountpoint -q "${EFI_MOUNT}"; then
    warn "${EFI_MOUNT} già montato, procedo."
else
    mount "${EFI_PART}" "${EFI_MOUNT}" || error "Mount fallito!"
    ok "Partizione montata."
fi

# --- Backup ---
echo ""
read -rp "$(echo -e "${YELLOW}Vuoi fare un backup della partizione EFI? (consigliato) [s/N]: ${NC}")" DO_BACKUP
if [[ "${DO_BACKUP,,}" == "s" ]]; then
    info "Backup in corso verso ${BACKUP_FILE}..."
    run "mkdir -p ${BACKUP_DIR}"
    if $DRY_RUN; then
        drylog "dd if=${EFI_PART} of=${BACKUP_FILE} bs=1M status=progress"
        ok "Backup completato. (simulato)"
    else
        dd if="${EFI_PART}" of="${BACKUP_FILE}" bs=1M status=progress 2>&1
        ok "Backup completato: ${BACKUP_FILE}"
    fi
else
    warn "Backup saltato."
fi

# --- Verifica BOOTX64.EFI ---
echo ""
info "Verifico presenza file EFI di Pop!_OS..."
if $DRY_RUN; then
    mock_ls_efi
    ok "BOOTX64.EFI trovato in ${EFI_MOUNT}/EFI/BOOT/ (simulato)"
elif ls "${EFI_MOUNT}/EFI/BOOT/BOOTX64.EFI" &>/dev/null; then
    ok "BOOTX64.EFI trovato in ${EFI_MOUNT}/EFI/BOOT/"
elif ls "${EFI_MOUNT}/EFI/" &>/dev/null; then
    warn "BOOTX64.EFI NON trovato. Contenuto attuale:"
    ls -lR "${EFI_MOUNT}/EFI/"
    echo ""
    read -rp "$(echo -e "${RED}File EFI mancante. Continuare comunque? [s/N]: ${NC}")" FORCE
    [[ "${FORCE,,}" != "s" ]] && error "Operazione annullata."
else
    error "La partizione EFI sembra vuota o danneggiata."
fi

# --- Installa efibootmgr ---
echo ""
info "Verifico efibootmgr..."
if $DRY_RUN; then
    drylog "apt-get update && apt-get install -y efibootmgr"
    ok "efibootmgr disponibile. (simulato)"
elif ! command -v efibootmgr &>/dev/null; then
    apt-get update -qq && apt-get install -y efibootmgr
    ok "efibootmgr installato."
else
    ok "efibootmgr già disponibile."
fi

# --- Mostra entry esistenti ---
echo ""
info "Entry UEFI attuali:"
if $DRY_RUN; then
    mock_efibootmgr_verbose
else
    efibootmgr -v
fi
echo ""

# --- Rimuovi entry duplicate Pop_OS ---
if $DRY_RUN; then
    EXISTING="0001"
    warn "Trovata entry esistente per '${LABEL}': Boot${EXISTING} (simulato)"
else
    EXISTING=$(efibootmgr | grep -i "${LABEL}" | grep -oP 'Boot\K[0-9A-Fa-f]+' || true)
fi

if [[ -n "${EXISTING}" ]]; then
    read -rp "$(echo -e "${YELLOW}Rimuovere la vecchia entry prima di aggiungerne una nuova? [s/N]: ${NC}")" DEL_OLD
    if [[ "${DEL_OLD,,}" == "s" ]]; then
        for BOOTNUM in ${EXISTING}; do
            info "Rimozione entry Boot${BOOTNUM}..."
            if $DRY_RUN; then
                drylog "efibootmgr -b ${BOOTNUM} -B"
            else
                efibootmgr -b "${BOOTNUM}" -B
            fi
            ok "Entry Boot${BOOTNUM} rimossa."
        done
    fi
fi

# --- Aggiunge entry UEFI ---
echo ""
info "Aggiunta entry UEFI '${LABEL}' su ${EFI_DISK} partizione 1..."
if $DRY_RUN; then
    drylog "efibootmgr -c -d ${EFI_DISK} -p 1 -L \"${LABEL}\" -l '\\EFI\\BOOT\\BOOTX64.EFI'"
else
    efibootmgr -c -d "${EFI_DISK}" -p 1 -L "${LABEL}" -l "${EFI_FILE}"
fi
ok "Entry UEFI aggiunta con successo!"

# --- Mostra risultato finale ---
echo ""
info "Entry UEFI risultanti:"
if $DRY_RUN; then
    echo "BootCurrent: 0000"
    echo "BootOrder: 0002,0000,0001"
    echo "Boot0000* Windows Boot Manager"
    echo "Boot0001  Pop_OS (vecchia, rimossa)"
    echo "Boot0002* Pop_OS  HD(1,GPT,...)/File(\EFI\BOOT\BOOTX64.EFI)"
else
    efibootmgr -v
fi

# --- Smonta ---
echo ""
info "Smonto ${EFI_MOUNT}..."
if $DRY_RUN; then
    drylog "umount ${EFI_MOUNT}"
else
    umount "${EFI_MOUNT}"
fi
ok "Partizione smontata."

# --- Fine ---
echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  Operazione completata!                    ${NC}"
if $DRY_RUN; then
echo -e "${MAGENTA}  (dry-run: nessuna modifica reale eseguita) ${NC}"
fi
echo -e "${GREEN}=============================================${NC}"
echo ""
echo -e "${YELLOW}IMPORTANTE:${NC}"
echo "  1. La entry '${LABEL}' è stata aggiunta come prima nel boot order."
echo "  2. Entra nel BIOS/UEFI e rimetti Windows Boot Manager come primo."
echo "  3. Riavvia e verifica che il dual boot funzioni correttamente."
echo ""
