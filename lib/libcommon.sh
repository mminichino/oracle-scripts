#!/bin/bash
#
#
function print_usage {
if [ -n "$PRINT_USAGE" ]; then
   echo "$PRINT_USAGE"
fi
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

function get_password {
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
}

function run_query {
[ -z "$1" ] && err_exit "run_query: query text argument can not be empty."

if [ -n "$QUERY_DEBUG" ]; then
if [ "$QUERY_DEBUG" -eq 1 ]; then
echo "[debug] ==== Begin Query Text ====" 1>&2
cat -nvET << EOF 1>&2
whenever sqlerror exit sql.sqlcode
whenever oserror exit
set heading off;
set pagesize 0;
set feedback off;
$1
exit;
EOF
echo "[debug] ==== End Query Text ====" 1>&2
fi
fi

if [ -n "$QUERY_DEBUG_EXIT" ]; then
if [ "$QUERY_DEBUG_EXIT" -eq 1 ]; then
   exit 0
fi
fi

sqlplus -S / as sysdba << EOF 2>&1
whenever sqlerror exit sql.sqlcode
whenever oserror exit
set heading off;
set pagesize 0;
set feedback off;
$1
exit;
EOF
if [ $? -ne 0 ]; then
   err_exit "Query execution failed: $1"
fi
}
