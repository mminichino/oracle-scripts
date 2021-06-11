#!/bin/sh
#

unset SID_ARG
PWD_FLAG=0

function print_usage {
   echo "Usage: $0 -s SID -P"
   echo "          -s Oracle SID"
   echo "          -P Create database password file and exit"
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

function info_msg {
   if [ -n "$1" ]; then
      echo "[i] Notice: $1"
   fi
}

function create_passwd_file {

[ -z "$ORACLE_HOME" ] && err_exit "ORACLE_HOME not set"
[ -z "$ORACLE_SID" ] && err_exit "ORACLE_SID not set"
[ -z "$ORACLE_PWD" ] && err_exit "Oracle password can not be null"

which orapwd 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "orapwd not found"

orapwd file=$ORACLE_HOME/dbs/orapw${ORACLE_SID} password=${ORACLE_PWD} entries=30
}

which sqlplus 2>&1 >/dev/null
[ $? -ne 0 ] && err_exit "sqlplus not found"

while getopts "s:P" opt
do
  case $opt in
    s)
      SID_ARG=$OPTARG
      ;;
    P)
      PWD_FLAG=1
      ;;
    \?)
      print_usage
      exit 1
      ;;
  esac
done

[ -n "$SID_ARG" ] && export ORACLE_SID=${SID_ARG}

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
export ORACLE_PWD=$PASSWORD

if [ "$PWD_FLAG" -eq 1 ]; then
   create_passwd_file
   exit 0
fi
