#!/bin/sh

sqlplus -S / as sysdba<<EOF
set linesize 200
set pagesize 50000
column table_name format a40
column compression format a10
column compress_for format a15
column owner format a10
column blocks format 9999999999
select table_name, compression, compress_for, blocks, owner from all_tables where owner not in ('SYS','SYSTEM','DBSNMP','XDB','OUTLN','APPQOSSYS','GSMADMIN_INTERNAL'); 
EOF
