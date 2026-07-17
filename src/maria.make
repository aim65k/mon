#=======================================================================
# Oracle 19c + PostgreSQL + MariaDB Makefile
#=======================================================================

ORACLE_HOME ?= /opt/oracle/product/19c/client_1
CC          = /usr/bin/gcc

TARGET      = dbd_maria

PG_INC      = $(shell pg_config --includedir)
PG_LIB      = $(shell pg_config --libdir)


MARIA_INC   = $(shell mariadb_config --include 2>/dev/null || mysql_config --include)
MARIA_LIBS  = $(shell mariadb_config --libs 2>/dev/null || mysql_config --libs)

ORA_INC     = -I$(ORACLE_HOME)/precomp/public \
              -I$(ORACLE_HOME)/rdbms/public

ORA_LIB     = -L$(ORACLE_HOME)/lib

PRJ_INC     = -I. -I../../lib
PRJ_LIB     = -L../../lib

CFLAGS      = -DMARIA -g -O0 -m64 -D_GNU_SOURCE -D_LINUX -fPIC \
              -Wall -Wextra \
              $(PRJ_INC) $(ORA_INC) -I$(PG_INC) \
              -I/usr/pgsql-16/include \
              -mcmodel=medium \
                $(MARIA_INC)

LDFLAGS     = $(ORA_LIB) -L$(PG_LIB) $(PRJ_LIB) -L/usr/lib/gcc/x86_64-redhat-linux/11 \
              -mcmodel=medium -Wl,--no-relax \
                $(MARIA_LIBS)

LIBS        = -lclntsh -lpq ../../lib/libdbc.a -lm -ldl -lpthread -lrt

OBJS        = main_dbd.o worker_dbd.o common_dbd.o maria_dbd.o insert_dbd.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) -o $@ $(OBJS) $(LDFLAGS) $(LIBS) 

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) *.o 

.PHONY: all clean

