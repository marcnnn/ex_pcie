PRIV_DIR ?= priv/native
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')
CC ?= cc
CFLAGS ?= -O2
CFLAGS += -std=gnu11 -fPIC -Wall -Wextra -I$(ERTS_INCLUDE_DIR)
LDFLAGS += -shared -lpthread

TARGET = $(PRIV_DIR)/ex_pcie_nif.so

all: $(TARGET)

$(TARGET): c_src/ex_pcie_nif.c
	@mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
