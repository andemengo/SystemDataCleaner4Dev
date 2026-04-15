PREFIX ?= /usr/local
BINARY = SystemDataCleaner4Dev
INSTALL_NAME = systemdatacleaner

.PHONY: build install uninstall clean

build:
	swiftc -O SystemDataCleaner4Dev.swift -o $(BINARY)

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BINARY) $(PREFIX)/bin/$(INSTALL_NAME)
	@echo "Installed to $(PREFIX)/bin/$(INSTALL_NAME)"

uninstall:
	rm -f $(PREFIX)/bin/$(INSTALL_NAME)
	@echo "Uninstalled $(INSTALL_NAME)"

clean:
	rm -f $(BINARY)
