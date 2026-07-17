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

# postgreSQL
export PG_HOST_IP=192.168.10.132
export PG_PORT=5432
export PG_USER=itstone
export PG_PASS=itstone
export PG_DATABASE_NAME=mondb

export query_file=("pg_test.sql")
#eof
