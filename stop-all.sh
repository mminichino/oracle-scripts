#!/bin/sh
#
SCRIPTDIR=$(cd $(dirname $0) && pwd)
source $SCRIPTDIR/lib/libcommon.sh
PRINT_USAGE="Usage: $0 [ -r ]"
STOP_RUNNING=0
STOP_ASM=0
FORCE=0

function stop_db {
[ -z "$1" ] && err_exit "stop-db: SID parameter required."
export ORACLE_SID=$1

echo "Stopping database $1 ..."
if [ "$FORCE" -eq 0 ]; then
   sqlCommand="shutdown immediate"
else
   sqlCommand="shutdown abort"
fi
run_query "$sqlCommand"
echo "Done."
}

while getopts "raf" opt
do
  case $opt in
    r)
      STOP_RUNNING=1
      ;;
    a)
      STOP_ASM=1
      ;;
    f)
      FORCE=1
      ;;
    \?)
      err_exit
      ;;
  esac
done

if [ "$STOP_RUNNING" -eq 1 ]; then
for oraSID in $(ps -ef |grep _pmon |grep -v grep | awk '{print $NF}' | sed -e 's/^.*pmon_//')
do
   if [ -n "$(echo $oraSID | sed -e 's/^+.*$//')" ]; then
      stop_db $oraSID
   fi
done
exit 0
fi

if [ "$STOP_ASM" -eq 1 ]; then
which srvctl 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "srvctl not found"

for oraSID in $(ps -ef |grep _pmon |grep -v grep | awk '{print $NF}' | sed -e 's/^.*pmon_//')
do
   if [ -z "$(echo $oraSID | sed -e 's/^+.*$//')" ]; then
      srvctl stop asm -force
   fi
done
exit 0
fi

for line in $(sed -e 's/#.*$//' -e '/^$/d' /etc/oratab)
do
    homePath=$(echo $line | cut -d: -f2)
    if [ -d "$homePath" ]; then
       ORACLE_SID=$(echo $line | cut -d: -f1)
       if [ -n "$(echo $ORACLE_SID | sed -e 's/^+.*$//')" ]; then
	  ps -ef | grep pmon_$ORACLE_SID | grep -v grep >/dev/null 2>&1
	  if [ $? -eq 0 ]; then
             stop_db $ORACLE_SID
	  else
             info_msg "Database $ORACLE_SID not running."
	  fi
       fi
    fi
done
