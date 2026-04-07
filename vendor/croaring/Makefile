UNAME := $(shell uname)
ifeq ($(UNAME), Darwin)
  LIB_EXT := dylib
  SHARED_FLAG := -dynamiclib
else
  LIB_EXT := so
  SHARED_FLAG := -shared
endif

CFLAGS := -O3 $(SHARED_FLAG) -fPIC

all:
	$(CC) $(CFLAGS) -o libcroaring.$(LIB_EXT) roaring.c helpers.c

clean:
	rm -f libcroaring.*
