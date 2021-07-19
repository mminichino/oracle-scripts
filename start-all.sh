#!/bin/sh
#

function print_usage {
   echo "Usage: $0"
}

function err_exit {
   if [ -n "$1" ]; then
      echo "[!] Error: $1"
   else
      print_usage
   fi
   exit 1
}

function start-db {
which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

[ -z "$1" ] && err_exit "start-db: SID parameter required."

export ORACLE_SID=$1

echo "Starting database $1 ..."
sqlplus -S / as sysdba << EOF
   set heading off;
   set pagesize 0;
   set feedback off;
   startup
   exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Failed to start database"
else
   echo "Done."
fi
}

for line in $(sed -e 's/#.*$//' -e '/^$/d' /etc/oratab)
do
    homePath=$(echo $line | cut -d: -f2)
    if [ -d "$homePath" ]; then
       ORACLE_SID=$(echo $line | cut -d: -f1)
       if [ -n "$(echo $ORACLE_SID | sed -e 's/^+.*$//')" ]; then
          start-db $ORACLE_SID
       fi
    fi
done
