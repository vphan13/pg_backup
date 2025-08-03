Written by Vinh Phan  
Updated: August 2025

# PostgreSQL Backup using Systemd Timers

This script is a robust wrapper around the `pg_back` package that enables multi-threaded directory backups of PostgreSQL databases. It provides compressed backups with comprehensive error handling and is designed specifically for systemd environments.

## Features

- **Multi-threaded backups** for faster performance using `pg_back`
- **Automatic compression** with `pigz` for space efficiency
- **Template service support** using systemd `%i` instance naming
- **Comprehensive error handling** with automatic cleanup on failure
- **Systemd-native logging** compatible with `journalctl`
- **Configurable retention** and parallel processing
- **Signal handling** for graceful interruption
- **Disk space monitoring** with low space warnings

## Prerequisites

### System Requirements
- **RHEL/RPM-based systems** (tested) or Debian-based systems (untested but should work)
- **PostgreSQL** server running
- **Network storage** recommended (NFS mount point for backup destination)

### Required Packages

#### RHEL/CentOS/Rocky Linux
```bash
# Install pigz for parallel compression
yum install pigz -y

# Install pg_back package
yum install https://github.com/orgrim/pg_back/releases/download/v2.4.0/pg-back-2.4.0-x86_64.rpm
```

#### Debian/Ubuntu
```bash
# Install pigz
apt-get install pigz

# Install pg_back
wget https://github.com/orgrim/pg_back/releases/download/v2.5.0/pg-back_2.5.0_linux_amd64.deb
dpkg -i pg-back_2.5.0_linux_amd64.deb
```

### User Requirements
- Script **must be run as the `postgres` user**
- Backup destination directory must be **writable by postgres user**

## Installation

1. **Copy the script** to the PostgreSQL home directory:
   ```bash
   cp pgBackup.sh /var/lib/pgsql/
   chmod +x /var/lib/pgsql/pgBackup.sh
   ```

2. **Set up backup destination** (strongly recommended to use NFS):
   ```bash
   # Ensure backup directory exists and is accessible
   mkdir -p /mnt/$(hostname -s)/pgdump
   chown postgres:postgres /mnt/$(hostname -s)/pgdump
   ```

3. **Install systemd service files**:
   ```bash
   cp pgBackup@.service pgBackup.timer /etc/systemd/system/
   systemctl daemon-reload
   ```

## Configuration

The script uses environment variables and command-line arguments for configuration:

### Environment Variables
- `BACKUP_PATH` - Backup destination directory (default: `/mnt/$(hostname -s)/pgdump`)
- `RETENTION_DAYS` - Days to keep old backups (default: `90`)
- `PARALLEL_JOBS` - pg_back parallel jobs (default: `10`)
- `COMPRESSION_THREADS` - pigz compression threads (default: `10`)

### Command Line Usage
```bash
# Basic usage - database name is required
./pgBackup.sh <database_name>

# Examples
./pgBackup.sh MyAppDB
./pgBackup.sh CustomerDatabase
./pgBackup.sh LoggingDB
```

## Usage

### Manual Execution

1. **Switch to postgres user**:
   ```bash
   sudo -u postgres -i
   ```

2. **Run backup for specific database**:
   ```bash
   cd /var/lib/pgsql
   ./pgBackup.sh MyDatabase
   ```

3. **With custom configuration**:
   ```bash
   RETENTION_DAYS=30 PARALLEL_JOBS=8 ./pgBackup.sh MyDatabase
   ```

### Systemd Service (Recommended)

#### Single Database Backup
```bash
# Enable and start backup service for a specific database
systemctl enable pg-backup@MyDatabase.service
systemctl start pg-backup@MyDatabase.service

# Check status and logs
systemctl status pg-backup@MyDatabase.service
journalctl -u pg-backup@MyDatabase.service
```

#### Multiple Database Backups
```bash
# Enable services for multiple databases
systemctl enable pg-backup@AppDB.service
systemctl enable pg-backup@UserDB.service
systemctl enable pg-backup@LogDB.service

# Start all at once
systemctl start pg-backup@AppDB.service pg-backup@UserDB.service pg-backup@LogDB.service
```

