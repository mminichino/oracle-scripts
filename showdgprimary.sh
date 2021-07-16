#!/bin/sh
sqlplus -S / as sysdba<<EOF
set pagesize 0
set linesize 200
column status format a15
column destination format a80
column error format a15
column SEVERITY format a15
column MESSAGE format a80
select dest_id, status, destination, error from v\$archive_dest where dest_id<=2 ;
select * from (select SEVERITY,ERROR_CODE,MESSAGE from v\$dataguard_status order by timestamp desc) where rownum <= 20 ;
EOF
