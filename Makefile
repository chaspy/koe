PREFIX ?= $(HOME)/.local

install:
	install -d $(PREFIX)/bin
	install -m 755 whisper-ja-toggle $(PREFIX)/bin/whisper-ja-toggle

uninstall:
	rm -f $(PREFIX)/bin/whisper-ja-toggle

.PHONY: install uninstall
