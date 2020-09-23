#!/bin/sh
#
SCRIPTLOC=$(cd $(dirname $0) && pwd)
[ ! -d $SCRIPTLOC/log ] && mkdir $SCRIPTLOC/log
LOGFILE=$SCRIPTLOC/log/sql.trc
BACKUP_DIR=""
NO_CATALOG=0
CHECK=0
END=0
BEGIN=0
OPSET=0
archBackupScript=""
dbBackupScript=""

function err_exit {
   if [ -n "$1" ]; then
      echo "$1"
   else
      echo "Usage: $0 -s ORACLE_SID -d /backup/dir [ -t backup_tag | -n ]"
   fi
   exit 1
}

function createArchLogScript {

if [ ! -d "$BACKUP_DIR" ]; then
   return 1
fi

archBackupScript=$(mktemp)

cat <<EOF > $archBackupScript
run
{
ALLOCATE CHANNEL CH01 DEVICE TYPE DISK FORMAT '$BACKUP_DIR/archivelog/%U' ;
SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
EOF

logSeqNum=`sqlplus -S / as sysdba <<EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   SELECT THREAD#, SEQUENCE# FROM V\\$LOG WHERE STATUS = 'CURRENT' OR STATUS = 'CLEARING_CURRENT' UNION
   SELECT THREAD#, MAX(SEQUENCE#) FROM V\\$LOG WHERE STATUS = 'INACTIVE' AND THREAD# NOT IN
   (SELECT THREAD# FROM V\\$LOG WHERE STATUS = 'CURRENT' OR STATUS = 'CLEARING_CURRENT') GROUP BY THREAD#
   ORDER BY THREAD#, SEQUENCE#;
EOF`

[ $? -ne 0 ] && return 1

dataArray=($logSeqNum)
for ((i=0; i<${#dataArray[@]}; i=i+2)); do
    threadNum=${dataArray[i]}
    untilSeqNum=${dataArray[i+1]}
    fromSeqNum=$(($untilSeqNum-1))
cat <<EOF >> $archBackupScript
BACKUP AS COPY ARCHIVELOG FROM SEQUENCE $fromSeqNum UNTIL SEQUENCE $untilSeqNum THREAD $threadNum ;
EOF
done

if [ "$NO_CATALOG" -eq 1 ]; then

cat <<EOF >> $archBackupScript
CHANGE COPY OF ARCHIVELOG LIKE '$BACKUP_DIR/archivelog/%' UNCATALOG ;
EOF

fi

cat <<EOF >> $archBackupScript
}
EOF

return 0
}

function createBackupScript {

if [ ! -d "$BACKUP_DIR" ]; then
   return 1
fi

if [ -z "$ORACLE_SID" ]; then
   echo "Error: ORACLE_SID not set."
   exit 1
fi

dbBackupScript=$(mktemp)

cat <<EOF > $dbBackupScript
run
{
set nocfau;
ALLOCATE CHANNEL CH01 DEVICE TYPE DISK FORMAT '$BACKUP_DIR/%U';
ALLOCATE CHANNEL CH02 DEVICE TYPE DISK FORMAT '$BACKUP_DIR/%U';
ALLOCATE CHANNEL CH03 DEVICE TYPE DISK FORMAT '$BACKUP_DIR/%U';
ALLOCATE CHANNEL CH04 DEVICE TYPE DISK FORMAT '$BACKUP_DIR/%U';

EOF

##if [ -f "$BACKUP_DIR/control01.ctl" ]; then

cat <<EOF >> $dbBackupScript

CROSSCHECK COPY TAG '$BACKUP_TAG' ;
CROSSCHECK BACKUP TAG '$BACKUP_TAG' ;

EOF

for dataFileName in $(ls $BACKUP_DIR/data* 2>/dev/null)
do
cat <<EOF >> $dbBackupScript
CATALOG DATAFILECOPY '$dataFileName' LEVEL 0 ;
EOF
done

for archFileName in $(ls $BACKUP_DIR/archivelog/arch* 2>/dev/null)
do
cat <<EOF >> $dbBackupScript
CATALOG ARCHIVELOG '$archFileName' ;
EOF
done

for cntlFileName in $(ls $BACKUP_DIR/control* 2>/dev/null)
do
cat <<EOF >> $dbBackupScript
CATALOG CONTROLFILECOPY '$cntlFileName' ;
EOF
done

cat <<EOF >> $dbBackupScript

BACKUP INCREMENTAL LEVEL 1 FOR RECOVER OF COPY WITH TAG '$BACKUP_TAG' DATABASE;
RECOVER COPY OF DATABASE WITH TAG '$BACKUP_TAG';
BACKUP AS COPY CURRENT CONTROLFILE TAG '$BACKUP_TAG' FORMAT '$BACKUP_DIR/control01.ctl' REUSE ;
DELETE NOPROMPT BACKUPSET TAG '$BACKUP_TAG';

EOF

if [ "$NO_CATALOG" -eq 1 ]; then

cat <<EOF >> $dbBackupScript
CHANGE COPY OF DATABASE TAG '$BACKUP_TAG' UNCATALOG ;
CHANGE COPY OF CONTROLFILE TAG '$BACKUP_TAG' UNCATALOG ;
EOF

fi

cat <<EOF >> $dbBackupScript
}
EOF

##else

##fi

return 0
}

if [ -z "$(which stat)" ]; then
   echo "This script requires the stat utility."
   exit 1
fi

while getopts "s:t:d:n" opt
do
  case $opt in
    n)
      NO_CATALOG=1
      ;;
    s)
      export ORACLE_SID=$OPTARG
      OPSET=$(($OPSET+1))
      ;;
    d)
      BACKUP_DIR=$OPTARG
      OPSET=$(($OPSET+1))
      ;;
    t)
      BACKUP_TAG=$OPTARG
      ;;
    \?)
      err_exit
      ;;
  esac
