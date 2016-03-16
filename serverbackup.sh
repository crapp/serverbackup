#!/bin/bash

# Simple bash script to perform server backups
# Copyright (C) 2015, 2016 Christian Rapp

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


# Make sure we run with bash
if [ -z "$BASH_VERSION" ]
then
  echo "Restarting script with bash interpreter"
  exec bash "$0" "$@"
fi

#####
# Script Parameters:
#
# First Parameter is the remote backup directory.
BACKUPDIR=$1
# Second parameter is the local backup directory.
BACKUPLOCALDIR=$2
# Create a backup of installed packages? 1 Yes 0 No
# Currently only dpkg supported, but you can change that easily yourself
BACKUPPKGLIST=$3
# GPG User to encrypt the data for. The public key must have been imported to the
# users keyring which runs this script
GPG_USER=$4
#####

# Absolute path to this script, e.g. /home/user/bin/foo.sh
SCRIPT=$(readlink -f "$0")
# Absolute path this script is in, thus /home/user/bin
SCRIPTPATH=$(dirname "$SCRIPT")

#get current date and write to var
curDate=$(date +"%Y-%m-%d")

#get start time from epoche
startTime=$(date +%s)

retValTar=0

printStatus () {
  if [ $1 -eq 0 ] && [ $2 -eq 0 ] && [ $3 -eq 0 ]
  then
    echo " OK"
  else
    echo " FAILED (1 = $1; 2 = $2; 3 = $3)"
  fi
}

