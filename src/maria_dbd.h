#ifndef _MARIA_DBD_H
#define _MARIA_DBD_H

#include <mysql/mysql.h>
#include "common_dbd.h"

#define MARIA_HOST_IP       "MARIA_HOST_IP"
#define MARIA_PORT          "MARIA_PORT"
#define MARIA_USER          "MARIA_USER"
#define MARIA_PASS          "MARIA_PASS"
#define MARIA_DATABASE_NAME "MARIA_DATABASE_NAME"

typedef struct {

    /* MariaDB 전용 */
    void            *maria_conn;                // MYSQL
    void            *maria_stmt;                // MYSQL_STMT
    void            *bind;                      // MYSQL_BIND

    my_bool         ind[MAX_COLS];              // is_null 
    unsigned long   rlen[MAX_COLS];             // length  
    char            *colbuf[MAX_COLS];
    unsigned long   col_buf_size[MAX_COLS];
} db_ctx_t;

void daDBEnv(); 

#endif /* DB_MARIADB_H */

