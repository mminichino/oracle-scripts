#!/bin/sh
#
SCRIPTDIR=$(cd $(dirname $0) && pwd)
source $SCRIPTDIR/lib/libcommon.sh
PRINT_USAGE="Usage: $0 [ -s SID | -a ]"
ARCHLOG=0

while getopts "s:a" opt
do
  case $opt in
    s)
      export ORACLE_SID=$OPTARG
      ;;
    a)
      ARCHLOG=1
      ;;
    \?)
      err_exit
      ;;
  esac
done

SHOW_HEADERS=1

sqlQuery="column instance_name format a14
column host_name format a15
column version_full format a14
column status format a10
select instance_name, host_name, version_full, status from v\$instance ;"
run_query "$sqlQuery"

sqlQuery="column name format a60
column member format a60
column status format a10
select file#,name,ts#,bytes from v\$datafile ;
select file#,name,ts#,bytes from v\$tempfile ;
select * from v\$tablespace ;
select group#,member from v\$logfile ;
select a.group#,b.status,a.member from v\$logfile a, v\$log b where a.group# = b.group# ;
archive log list ;"
run_query "$sqlQuery"

if [ "$ARCHLOG" -eq 1 ]; then
sqlQuery="column name format a60
column name format a70
column status format a6
select name,status from v\$archived_log where status <> 'D' ;"
run_query "$sqlQuery"
fi

##
