#!/bin/sh
#
SCRIPTLOC=$(cd $(dirname $0) && pwd)
[ ! -d $SCRIPTLOC/log ] && mkdir $SCRIPTLOC/log
LOGFILE=$SCRIPTLOC/log/sql.trc
HOSTNAME=$(uname -n)
GLOBAL_SID=""

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
      echo "Usage: $0 -s ORACLE_SID -b | -e | -c | -q"
   fi
   if [ -n "$2" ]; then
      exit $2
   else
      exit 1
   fi
}

function dbStartHotBackup {

sqlplus -S / as sysdba <<EOF 2>&1 | log_output
whenever sqlerror exit 1
alter system archive log current ;
alter database begin backup ;
EOF

return $?
}

function dbEndHotBackup {

sqlplus -S / as sysdba <<EOF 2>&1 | log_output
whenever sqlerror exit 1
alter database end backup ;
alter system archive log current ;
EOF

return $?
}

function getDbfMountPoint {

local firstDbfFilePath=`sqlplus -S / as sysdba <<EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\\$datafile where rownum = 1 ;
   exit;
EOF`
local ret=$?

dbfmountpoint=$(cd $(dirname $firstDbfFilePath); df -h . | tail -n 1 | awk '{print $NF}')

return $ret
}

CHECK=0
END=0
BEGIN=0
OPSET=0
QUICK=0
dbfmountpoint=""

if [ -z "$(which stat)" ]; then
   err_exit "This script requires the stat utility."
fi

while getopts "s:cbeq" opt
do
  case $opt in
    c)
      CHECK=1
      OPSET=$(($OPSET+1))
      ;;
    s)
      export ORACLE_SID=$OPTARG
      ;;
    e)
      END=1
      OPSET=$(($OPSET+1))
      ;;
    b)
      BEGIN=1
      OPSET=$(($OPSET+1))
      ;;
    q)
      QUICK=1
      ;;
    \?)
      err_exit
      ;;
  esac
done

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

if [ "$OPSET" -ne 1 ]; then
   err_exit
fi

if [ -z "$ORACLE_HOME" -a -z "$(which sqlplus)" ]; then
   err_exit "Environment not properly set."
fi

if [ "$BEGIN" -eq 1 ]; then

echo "Begin hot backup mode." 2>&1 | log_output

dbStartHotBackup

if [ $? -ne 0 ]
then
   err_exit "Failed to put $ORACLE_SID into hot backup mode.  See $LOGFILE for more information."
fi

echo "Begin Backup Done." 2>&1 | log_output

fi

if [ "$END" -eq 1 ]; then

echo "End hot backup mode." 2>&1 | log_output

dbEndHotBackup

if [ $? -ne 0 ]
then
   err_exit "Failed to end $ORACLE_SID hot backup mode.  See $LOGFILE for more information."
fi

if [ "$QUICK" -ne 1 ]; then
echo "Writing database configuration file." 2>&1 | log_output
$SCRIPTLOC/createConfigFile.sh -s $DBNAME -h 2>&1 | log_output

if [ $? -ne 0 ]
then
   err_exit "Saving configuration for $ORACLE_SID failed. See $LOGFILE for more information."
else
   echo "Save configuration done." 2>&1 | log_output
fi
fi

echo "End Backup Done." 2>&1 | log_output

fi

if [ "$CHECK" -eq 1 ]; then

BACKUPMODE=0
STATUS=`sqlplus -S / as sysdba <<EOF
set heading off;
set pagesize 0;
set feedback off;
select regexp_replace(status,'[ ]*','') from v\\$backup ;
EOF`

for file in $STATUS; do
   [ "$file" != "NOTACTIVE" ] && BACKUPMODE=1
done

if [ "$BACKUPMODE" -eq 1 ]; then
   err_exit "Database $ORACLE_SID is in hot backup mode."
else
   err_exit "Database $ORACLE_SID is not in backup mode." 0
fi

fi

exit 0
##
