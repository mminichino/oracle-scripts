#!/bin/sh

sqlplus -S / as sysdba<<EOF
set linesize 200
column instance_name format a14
column host_name format a15
column version_full format a14
column status format a10
select instance_name, host_name, version_full, status from v\$instance ;
EOF

sqlplus -S / as sysdba<<EOF
set linesize 200
column name format a60
column member format a40
select file#,name,ts#,bytes from v\$datafile ;
select file#,name,ts#,bytes from v\$tempfile ;
select * from v\$tablespace ;
select group#,status,member from v\$logfile ;
EOF
