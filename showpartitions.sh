#!/bin/sh

sqlplus -S / as sysdba<<EOF
set linesize 200
column partition_name format a30
column segment_name format a30
column table_owner format a11
select partition_name,segment_name,bytes from dba_segments where (segment_type = 'TABLE PARTITION') and (tablespace_name <> 'SYSAUX') ;
select table_owner,table_name,partition_name,compression,compress_for from DBA_TAB_PARTITIONS where (table_owner <> 'SYS') and (table_owner <> 'SYSTEM') ;
EOF
