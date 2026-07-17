#include <stdio.h>
#include "query0.inc"

int    siQryCnt=1;
unsigned char *scpaQry[2] = {
   pg_test_sql,
   NULL
};

unsigned int siaQryLen[2] = {
   pg_test_sql_len,
   0
};
