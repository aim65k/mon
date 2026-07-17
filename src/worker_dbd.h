#ifndef _WORKER_DBD_H
#define _WORKER_DBD_H

#include <pthread.h>

typedef struct _thd_t {
    pthread_t   ptThdId;            // thread id
    int         iAlertMicroSec;     // 일정한 micro sec마다 실행
    int         iQryIdx;            // 몇번째 query 정보
} thd_t;

typedef struct _thd_info_t {
    int         iUseThdCnt;     // 현재 몇개 사용중인지
    thd_t       saThd[DBD_THD_MAX_CNT];                                                                            
} thd_info_t;

int daRunWorker();


#endif
