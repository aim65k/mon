#=======================================================================
# MSSQL (FreeTDS/unixODBC) + PostgreSQL Makefile
#=======================================================================

CC       = /usr/bin/gcc
TARGET   = dbd_mssql

# ----------------------- PostgreSQL -----------------------
PG_INC   = $(shell pg_config --includedir)
PG_LIB   = $(shell pg_config --libdir)

# ----------------------- unixODBC -------------------------
# FreeTDS는 unixODBC를 통해 연결 (odbc.ini / odbcinst.ini 설정 필요)
ODBC_INC = /usr/include
ODBC_LIB = /usr/lib64

# ----------------------- Project --------------------------
PRJ_INC  = -I. -I../../lib
PRJ_LIB  = -L../../lib

CFLAGS   = -DMSSQL -g -O0 -m64 -D_GNU_SOURCE -D_LINUX -fPIC \
           -Wall -Wextra \
           $(PRJ_INC) -I$(ODBC_INC) -I$(PG_INC) \
           -I/usr/pgsql-16/include

LDFLAGS  = -L$(ODBC_LIB) -L$(PG_LIB) $(PRJ_LIB)

LIBS     = -lodbc -lpq ../../lib/libdbc.a -lm -ldl -lpthread -lrt

OBJS     = main_dbd.o worker_dbd.o common_dbd.o mssql_dbd.o insert_dbd.o

# ----------------------------------------------------------
all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) -o $@ $(OBJS) $(LDFLAGS) $(LIBS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) *.o

.PHONY: all clean

