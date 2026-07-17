#include <stdio.h>
#include "query0.inc"
#include "query1.inc"
#include "query2.inc"
#include "query3.inc"

int    siQryCnt=4;
unsigned char *scpaQry[5] = {
   oracle_collect_insert_01_20_sql,
   oracle_collect_insert_21_39_sql,
   oracle_collect_merge_01_6_sql,
   oracle_collect_time_sql,
   NULL
};

unsigned int siaQryLen[5] = {
   oracle_collect_insert_01_20_sql_len,
   oracle_collect_insert_21_39_sql_len,
   oracle_collect_merge_01_6_sql_len,
   oracle_collect_time_sql_len,
   0
};