##
# @brief Print messages to stdout
# @param $1 echo parameter
# @param $2 message
##
printMessage() {
  if [ $# -eq 2 ]
  then
    echoVar="$1"
    msg="$2"
  else
    echoVar=""
    msg="$1"
  fi
  echo $echoVar "$(date +'%Y-%m-%d %H:%M:%S'): $msg"
}


##
# @brief Encrypt file with gnupg
# @param $1 file to encrypt
##
encryptFile() {
  # TODO: Add support for keys with password
  # Encrypt file $1 for User $GPG_USER using a gpg key without password. Use
  # trust-model always with care. Better to actually sign the key.
  gpg --batch --yes --trust-model always -e -r "$GPG_USER" "$1"
}



##
# @brief Remove backup files no longer required
# @param $1 PackageList (2), Database (1) or folder (0)
# @param $2 Folder or Database name
# @param $3 Maximum days
##
removeOldBackups() {
  if [ $1 == 2 ]
  then
    findDirName="${BACKUPDIR}/packageList"
    findPattern="packageList_*.list.gpg"
  fi
  if [ $1 == 1 ]
  then
    findDirName="${BACKUPDIR}/db"
    findPattern="*_db_${2}_*.sql.gz.gpg"
  fi
  if [ $1 == 0 ]
  then
    folderName=$(basename "$2")
    findDirName="${BACKUPDIR}/${folderName}"
    findPattern="${folderName}_backup_*.tar.gz.gpg"
  fi
  printMessage "-n" "Searching in folder: $findDirName for this pattern ${findPattern}. "
  printMessage "Will delete all files older than $3 days."
  find "$findDirName" -name "$findPattern" -mtime +${3} -exec rm -vf {} \;
}

##
# @brief Create a tar/gzip archiv from provided directory
# @param $1 Directory to tar
# @param $2 Directories or Files to exclude as a comma separated string
##
createTarbackup()
{
  printMessage "Creating backup of $1"

  folderToBackup=$(basename "$1")
  backupfile="${BACKUPLOCALDIR}/${folderToBackup}/${folderToBackup}_backup.tar.gz"

  # create directories if missing
  mkdir -vp "${BACKUPDIR}/${folderToBackup}" "${BACKUPLOCALDIR}/${folderToBackup}"

  use_ionice=false
  ionice_class=""
  ionice_level=""

  if [ "$3" != "" ]
  then
    IFS=',' read -ra ioniceArray <<< "$3"
    if [ "${ioniceArray[0]}" == "1" ]
    then
      use_ionice=true
      ionice_class=${ioniceArray[1]}
      ionice_level=${ioniceArray[2]}
    fi
  fi

  if [ "$2" != "" ]
  then
    excludeOption=""
    IFS=',' read -ra excludesArray <<< "$2"
    for exclude in "${excludesArray[@]}"
    do
      if [ "$excludeOption" != "" ]
      then
        excludeOption+=" --exclude=${exclude}"
      else
        excludeOption+="--exclude=${exclude}"
      fi
    done
    printMessage "Tar excludes: ${excludeOption}"
    if [ $use_ionice = true ]
    then
      ionice -c$ionice_class -n$ionice_level tar czpf "$backupfile" $excludeOption -C "$1" .
    else
      tar czpf "$backupfile" $excludeOption -C "$1" .
    fi
  else
    if [ $use_ionice = true ]
    then
      ionice -c$ionice_class -n$ionice_level tar czpf "$backupfile" -C "$1" .
    else
      tar czpf "$backupfile" -C "$1" .
    fi
  fi
  # save return value of tar command
  retValTar=$?

  # encrypt the archive
  encryptFile $backupfile

  # copy encrypted archive to backup folder
  cp -vf "${backupfile}.gpg" "${BACKUPDIR}/${folderToBackup}/${folderToBackup}_backup_${curDate}.tar.gz.gpg"
  retValCp=$?

  # delete local backup
  rm -vf "$backupfile" "${backupfile}.gpg"

  printMessage "-n" "Backup status: "
  printStatus $retValTar $retValCp $?
}

##
# @brief Make a database dump, gzip the resulting file and encrypt it with gpg
# @param $1 Database name
# @param $2 DBMS (mysql|postgres)
# @param $3 Connection parameters (comma separated string. do not use passwords
# with commas :). username,password,port,host)
##
backupDatabase() {
  # create directories if missing
  mkdir -vp "${BACKUPDIR}/db" "${BACKUPLOCALDIR}/db"

  # get connection params
  IFS="," read username password port host <<< "$3"

  if [ "$2" == "mysql" ]
  then
    dbLocalFile="${BACKUPLOCALDIR}/${2}_db_${1}_${curDate}.sql.gz"
    printMessage "Dumping mysql Database $1. Connection Parameters: $username $port $host"
    mysqldump -u "$username" -p${password} -P $port -h "$host"  "$1" | gzip > "$dbLocalFile"
  fi
  if [ "$2" == "postgres" ]
  then
    dbLocalFile="${BACKUPLOCALDIR}/${2}_db_${1}_${curDate}.sql.gz"
    printMessage "Dumping postgres Database $1. Connection Parameters: $username $port $host"
    PGPASSWORD="$password" pg_dump -p $port -h "$host" -U "$username" "$1" | gzip > "$dbLocalFile"
  fi

  encryptFile "$dbLocalFile"

  cp -vf "${dbLocalFile}.gpg" "${BACKUPDIR}/db"
  rm -vf "$dbLocalFile" "${dbLocalFile}.gpg"
}

##
# @brief Get installed packages and save them to file
##
backupPackageList() {
  # create directories if missing
  mkdir -vp "${BACKUPDIR}/packageList" "${BACKUPLOCALDIR}/packageList"

  packageListFile="${BACKUPLOCALDIR}/packageList_${curDate}.list"

  printMessage "Creating backup of all installed packages with dpkg command"

  dpkg --get-selections > "$packageListFile"

  encryptFile "$packageListFile"

  cp -vf "${packageListFile}.gpg" "${BACKUPDIR}/packageList"
  rm -vf "${packageListFile}" "${packageListFile}.gpg"
}

printMessage "-e" "\nStarting server backup"

# read directories from file. semicolon is the separator
while IFS=';' read bfolder excludes days ionice
do
  if [ "$bfolder" == "" ] || [[ "$bfolder" == "#"*  ]]
  then
    continue
  fi

  printMessage "-e" "Backup Folder: $bfolder \n\
    Excludes: $excludes \n\
    Days max: $days \n"

  createTarbackup $bfolder $excludes $ionice
  if [ "$days" != "" ] && [[ "$days" > 0 ]]
  then
    removeOldBackups 0 $bfolder $days
  fi

done < $SCRIPTPATH/backupDirectories

# read databases to backup from file.
while IFS=';' read dbname dbms connparams days
do
  if [ "$dbname" == "" ] || [[ "$dbname" == "#"*  ]]
  then
    continue
  fi

  printMessage "-e" "Backup Database: $dbname \n\
    DBMS: $dbms \n\
    Days max: $days \n"

  backupDatabase $dbname $dbms $connparams

  if [ "$days" != "" ] && [[ "$days" > 0 ]]
  then
    removeOldBackups 1 $dbname $days
  fi
done < $SCRIPTPATH/backupDatabases

# create list of installed packages
if [ $BACKUPPKGLIST == 1 ]
then
  backupPackageList
  # TODO Hard coded number of days
  removeOldBackups 2 "" 30
fi

endTime=$(date +%s)
diff=$(($endTime - $startTime))

printMessage "Backup finished in $diff seconds"

exit 0

