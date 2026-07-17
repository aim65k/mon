#=======================================================================
# Oracle 19c + PostgreSQL + MariaDB Makefile
#=======================================================================

ORACLE_HOME ?= /opt/oracle/product/19c/client_1
CC          = /usr/bin/gcc

TARGET      = dbd_oracle

PG_INC      = $(shell pg_config --includedir)
PG_LIB      = $(shell pg_config --libdir)


ORA_INC     = -I$(ORACLE_HOME)/precomp/public \
              -I$(ORACLE_HOME)/sdk/include \
              -I$(ORACLE_HOME)/rdbms/public

ORA_LIB     = -L$(ORACLE_HOME)/lib

PRJ_INC     = -I. -I../../lib
PRJ_LIB     = -L../../lib

CFLAGS      = -DORACLE -g -O0 -m64 -D_GNU_SOURCE -D_LINUX -fPIC \
              -Wall -Wextra \
              $(PRJ_INC) $(ORA_INC) -I$(PG_INC) \
              -I/usr/pgsql-16/include \
              -mcmodel=medium

LDFLAGS     = $(ORA_LIB) -L$(PG_LIB) $(PRJ_LIB) -L/usr/lib/gcc/x86_64-redhat-linux/11 \
              -mcmodel=medium -Wl,--no-relax

LIBS        = -lclntsh -lpq ../../lib/libdbc.a -lm -ldl -lpthread -lrt

OBJS        = main_dbd.o worker_dbd.o common_dbd.o oracle_dbd.o insert_dbd.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) -o $@ $(OBJS) $(LDFLAGS) $(LIBS) 

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) *.o 

.PHONY: all clean

