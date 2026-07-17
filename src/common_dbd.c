#include "main_dbd.h"
#include "common_dbd.h"


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
