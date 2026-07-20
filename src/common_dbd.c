#include "main_dbd.h"
#include "common_dbd.h"
#include <pthread.h>


void 
daAppendString(char **buf, size_t *cap, size_t *len, const char *s)
{
    size_t slen;

    if (!s) return;

    slen = strlen(s);

    if (*len + slen + 1 >= *cap) {
        size_t newcap = *cap;

        while (*len + slen + 1 >= newcap)
            newcap *= 2;

        *buf = realloc(*buf, newcap);
        if (!*buf) {
            EXIT("realloc failed\n");
        }

        *cap = newcap;
    }

    memcpy(*buf + *len, s, slen);
    *len += slen;
    (*buf)[*len] = 0x00;
}

char *
daEscapePgCopyField(const char *src)
{
    size_t i, len, cap;
    char *out;

    if (!src) return NULL;

    len = 0;
    cap = strlen(src) * 2 + 16;
    out = (char *)dcMalloc(cap);

    for (i = 0; src[i]; i++) {
        switch (src[i]) {
        case '\\':
            daAppendString(&out, &cap, &len, "\\\\");
            break;
        case '\t':
            daAppendString(&out, &cap, &len, "\\t");
            break;
        case '\n':
            daAppendString(&out, &cap, &len, "\\n");
            break;
        case '\r':
            daAppendString(&out, &cap, &len, "\\r");
            break;
        default:
            if (len + 2 >= cap) {
                cap *= 2;
                out = realloc(out, cap);
                if (!out) {
                    EXIT("realloc failed\n");
                }
            }
            out[len++] = src[i];
            out[len] = 0x00;
            break;
        }
    }

    return out;
}

char *
daPrintRunMethod(char cRunMethod)
{
    switch(cRunMethod)
    {
        case    RUN_METHOD_INSERT:  return("INSERT");
        case    RUN_METHOD_SELECT:  return("SELECT");
        case    RUN_METHOD_MERGE:   return("MERGE");
        default:
            LOGD("cRunMethod:%c value not defined, exit\n", cRunMethod);
            exit(1);
    }
    return (char *)NULL;
}

pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
int ready_to_work = 0; // 스레드가 일해도 되는지 체크하는 플래그

int
daStopQry(qry_t *spQry)
{
    spQry->cRunYn = DEF_STOP;
    LOGE("[%s] 해당 query는 오류로 더이상 수행하지 않습니다. \n", spQry->caTitle);
    pthread_mutex_lock(&mutex);
    while (ready_to_work == 0) {
        // 이 함수가 실행되면 이 스레드는 멈추고 CPU 점유율을 0%로 만듭니다.
        pthread_cond_wait(&cond, &mutex); 
    }
    pthread_mutex_unlock(&mutex);
    return(0);
}
