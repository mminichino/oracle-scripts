#!/bin/bash
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
QUICK=0
archBackupScript=""
dbBackupScript=""
dbIsCdb=0
HOSTNAME=$(uname -n)
SID_ARG=""

function log_output {
    DATE=$(date '+%m-%d-%y_%H:%M:%S')
    while read line; do
        [ -z "$line" ] && continue
        echo "$DATE $HOSTNAME: $line" >> $LOGFILE
    done
}

function err_exit {
   DATE=$(date '+%m%d%y-%H%M%S')" "$(uname -n)
   LEVEL="ERROR"
   if [ -n "$2" ]; then
      if [ "$2" -eq 0 ]; then
         LEVEL="INFO"
      fi
   fi
   if [ -n "$1" ]; then
      echo "${LEVEL}: $1" 2>&1 | log_output
      echo "$1"
   else
      echo "Usage: $0 -s ORACLE_SID -d /backup/directory [ -n | -t backup_tag ]"
   fi
   if [ -n "$2" ]; then
      exit $2
   else
      exit 1
   fi
}

function checkArchLogStatus {
dbArchLogStatus=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select log_mode from v\\$database;
   exit;
EOF`

if [ "$dbArchLogStatus" = "NOARCHIVELOG" ]; then
   err_exit "Database is not in archive log mode."
fi

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

if [ "$dbMajorRev" -gt 11 ]; then
cdbStatus=`sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select cdb from v\\$database ;
   exit;
EOF`

if [ "$cdbStatus" = "YES" ]; then
   dbIsCdb=1
else
   dbIsCdb=0
fi
   
fi
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
   select thread#, sequence# from v\\$log where status = 'CURRENT' or status = 'CLEARING_CURRENT' union 
   select thread#, max(sequence#) from v\\$log where status = 'INACTIVE' group by thread# order by thread#, sequence# ;
   alter system archive log current ;
EOF`

[ $? -ne 0 ] && return 1

dataArray=($logSeqNum)
for ((i=0; i<${#dataArray[@]}; i=i+2)); do
    threadNum=${dataArray[i]}
    seqNum=${dataArray[i+1]}

if [ "$dbMajorRev" -gt 11 ]; then

logArchLogSeqName=`sqlplus -S / as sysdba <<EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\\$archived_log where thread# = $threadNum and sequence# = $seqNum and rownum = 1;
EOF`

if [ -z "$logArchLogSeqName" ]; then
   echo "File for thread $threadNum sequence $seqNum not found, skipping." | log_output
   continue
fi

logArchLogSeqName=$(basename $logArchLogSeqName)

cat <<EOF >> $archBackupScript
BACKUP AS COPY ARCHIVELOG SEQUENCE $seqNum THREAD $threadNum FORMAT '$BACKUP_DIR/archivelog/$logArchLogSeqName' ;
EOF

else

cat <<EOF >> $archBackupScript
BACKUP AS COPY ARCHIVELOG SEQUENCE $seqNum THREAD $threadNum ;
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

if [ "$dbMajorRev" -gt 11 -a "$dbIsCdb" -eq 1 ]; then

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
ALLOCATE CHANNEL dbbkup DEVICE TYPE DISK FORMAT '$BACKUP_DIR/%U';

EOF

if [ "$dbMajorRev" -gt 11 -a "$dbIsCdb" -eq 1 ]; then
for ((i=0; i<${#pdbArray[@]}; i=i+1)); do
pdbName=$(echo ${pdbArray[$i]} | sed -e 's/\$//g')
cat <<EOF >> $dbBackupScript
ALLOCATE CHANNEL ${pdbName} DEVICE TYPE DISK FORMAT '$BACKUP_DIR/$pdbName/%U';
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
CATALOG DATAFILECOPY '$dataFileName' LEVEL 0 TAG '$BACKUP_TAG' ;
EOF
done

if [ "${#pdbArray[@]}" -gt 0 ]; then

for ((i=0; i<${#pdbArray[@]}; i=i+1)); do
pdbName=$(echo ${pdbArray[$i]} | sed -e 's/\$//g')

if [ -d "$BACKUP_DIR/$pdbName" ]; then
for dataFileName in $(ls $BACKUP_DIR/$pdbName/data_* 2>/dev/null)
do
cat <<EOF >> $dbBackupScript
CATALOG DATAFILECOPY '$dataFileName' LEVEL 0 TAG '$BACKUP_TAG' ;
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

if [ "$dbMajorRev" -gt 11 -a "$dbIsCdb" -eq 1 ]; then

cat <<EOF >> $dbBackupScript

BACKUP CHANNEL 'dbbkup' INCREMENTAL LEVEL 1 FOR RECOVER OF COPY WITH TAG '$BACKUP_TAG' DATABASE ROOT;
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

return 0
}

if [ -z "$(which stat)" ]; then
   err_exit "This script requires the stat utility."
fi

while getopts "s:t:d:nq" opt
do
  case $opt in
    n)
      NO_CATALOG=1
      ;;
    s)
      SID_ARG=$OPTARG
      OPSET=$(($OPSET+1))
      ;;
    d)
      BACKUP_DIR=$OPTARG
      OPSET=$(($OPSET+1))
      ;;
    t)
      BACKUP_TAG=$OPTARG
      ;;
    q)
      QUICK=1
      ;;
    \?)
      err_exit
      ;;
  esac
done

if [ -z "$ORACLE_HOME" ]; then
   if [ -f $HOME/.bashrc ]; then
      . $HOME/.bashrc
   else
      err_exit "Environment not set properly"
   fi
fi

export ORACLE_SID=${SID_ARG:-oradb}

if [ -z "$(cut -d: -f 1 /etc/oratab | grep $ORACLE_SID)" ]; then
   # Try to get grid home
   GRID_HOME=$(dirname $(dirname $(ps -ef | grep evmd.bin | grep -v grep | awk '{print $NF}')))
   if [ -n "$GRID_HOME" ]; then
      export START_PATH=$PATH
      export PATH=$GRID_HOME/bin:$START_PATH
      export LD_LIBRARY_PATH=$GRID_HOME/lib
      ORACLE_HOME=$(srvctl config database -db $ORACLE_SID | grep -i -e "^oracle home" -e "^PRCD-1229" | awk '{print $NF}' | sed -e 's/\.$//')
      [ -z "$ORACLE_HOME" ] && err_exit "$ORACLE_SID not properly configured."
      LOCAL_ORACLE_SID=$(basename $(ls $ORACLE_HOME/dbs/hc_${ORACLE_SID}*.dat) | sed -e 's/hc_//' -e 's/\.dat//')
      if [ -z "$LOCAL_ORACLE_SID" ]; then
         err_exit "Can not configure local instance SID from Grid Home $GRID_HOME"
      fi
      echo "CRS found, configured instance $LOCAL_ORACLE_SID from Grid." | log_output
      export PATH=$ORACLE_HOME/bin:$GRID_HOME/bin:$START_PATH
      export LD_LIBRARY_PATH==$ORACLE_HOME/lib
      GLOBAL_SID=$ORACLE_SID
      export ORACLE_SID=$LOCAL_ORACLE_SID
   else
      err_exit "DB Instance $ORACLE_SID not found in /etc/oratab."
   fi
else
   ORAENV_ASK=NO
   source oraenv
fi

if [ -n "$GLOBAL_SID" ]; then
   DBNAME=$GLOBAL_SID
else
   DBNAME=$ORACLE_SID
fi

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

echo "Begin incremental merge backup." 2>&1 | log_output

checkArchLogStatus
getDbVersion || err_exit "Can not get database version"
createBackupScript || err_exit "Can not create backup script"

echo "Beginning incremental backup $BACKUP_TAG on database $ORACLE_SID" 2>&1 | log_output
rman <<EOF 2>&1 | log_output
connect target /
@$dbBackupScript
EOF

if [ $? -ne 0 ]
then
   err_exit "Backup for $ORACLE_SID failed. See $LOGFILE for more information."
else
   echo "Backup Phase Done." 2>&1 | log_output
fi

createArchLogScript || err_exit

echo "Beginning archive log backup $BACKUP_TAG on database $ORACLE_SID" 2>&1 | log_output
[ ! -z "$BACKUP_DIR" ] && rm -f $BACKUP_DIR/archivelog/* > /dev/null 2>&1
rman <<EOF 2>&1 | log_output
connect target /
@$archBackupScript
EOF

if [ $? -ne 0 ]
then
   err_exit "Backup for $ORACLE_SID failed. See $LOGFILE for more information."
else
   echo "Archivelog Backup Done." 2>&1 | log_output
fi

if [ "$QUICK" -ne 1 ]; then
echo "Writing database configuration file." 2>&1 | log_output
$SCRIPTLOC/createConfigFile.sh -s $DBNAME -d $BACKUP_DIR -p 2>&1 | log_output

if [ $? -ne 0 ]
then
   err_exit "Saving configuration for $ORACLE_SID failed. See $LOGFILE for more information."
else
   echo "Saving configuration done." 2>&1 | log_output
fi
fi

echo "End Backup." 2>&1 | log_output

exit 0
##
