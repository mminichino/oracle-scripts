#!/bin/bash
#
#
unset SID_ARG
SCRIPTDIR=$(cd $(dirname $0) && pwd)
LISTENER_ONLY=0

function print_usage {
   echo "Usage: $0 -s SID [ -l ]"
   echo "          -s Oracle SID"
   echo "          -l Just remove SID from tnsnames.ora"
}

function err_exit {
   if [ -n "$1" ]; then
      echo "[!] Error: $1"
   else
      print_usage
   fi
   exit 1
}

function warn_msg {
   if [ -n "$1" ]; then
      echo "[i] Warning: $1"
   fi
}

function listener_remove {
[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME not set."
[ ! -f $ORACLE_HOME/network/admin/tnsnames.ora ] && err_exit "tnsnames.ora file not found."
[ -z "$ORACLE_SID" ] && err_exit "ORACLE_SID not set."

sed -i -e "/$ORACLE_SID.*=/,/^ *\$/d" $ORACLE_HOME/network/admin/tnsnames.ora
}

function listener_config {

[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME is not set"

if [ -n "$1" ]; then
   echo "Removing instance $1 on node $(uname -n)"
   listener_remove
fi

which lsnrctl 2>&1 >/dev/null
[ $? -ne 0 ] && warn_msg "lsnrctl not found"

lsnrctl status 2>&1 >/dev/null
if [ $? -eq 0 ]; then
   lsnrctl reload
fi

}

function get_db_path {

ISCDB=`sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\\$containers where con_id = 0;
   exit;
EOF
`

[ $? -ne 0 ] && err_exit "Error getting CDB status"

if [ -z "$ISCDB" ]; then
   cdbConId=1
else
   cdbConId=0
fi

sysDataFile=`sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\\$datafile where ts# = 0 and con_id = $cdbConId ;
   exit;
EOF
`

[ $? -ne 0 ] && err_exit "Error connecing to SID $ORACLE_SID"

dataFilePath=$(dirname $sysDataFile)

archLogLocation=`sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select destination from v\\$archive_dest where dest_name='LOG_ARCHIVE_DEST_1';
   exit;
EOF
`

[ $? -ne 0 ] && err_exit "Error connecing to SID $ORACLE_SID"

recoveryLocation=`sqlplus -S / as sysdba << EOF
   whenever sqlerror exit sql.sqlcode
   whenever oserror exit
   set heading off;
   set pagesize 0;
   set feedback off;
   select name from v\\$recovery_file_dest where con_id = 0;
   exit;
EOF
`

[ $? -ne 0 ] && err_exit "Error connecing to SID $ORACLE_SID"

}

while getopts "s:l" opt
do
  case $opt in
    s)
      SID_ARG=$OPTARG
      ;;
    l)
      LISTENER_ONLY=1
      ;;
    \?)
      print_usage
      exit 1
      ;;
  esac
done

[ -z "$SID_ARG" ] && [ -z "$ORACLE_SID" ] && err_exit "Oracle SID not defined"
export ORACLE_SID=$SID_ARG

if [ "$LISTENER_ONLY" -eq 1 ]; then
   listener_remove
   exit 0
fi

get_db_path

echo "Deleting Oracle SID $ORACLE_SID"
echo "  Deleting data directory   : $dataFilePath"
echo "  Deleting recovery directoy: $recoveryLocation"
echo "  Deleting log directory    : $archLogLocation"
echo "WARNING: This operation is destructive and can not be undone."
echo -n "Enter Oracle SID to contine: "
read ANSWER

if [ "$ANSWER" != "$ORACLE_SID" ]; then
   echo ""
   echo "Aborting ..."
   exit 1
fi

while true
do
   echo -n "Password: "
   read -s PASSWORD
   echo ""
   echo -n "Retype Password: "
   read -s CHECK_PASSWORD
   echo ""
   if [ "$PASSWORD" != "$CHECK_PASSWORD" ]; then
      echo "Passwords do not match"
   else
      break
   fi
done

dbca -silent -deleteDatabase -sourceDB $ORACLE_SID -sysDBAUserName sys -sysDBAPassword "$PASSWORD" || err_exit "Database $ORACLE_SID delete failed"

listener_config $ORACLE_SID

echo "Removing $dataFilePath"
[ -n "$dataFilePath" ] && [ "$dataFilePath" != "/" ] && rm -r $dataFilePath
echo "Removing $archLogLocation"
[ -n "$archLogLocation" ] && [ "$archLogLocation" != "/" ] && rm -r $archLogLocation
echo "Removing $recoveryLocation"
[ -n "$recoveryLocation" ] && [ "$recoveryLocation" != "/" ] && rm -r $recoveryLocation

exit 0
