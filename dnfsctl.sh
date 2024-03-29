#!/bin/sh
#
SCRIPTDIR=$(cd $(dirname $0) && pwd)
source $SCRIPTDIR/lib/libcommon.sh

if [ -z "$ORACLE_HOME" ]
then
   echo "ORACLE_HOME is not defined"
fi

if [ ! -d $ORACLE_HOME/lib ]
then
   echo "Can not find lib directory in Oracle home."
fi

while getopts "ofc" opt
do
  case $opt in
    o)
      echo "Turning dNFS on..."
      cd $ORACLE_HOME/rdbms/lib
      make -f ins_rdbms.mk dnfs_on
      ;;
    f)
      echo "Turning dNFS off..."
      cd $ORACLE_HOME/rdbms/lib
      make -f ins_rdbms.mk dnfs_off
      ;;
    c)
      RESULT=$([ -d $ORACLE_HOME/rdbms/lib/odm ] && find $ORACLE_HOME/rdbms/lib/odm -name libnfsodm\*)
      if [ -n "$RESULT" ]; then
         info_msg "dNFS is enabled."
      else
         info_msg "dNFS is off."
      fi
      ;;
    \?)
      err_exit
      ;;
  esac
done
