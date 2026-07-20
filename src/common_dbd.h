#ifndef _COMMON_DBD_H
#define _COMMON_DBD_H

#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include "common_db.h"
#include "log_db.h"

#define MAX_COLS            256
#define LINE_BUF_INIT       8192

void daAppendString(char **buf, size_t *cap, size_t *len, const char *s);
char *daEscapePgCopyField(const char *src);
char *daPrintRunMethod(char cRunMethod);

#endif
