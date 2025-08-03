#!/bin/bash
#########################################################
#                                                       #
#       pg_backup wrapper script for postgres hosts    #
#       Please test backups and recoveries!!           #
#       Prerequisites                                  #
#          1. Must be run as the postgres user         #
#          2. pg_backup and pigz installed             #
#          3. backup directory path exists             #
#          4. Change DbName and BackupDir              #
#             as needed                                #
#                                                       #
#########################################################

set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'        # Secure Internal Field Separator

# Script configuration
readonly SCRIPT_NAME="$(basename "$0")"

# Signal handlers for cleanup
trap '_cleanup_on_exit' EXIT
trap '_cleanup_on_signal' INT TERM

############## Configuration Section #####################
# Change to suite your environment
readonly DB_NAME="${1:-${DB_NAME:-IrysView_Dev}}"
readonly BACKUP_PATH="${BACKUP_PATH:-/mnt/$(hostname -s)/pgdump}"
readonly BACKUP_DIR="${DB_NAME}-$(date --iso-8601)"
readonly RETENTION_DAYS="${RETENTION_DAYS:-90}"
readonly PARALLEL_JOBS="${PARALLEL_JOBS:-10}"
readonly COMPRESSION_THREADS="${COMPRESSION_THREADS:-10}"

# Validate required environment
readonly REQUIRED_USER="postgres"
readonly REQUIRED_COMMANDS=("pg_back" "pigz" "tar" "find")

############## Logging Functions #########################
_log() {
    local level="$1"
    shift
    echo "[$level] $*"
}

_log_info() { _log "INFO" "$@"; }
_log_warn() { _log "WARN" "$@"; }
_log_error() { _log "ERROR" "$@"; }

############## Cleanup Functions #########################
_cleanup_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        _log_error "Script exited with error code: $exit_code"
        # Clean up partial backup if it exists
        if [[ -d "${BACKUP_PATH}/${BACKUP_DIR}" ]]; then
            _log_info "Cleaning up partial backup directory"
            rm -rf "${BACKUP_PATH:?}/${BACKUP_DIR:?}"
        fi
    fi
}

_cleanup_on_signal() {
    _log_warn "Script interrupted by signal"
    exit 130
}

############## Validation Functions ######################
_check_user() {
    if [[ "$(whoami)" != "$REQUIRED_USER" ]]; then
        _log_error "This script must be run as the $REQUIRED_USER user"
        return 1
    fi
}

_check_prereq() {
    local missing_commands=()
    
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        _log_error "Missing required commands: ${missing_commands[*]}"
        _log_info "Install missing packages:"
        _log_info "  yum install pigz -y"
        _log_info "  yum install https://github.com/orgrim/pg_back/releases/download/v2.4.0/pg-back-2.4.0-x86_64.rpm"
        return 1
    fi
}

_check_backup_dir() {
    if [[ ! -d "$BACKUP_PATH" ]]; then
        _log_error "Backup directory does not exist: $BACKUP_PATH"
        return 1
    fi
    
    if [[ ! -w "$BACKUP_PATH" ]]; then
        _log_error "Backup directory is not writable: $BACKUP_PATH"
        return 1
    fi
    
    # Check available space (warn if less than 10GB)
    local available_space
    available_space=$(df -BG "$BACKUP_PATH" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $available_space -lt 10 ]]; then
        _log_warn "Low disk space in backup directory: ${available_space}GB available"
    fi
}

############## Display Functions #########################
_start_msg() {
    _log_info "Starting backup of $DB_NAME on $(hostname -s)"
    cat << EOM
        +-------------------------------------------------------+
                  Backing up $DB_NAME on $(hostname -s)
        +-------------------------------------------------------+

EOM
}

_end_msg() {
    _log_info "Finished backup of $DB_NAME on $(hostname -s)"
    cat << EOM

        +---------------------------------------------------------------+
                Finished backing up $DB_NAME on $(hostname -s)
        +---------------------------------------------------------------+

EOM
}

_start_tar_msg() {
    _log_info "Starting compression of $BACKUP_DIR"
    cat << EOM

        +-------------------------------------------------------------------------------+
                starting tar $BACKUP_DIR
        +-------------------------------------------------------------------------------+

EOM
}

