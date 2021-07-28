#!/bin/bash
#
#
SCRIPTDIR=$(cd $(dirname $0) && pwd)
source $SCRIPTDIR/lib/libcommon.sh
PRINT_USAGE="Usage: $0 -s SID [ -l ]
             -s Oracle SID
             -l Just remove SID from tnsnames.ora
             -m Manual remove without dbca"
unset SID_ARG
SCRIPTDIR=$(cd $(dirname $0) && pwd)
LISTENER_ONLY=0
MANUAL_REMOVE=0

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

while getopts "s:lm" opt
do
  case $opt in
    s)
      SID_ARG=$OPTARG
      ;;
    l)
      LISTENER_ONLY=1
      ;;
    m)
      MANUAL_REMOVE=1
      ;;
    \?)
      print_usage
      exit 1
      ;;
  esac
done

[ -z "$SID_ARG" ] && [ -z "$ORACLE_SID" ] && err_exit "Oracle SID not defined"
export ORACLE_SID=$SID_ARG

warn_prompt

if [ "$LISTENER_ONLY" -eq 1 ]; then
   listener_remove
   exit 0
fi

if [ "$MANUAL_REMOVE" -eq 1 ]; then
   drop_database
   exit 0
fi

get_db_path

echo "Deleting Oracle SID $ORACLE_SID"
echo "  Deleting data directory   : $dataFilePath"
echo "  Deleting recovery directoy: $recoveryLocation"
echo "  Deleting log directory    : $archLogLocation"
ask_prompt

get_password

dbca -silent -deleteDatabase -sourceDB $ORACLE_SID -sysDBAUserName sys -sysDBAPassword "$ORACLE_PWD" || err_exit "Database $ORACLE_SID delete failed"

listener_config $ORACLE_SID

echo "Removing $dataFilePath"
[ -n "$dataFilePath" ] && [ "$dataFilePath" != "/" ] && rm -r $dataFilePath
echo "Removing $archLogLocation"
[ -n "$archLogLocation" ] && [ "$archLogLocation" != "/" ] && rm -r $archLogLocation
echo "Removing $recoveryLocation"
[ -n "$recoveryLocation" ] && [ "$recoveryLocation" != "/" ] && rm -r $recoveryLocation

exit 0
