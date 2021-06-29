#!/bin/sh
sqlplus -S / as sysdba<<EOF
archive log list;
EOF
sqlplus -S / as sysdba<<EOF
set linesize 200
column name format a70
column status format a6
select name,status from v\$archived_log where status <> 'D' ;
EOF
