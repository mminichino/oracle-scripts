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

function getDbVersion {
dbversion=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select version from v\\$instance ;
   exit;
EOF`

[ $? -ne 0 ] && return 1

dbMajorRev=$(echo $dbversion | sed -n -e 's/^\([0-9]*\)\..*$/\1/p')
}

function createArchLogScript {

if [ ! -d "$BACKUP_DIR" ]; then
   return 1
fi

archiveLogFormat='%U'
archBackupScript=$(mktemp)

cat <<EOF > $archBackupScript
run
{
ALLOCATE CHANNEL CH01 DEVICE TYPE DISK FORMAT '$BACKUP_DIR/archivelog/$archiveLogFormat' ;
EOF

logSeqNum=`sqlplus -S / as sysdba <<EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select thread#, sequence# from v\\$log where status = 'current' or status = 'clearing_current' union
   select thread#, max(sequence#) from v\\$log where status = 'inactive' and thread# not in
   (select thread# from v\\$log where status = 'current' or status = 'clearing_current') group by thread#
   order by thread#, sequence#;
EOF`

[ $? -ne 0 ] && return 1

dataArray=($logSeqNum)
for ((i=0; i<${#dataArray[@]}; i=i+2)); do
    threadNum=${dataArray[i]}
    untilSeqNum=${dataArray[i+1]}
    fromSeqNum=$(($untilSeqNum-1))

if [ "$dbMajorRev" -gt 11 ]; then

untilArchLogSeqName=`sqlplus -S / as sysdba <<EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   alter system archive log current ;
   select name from v\\$archived_log where sequence# = $untilSeqNum ;
EOF`
fromArchLogSeqName=`sqlplus -S / as sysdba <<EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\\$archived_log where sequence# = $fromSeqNum ;
EOF`
untilArchLogSeqName=$(basename $untilArchLogSeqName)
fromArchLogSeqName=$(basename $fromArchLogSeqName)
cat <<EOF >> $archBackupScript
BACKUP AS COPY ARCHIVELOG SEQUENCE $fromSeqNum THREAD $threadNum FORMAT '$BACKUP_DIR/archivelog/$fromArchLogSeqName';
BACKUP AS COPY ARCHIVELOG SEQUENCE $untilSeqNum THREAD $threadNum FORMAT '$BACKUP_DIR/archivelog/$untilArchLogSeqName';
EOF

else

cat <<EOF >> $archBackupScript
BACKUP AS COPY ARCHIVELOG FROM SEQUENCE $fromSeqNum UNTIL SEQUENCE $untilSeqNum THREAD $threadNum ;
EOF

fi

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

if [ "$dbMajorRev" -gt 11 ]; then

pdbNames=`sqlplus -S / as sysdba <<EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select lower(name) from v\\$containers where con_id <> 1 ;
EOF`

pdbArray=($pdbNames)

else

pdbArray=()

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

if [ "$dbMajorRev" -gt 11 ]; then
for ((i=0; i<${#pdbArray[@]}; i=i+1)); do
pdbName=$(echo ${pdbArray[$i]} | sed -e 's/\$//g')
cat <<EOF >> $dbBackupScript
ALLOCATE CHANNEL $pdbName DEVICE TYPE DISK FORMAT '$BACKUP_DIR/$pdbName/%U';
EOF
done
fi

cat <<EOF >> $dbBackupScript

CROSSCHECK COPY TAG '$BACKUP_TAG' ;
CROSSCHECK BACKUP TAG '$BACKUP_TAG' ;

EOF

for dataFileName in $(ls $BACKUP_DIR/data_* 2>/dev/null)
do
cat <<EOF >> $dbBackupScript
CATALOG DATAFILECOPY '$dataFileName' LEVEL 0 ;
EOF
done

if [ "${#pdbArray[@]}" -gt 0 ]; then

for ((i=0; i<${#pdbArray[@]}; i=i+1)); do
pdbName=$(echo ${pdbArray[$i]} | sed -e 's/\$//g')

if [ -d "$BACKUP_DIR/$pdbName" ]; then
for dataFileName in $(ls $BACKUP_DIR/$pdbName/data_* 2>/dev/null)
do
cat <<EOF >> $dbBackupScript
CATALOG DATAFILECOPY '$dataFileName' LEVEL 0 ;
EOF
done

else
   mkdir $BACKUP_DIR/$pdbName
fi

done # pdbArray loop

fi # pdb loop

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

if [ "$dbMajorRev" -gt 11 ]; then

cat <<EOF >> $dbBackupScript

BACKUP INCREMENTAL LEVEL 1 FOR RECOVER OF COPY WITH TAG '$BACKUP_TAG' DATABASE ROOT;
EOF

for ((i=0; i<${#pdbArray[@]}; i=i+1)); do
pdbName=$(echo ${pdbArray[$i]} | sed -e 's/\$//g')
cat <<EOF >> $dbBackupScript
BACKUP CHANNEL '$pdbName' INCREMENTAL LEVEL 1 FOR RECOVER OF COPY WITH TAG '$BACKUP_TAG' PLUGGABLE DATABASE '${pdbArray[$i]}';
EOF
done

cat <<EOF >> $dbBackupScript
RECOVER COPY OF DATABASE ROOT WITH TAG '$BACKUP_TAG';
EOF

for ((i=0; i<${#pdbArray[@]}; i=i+1)); do
cat <<EOF >> $dbBackupScript
RECOVER COPY OF PLUGGABLE DATABASE '${pdbArray[$i]}' WITH TAG '$BACKUP_TAG';
EOF
done

cat <<EOF >> $dbBackupScript
BACKUP AS COPY CURRENT CONTROLFILE TAG '$BACKUP_TAG' FORMAT '$BACKUP_DIR/control01.ctl' REUSE ;
DELETE NOPROMPT BACKUPSET TAG '$BACKUP_TAG';
EOF

else

cat <<EOF >> $dbBackupScript

BACKUP INCREMENTAL LEVEL 1 FOR RECOVER OF COPY WITH TAG '$BACKUP_TAG' DATABASE;
RECOVER COPY OF DATABASE WITH TAG '$BACKUP_TAG';
BACKUP AS COPY CURRENT CONTROLFILE TAG '$BACKUP_TAG' FORMAT '$BACKUP_DIR/control01.ctl' REUSE ;
DELETE NOPROMPT BACKUPSET TAG '$BACKUP_TAG';

EOF

fi

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
   err_exit "This script shoud be run as the oracle user."
fi

if [ "$OPSET" -ne 2 ]; then
   err_exit
fi

if [ ! -d "$BACKUP_DIR" ];then
   err_exit "Backup directory $BACKUP_DIR does not exist."
fi

if [ -z "$ORACLE_SID" -a -z "$(which sqlplus)" ]; then
   err_exit "Environment not properly set."
fi

[ -z "$BACKUP_TAG" ] && BACKUP_TAG=incrmrg_$ORACLE_SID

[ ! -d "$BACKUP_DIR/archivelog" ] && mkdir $BACKUP_DIR/archivelog

DATE=$(date '+%m%d%y-%H%M%S')
echo "$DATE: Begin incremental merge backup." >> $LOGFILE 2>&1

getDbVersion || err_exit
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

createArchLogScript || err_exit

echo -n "Beginning archive log backup $BACKUP_TAG on database $ORACLE_SID ..."
[ ! -z "$BACKUP_DIR" ] && rm -f $BACKUP_DIR/archivelog/* > /dev/null 2>&1
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
