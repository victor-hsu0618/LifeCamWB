CC      = clang
CFLAGS  = -Wall -Wextra -O2
LDFLAGS = -framework CoreMediaIO -framework CoreFoundation

TARGET  = lifecam_wb

$(TARGET): lifecam_wb.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: clean
