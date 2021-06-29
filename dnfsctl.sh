#!/bin/sh

function err_exit {
   if [ -n "$1" ]; then
      echo "$1"
   else
      echo "Usage: $0 -o | -f"
   fi
   exit 1
}

if [ -z "$ORACLE_HOME" ]
then
   echo "ORACLE_HOME is not defined"
fi

if [ ! -d $ORACLE_HOME/lib ]
then
   echo "Can not find lib directory in Oracle home."
fi

while getopts "of" opt
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
    \?)
      err_exit
      ;;
  esac
done

