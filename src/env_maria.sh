#!/bin/bash

# dir
export DBD_LOGDIR=$PRJHOME/mon/log
export DBD_DATDIR=$PRJHOME/mon/dat
export DBD_CFGDIR=$PRJHOME/mon/cfg

# insert DB-postgreSQL(test2)
export INS_PG_HOST_IP=192.168.10.132
export INS_PG_PORT=5432
export INS_PG_USER=itstone
export INS_PG_PASS=itstone
export INS_PG_DATABASE_NAME=mondb

# mariaDB(test2)
export MARIA_HOST_IP=192.168.10.132
export MARIA_PORT=3306
export MARIA_USER=itstone
export MARIA_PASS=itstone
export MARIA_DATABASE_NAME=employees

export query_file=("maria_collect_insert_01_13.sql" "maria_collect_merge_01_02.sql")
#eof