_end_tar_msg() {
    _log_info "Finished compression of $BACKUP_DIR"
    cat << EOM

        +-------------------------------------------------------------------------------+
                end tar $BACKUP_DIR
        +-------------------------------------------------------------------------------+

EOM
}

############## Backup Functions ##########################
_backup_db() {
    local backup_full_path="${BACKUP_PATH}/${BACKUP_DIR}"
    
    _log_info "Creating database backup in: $backup_full_path"
    
    # Create backup directory
    if ! mkdir -p "$backup_full_path"; then
        _log_error "Failed to create backup directory: $backup_full_path"
        return 1
    fi
    
    # Run pg_back with error handling
    if pg_back -b "$backup_full_path" -j "$PARALLEL_JOBS" -J 2 -Z0 -F directory; then
        _log_info "Database backup completed successfully"
        return 0
    else
        _log_error "Database backup failed"
        return 1
    fi
    
    # Alternative: backup specific database only (uncomment if needed)
    # pg_back -b "$backup_full_path" -j "$PARALLEL_JOBS" -J 2 -Z0 -F directory "$DB_NAME"
}

_tar_backup() {
    local backup_full_path="${BACKUP_PATH}/${BACKUP_DIR}"
    local tar_file="${backup_full_path}.tar.gz"
    
    _start_tar_msg
    
    if [[ ! -d "$backup_full_path" ]]; then
        _log_error "Backup directory does not exist: $backup_full_path"
        return 1
    fi
    
    _log_info "Compressing backup to: $tar_file"
    
    # Change to parent directory to avoid full path in tar
    if ! cd "$(dirname "$backup_full_path")"; then
        _log_error "Failed to change to backup directory"
        return 1
    fi
    
    # Create compressed tar with error handling
    if tar -cf - "$(basename "$backup_full_path")" | pigz -p "$COMPRESSION_THREADS" > "$tar_file"; then
        _log_info "Compression completed successfully"
        
        # Verify tar file was created and has content
        if [[ -s "$tar_file" ]]; then
            _log_info "Removing uncompressed backup directory to save space"
            rm -rf "$backup_full_path"
            _end_tar_msg
            return 0
        else
            _log_error "Compressed file is empty or was not created properly"
            return 1
        fi
    else
        _log_error "Compression failed"
        return 1
    fi
}

_pg_cleanup() {
    if [[ -z "$BACKUP_PATH" ]]; then
        _log_error "BACKUP_PATH is not set"
        return 1
    fi
    
    _log_info "Cleaning up backups older than $RETENTION_DAYS days"
    
    if ! cd "$BACKUP_PATH"; then
        _log_error "Failed to change to backup directory: $BACKUP_PATH"
        return 1
    fi
    
    # Find and remove old backups with logging
    local old_backups
    old_backups=$(find "$BACKUP_PATH" -maxdepth 1 -name "${DB_NAME}-*" -mtime +$RETENTION_DAYS -type f -o -type d)
    
    if [[ -n "$old_backups" ]]; then
        _log_info "Removing old backups:"
        echo "$old_backups" | while read -r backup; do
            _log_info "  Removing: $backup"
            rm -rf "$backup"
        done
    else
        _log_info "No old backups found to clean up"
    fi
}

############## Main Function ##############################
main() {
    # Validate arguments
    if [[ $# -eq 0 ]]; then
        _log_error "Usage: $SCRIPT_NAME <database_name>"
        _log_info "Example: $SCRIPT_NAME MyDatabase"
        exit 1
    fi
    
    _log_info "Starting $SCRIPT_NAME for database: $DB_NAME"
    
    # Run all validations first
    _check_user || exit 1
    _check_prereq || exit 1
    _check_backup_dir || exit 1
    
    # Start backup process
    _start_msg
    
    # Execute backup steps
    if _backup_db && _tar_backup; then
        _end_msg
        _log_info "Backup completed successfully"
        
        # Optional cleanup (uncomment if desired)
        # _pg_cleanup
        
        exit 0
    else
        _log_error "Backup process failed"
        exit 1
    fi
}

# Run main function
main "$@"