#### Scheduled Backups with Timers
```bash
# Enable daily scheduled backups
systemctl enable pg-backup@MyDatabase.timer

# Check timer status
systemctl list-timers pg-backup@*

# View timer logs
journalctl -u pg-backup@MyDatabase.timer
```

#### Custom Timer Schedule
Edit `/etc/systemd/system/pgBackup.timer` to modify the schedule:
```ini
[Timer]
# Weekly on Saturday at 2 AM Pacific Time
OnCalendar=Sat *-*-* 02:00:00 America/Los_Angeles

# Daily at 3 AM UTC
# OnCalendar=daily
# OnCalendar=*-*-* 03:00:00

# Every 6 hours
# OnCalendar=*-*-* 00/6:00:00
```

## Backup Process

The script performs the following steps:

1. **Validation Phase**:
   - Verify running as postgres user
   - Check required commands are available
   - Validate backup directory exists and is writable
   - Check available disk space (warns if < 10GB)

2. **Backup Phase**:
   - Create timestamped backup directory (`DatabaseName-YYYY-MM-DD`)
   - Run `pg_back` with directory format for fast parallel backup
   - Log progress and handle errors

3. **Compression Phase**:
   - Compress backup directory using `tar` and `pigz`
   - Verify compressed file integrity
   - Remove uncompressed directory to save space

4. **Cleanup Phase** (optional):
   - Remove backups older than retention period
   - Log cleanup operations

## Backup Output

Backups are stored as compressed tar files with the naming convention:
```
/mnt/hostname/pgdump/DatabaseName-YYYY-MM-DD.tar.gz
```

Example:
```
/mnt/db01/pgdump/MyAppDB-2025-08-03.tar.gz
/mnt/db01/pgdump/UserDB-2025-08-03.tar.gz
```

## Monitoring and Logging

### View Logs
```bash
# View all logs for a specific database backup
journalctl -u pg-backup@MyDatabase.service

# Follow logs in real-time
journalctl -u pg-backup@MyDatabase.service -f

# Show only errors
journalctl -u pg-backup@MyDatabase.service -p err

# Show logs from last 24 hours
journalctl -u pg-backup@MyDatabase.service --since "24 hours ago"

# Show logs for all backup services
journalctl -u pg-backup@*.service
```

### Log Levels
The script uses structured logging with the following levels:
- `[INFO]` - Normal operation messages
- `[WARN]` - Warning conditions (low disk space, etc.)
- `[ERROR]` - Error conditions that prevent backup completion

## Recovery

To restore from a backup:

1. **Extract the backup**:
   ```bash
   cd /tmp
   tar -xzf /mnt/hostname/pgdump/DatabaseName-YYYY-MM-DD.tar.gz
   ```

2. **Use pg_back's restore capabilities** or standard PostgreSQL tools to restore individual databases or the entire cluster.

## Troubleshooting

### Common Issues

1. **Permission Denied**:
   - Ensure script runs as postgres user
   - Check backup directory permissions

2. **Command Not Found**:
   - Install missing packages (`pigz`, `pg_back`)
   - Check PATH includes necessary binaries

3. **Disk Space Issues**:
   - Monitor available space in backup directory
   - Adjust retention period or cleanup old backups

4. **Service Won't Start**:
   - Check systemd service file paths
   - Verify script is executable
   - Check journalctl for detailed error messages

### Debug Mode
Run manually with verbose output:
```bash
sudo -u postgres /var/lib/pgsql/pgBackup.sh MyDatabase
```

## References

- [systemd/Timers](https://wiki.archlinux.org/index.php/Systemd/Timers#Realtime_timer)
- [How to use Systemd timers](https://www.certdepot.net/rhel7-use-systemd-timers/)
- [Use systemd timers instead of cronjobs](https://opensource.com/article/20/7/systemd-timers)
- [pg_back documentation](https://github.com/orgrim/pg_back)
- [PostgreSQL Backup and Restore](https://www.postgresql.org/docs/current/backup.html)
