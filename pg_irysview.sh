#!/bin/bash
#########################################################
#                                                       #
#       pg_backup wrapper script for BAS hosts          #
#	Please test backups and recoveries!!		#
#       Prerequisites                                   #
#          1. Must be run as the postgres user          #
#          2. pg_backup and pigz installed              #
#          3. backup directory path exists              #
#          4. Change DbName and BackupDir               #
#             as needed                                 #
#                                                       #
#########################################################

#######################pg_back is available for download at #####################################
#     https://github.com/orgrim/pg_back/releases/download/v2.4.0/pg-back-2.4.0-x86_64.rpm	#
#################################################################################################
#VariableName
#_function_name

############Change to suite your environment#######################
DbName=IrysView_Dev

# It is strongly recommend the path below is located on an nfs
# mount point

BackupPath=/mnt/$(hostname -s)/pgdump 


BackupDir=${DbName}-$(date --iso-8601)

###################################################################
_check_prereq () {
if [[ -f $(which pg_back) && -f $(which pigz) ]]; then
	return 0
else
	return 1
fi
}


_start_msg() {
cat << EOM
        +-------------------------------------------------------+
                  Backing up ${DbName} on $(hostname -s)
        +-------------------------------------------------------+

EOM
}

_end_msg() {
cat << EOM

        +---------------------------------------------------------------+
                Finished backing up ${DbName} on $(hostname -s)
        +---------------------------------------------------------------+

EOM
}


_start_tar_msg() {
cat << EOM

        +-------------------------------------------------------------------------------+
                starting tar ${BackupDir}
        +-------------------------------------------------------------------------------+

EOM
}

_end_tar_msg() {
cat << EOM

        +-------------------------------------------------------------------------------+
                end tar ${BackupDir}
        +-------------------------------------------------------------------------------+

EOM
}

_backup_db () {
        #pg_back -b "${BackupPath}"/"${BackupDir}" -j 10 -J 2 -Z0 -F directory ${DbName} && \
        pg_back -b "${BackupPath}"/"${BackupDir}" -j 10 -J 2 -Z0 -F directory && \
        _end_msg
        return 0
}

# Function to tar and compress directory using tar and pigz, and remove directory
# after tar.gz file has been created

_tar_backup () {
        _start_tar_msg
        if [ -d "${BackupPath}"/"${BackupDir}" ];
        then
                tar -cf - "${BackupPath}"/"${BackupDir}" | pigz -p 10 > "${BackupPath}"/"${BackupDir}".tar.gz && \
                echo "removing backup directory to save space..."
                find "${BackupPath}" -maxdepth 1 -type d -a -name "${BackupDir}" -exec rm -rf "{}" \; && \
                _end_tar_msg
                return 0
        else
                echo "${BackupDir} does not exist}"
                return 1
        fi
}

_pg_cleanup () {
# clean up files and directories older than 30 days
     find ${BackupPath} -maxdepth 1 -name ${DbName}-* -mtime +90 -exec rm -rf "{}" \;
}

#_check_prereq && \
_start_msg		#start backup message
_backup_db && \
_tar_backup
#_pg_cleanup
