#!/bin/bash

# metaDB-postgreSQL
export INS_PG_HOST_IP=192.168.10.132
export INS_PG_PORT=5432
export INS_PG_USER=itstone
export INS_PG_PASS=itstone
export INS_PG_DATABASE_NAME=mondb

# dir
export DBD_LOGDIR=$PRJHOME/mon/log
export DBD_DATDIR=$PRJHOME/mon/dat
export DBD_CFGDIR=$PRJHOME/mon/cfg
export DBD_BINDIR=$PRJHOME/mon/bin
export DBD_ADMIN_FILE=process_list.cfg


# oracle
export ORACLE_USER=itstone
export ORACLE_PASS=itstone
export ORACLE_SERVICE_NAME=orclpdb1

query_file=()
query_file+=("oracle_collect_insert_01_20.sql")
query_file+=("oracle_collect_insert_21_39.sql")
query_file+=("oracle_collect_merge_01_6.sql")
query_file+=("oracle_collect_time.sql")
export query_file
#eof
