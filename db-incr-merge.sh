#!/bin/bash
#
SCRIPTLOC=$(cd $(dirname $0) && pwd)
source $SCRIPTLOC/lib/libcommon.sh
[ ! -d $SCRIPTLOC/log ] && mkdir $SCRIPTLOC/log
PRINT_USAGE="Usage: $0 -s SID -d /backup/dir -t tag"
LOGFILE=$SCRIPTLOC/log/sql.trc
BACKUP_DIR=""
archBackupScript=""
dbBackupScript=""
SID_ARG=""
NOLOG=0
KEEPSCR=0

while getopts "s:t:d:ok" opt
do
  case $opt in
    s)
      SID_ARG=$OPTARG
      ;;
    d)
      BACKUP_DIR=$OPTARG
      ;;
    t)
      BACKUP_TAG=$OPTARG
      ;;
    o)
      NOLOG=1
      ;;
    k)
      KEEPSCR=1
      ;;
    \?)
      err_exit
      ;;
  esac
done

if [ -z "$SID_ARG" -o -z "$BACKUP_DIR" ]; then
  print_usage
  err_exit "SID and backup directory arguments are required."
fi

export ORACLE_SID=${SID_ARG}

[ -z "$BACKUP_TAG" ] && BACKUP_TAG=incrmrg_$ORACLE_SID

[ ! -d "$BACKUP_DIR/archivelog" ] && mkdir $BACKUP_DIR/archivelog

echo "Begin incremental merge backup." 2>&1 | log_output

echo "Creating database configuration file." 2>&1 | log_output
DBCONFIG=$(db_config -q -d $BACKUP_DIR -s $ORACLE_SID)
[ $? -ne 0 ] && err_exit "Can not create DB config file."

echo "Checking database archive log status." 2>&1 | log_output
config_query -f $DBCONFIG archivemode
[ $? -ne 0 ] && err_exit "Database is not in archive log mode."

dbversion=$(config_query -f $DBCONFIG dbversion)
[ $? -ne 0 ] && err_exit "Can not get database version"

dbBackupScript=$(mktemp)
rman_script -s $ORACLE_SID -t $BACKUP_TAG -d $BACKUP_DIR -b > $dbBackupScript
[ $? -ne 0 -o ! -s "$dbBackupScript" ] && err_exit "Can not create backup script"

echo "Beginning incremental backup $BACKUP_TAG on database $ORACLE_SID" 2>&1 | log_output
rman <<EOF 2>&1 | log_output
connect target /
@$dbBackupScript
EOF

if [ $? -ne 0 ]
then
   echo "Backup for $ORACLE_SID failed." 2>&1 | log_output
   err_exit "Backup for $ORACLE_SID failed. See $LOGFILE for more information."
else
   echo "Backup Phase Done." 2>&1 | log_output
fi

archBackupScript=$(mktemp)
rman_script -s $ORACLE_SID -t $BACKUP_TAG -d $BACKUP_DIR -a > $archBackupScript
[ $? -ne 0 -o ! -s "$archBackupScript" ] && err_exit "Can not create archive log script."

echo "Beginning archive log backup $BACKUP_TAG on database $ORACLE_SID" 2>&1 | log_output
[ ! -z "$BACKUP_DIR" ] && rm -f $BACKUP_DIR/archivelog/* > /dev/null 2>&1
rman <<EOF 2>&1 | log_output
connect target /
@$archBackupScript
EOF

if [ $? -ne 0 ]
then
   echo "Archive log backup for $ORACLE_SID failed." 2>&1 | log_output
   err_exit "Backup for $ORACLE_SID failed. See $LOGFILE for more information."
else
   echo "Archivelog Backup Done." 2>&1 | log_output
fi

echo "End Backup." 2>&1 | log_output

[ "$KEEPSCR" -eq 0 ] && rm $dbBackupScript
[ "$KEEPSCR" -eq 0 ] && rm $archBackupScript
exit 0
##