done

ORAENV_ASK=NO
source oraenv

if [ "$(stat -t -c '%u' /etc/oratab)" != "$(id -u)" ]; then
   echo "This script shoud be run as the oracle user."
   exit 1
fi

if [ "$OPSET" -ne 2 ]; then
   echo "Usage: $0 -s ORACLE_SID -f | -t | -c"
   exit 1
fi

if [ ! -d "$BACKUP_DIR" ];then
   echo "Backup directory $BACKUP_DIR does not exist."
   exit 1
fi

if [ -z "$ORACLE_SID" -a -z "$(which sqlplus)" ]; then
   echo "Environment not properly set."
   exit 1
fi

[ -z "$BACKUP_TAG" ] && BACKUP_TAG=incrmrg_$ORACLE_SID

[ ! -d "$BACKUP_DIR/archivelog" ] && mkdir $BACKUP_DIR/archivelog

DATE=$(date '+%m%d%y-%H%M%S')
echo "$DATE: Begin incremental merge backup." >> $LOGFILE 2>&1

createArchLogScript || err_exit
createBackupScript || err_exit

echo -n "Beginning incremental backup $BACKUP_TAG on database $ORACLE_SID ..."
rman <<EOF >> $LOGFILE 2>&1
connect target /
@$dbBackupScript
EOF

if [ $? -ne 0 ]
then
   echo "Backup for $ORACLE_SID failed. See $LOGFILE for more information."
   exit 1
else
   echo "Done."
fi

echo -n "Beginning archive log backup $BACKUP_TAG on database $ORACLE_SID ..."
rman <<EOF >> $LOGFILE 2>&1
connect target /
@$archBackupScript
EOF

if [ $? -ne 0 ]
then
   echo "Backup for $ORACLE_SID failed. See $LOGFILE for more information."
   exit 1
else
   echo "Done."
fi

echo -n "Writing database configuration file ..."
$SCRIPTLOC/createConfigFile.sh -s $ORACLE_SID -d $BACKUP_DIR >> $LOGFILE 2>&1

if [ $? -ne 0 ]
then
   echo "Saving configuration for $ORACLE_SID failed. See $LOGFILE for more information."
   exit 1
else
   echo "Done."
fi

DATE=$(date '+%m%d%y-%H%M%S')
echo "$DATE: End Backup." >> $LOGFILE 2>&1

exit 0
##
