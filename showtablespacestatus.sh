#!/bin/sh

sqlplus -S / as sysdba<<EOF
set linesize 200
column tablespace_name format a20
column status format a10
select tablespace_name, status from dba_tablespaces ;
EOF
