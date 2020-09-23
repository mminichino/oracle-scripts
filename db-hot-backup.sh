#!/bin/sh
#
SCRIPTLOC=$(cd $(dirname $0) && pwd)
[ ! -d $SCRIPTLOC/log ] && mkdir $SCRIPTLOC/log
LOGFILE=$SCRIPTLOC/log/sql.trc

function dbStartHotBackup {

sqlplus -S / as sysdba <<EOF >> $LOGFILE 2>&1
whenever sqlerror exit 1
alter system archive log current ;
alter database begin backup ;
EOF

return $?
}

function dbEndHotBackup {

sqlplus -S / as sysdba <<EOF >> $LOGFILE
whenever sqlerror exit 1
alter database end backup ;
alter system archive log current ;
EOF

return $?
}

CHECK=0
END=0
BEGIN=0
OPSET=0

if [ -z "$(which stat)" ]; then
   echo "This script requires the stat utility."
   exit 1
fi

while getopts "s:cbe" opt
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
    \?)
      echo "Usage: $0 -s ORACLE_SID -f | -t | -c"
      exit 1
      ;;
  esac
done

ORAENV_ASK=NO
source oraenv

if [ "$(stat -t -c '%u' /etc/oratab)" != "$(id -u)" ]; then
   echo "This script shoud be run as the oracle user."
   exit 1
fi

if [ "$OPSET" -ne 1 ]; then
   echo "Usage: $0 -s ORACLE_SID -f | -t | -c"
   exit 1
fi

if [ -z "$ORACLE_HOME" -a -z "$(which sqlplus)" ]; then
   echo "Environment not properly set."
   exit 1
fi

if [ "$BEGIN" -eq 1 ]; then

DATE=$(date '+%m%d%y-%H%M%S')
echo "$DATE: Begin hot backup mode." >> $LOGFILE 2>&1

dbStartHotBackup

if [ $? -ne 0 ]
then
   echo "Failed to put $ORACLE_SID into hot backup mode.  See $LOGFILE for more information."
   exit 1
fi

DATE=$(date '+%m%d%y-%H%M%S')
echo "$DATE: Done." >> $LOGFILE 2>&1

fi

if [ "$END" -eq 1 ]; then

DATE=$(date '+%m%d%y-%H%M%S')
echo "$DATE: End hot backup mode." >> $LOGFILE 2>&1

dbEndHotBackup

if [ $? -ne 0 ]
then
   echo "Failed to end $ORACLE_SID hot backup mode.  See $LOGFILE for more information."
   exit 1
fi

DATE=$(date '+%m%d%y-%H%M%S')
echo "$DATE: Done." >> $LOGFILE 2>&1

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
   echo "Database $ORACLE_SID is in hot backup mode."
   exit 1
else
   echo "Database $ORACLE_SID is not in backup mode."
fi

fi

exit 0
##
