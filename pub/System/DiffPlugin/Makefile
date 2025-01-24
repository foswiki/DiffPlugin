FOSWIKI_ROOT?=~/foswiki/core
TARGET= build/diff.css build/diff.js

-include $(FOSWIKI_ROOT)/pub/System/JQueryPlugin/Makefile.include

clean:
	rm -f build/*

build/%.css: src/%.css
	@echo generating $@; $(CAT) $^ | $(CSSMIN) $(CSSMIN_ARGS) > $@

build/%.js: src/%.js
	@echo generating $@; $(JSMIN) $^ > $@


