# Force the use of bash for shell statements. If we don't do this, many Linux
# variants will use sh.
SHELL := /bin/bash

# Can be overridden on the command line. This is the name of the tar.gz file
# produced when you run `make dist'.
DIST_NAME = $(shell echo "Doppio_`date +'%y-%m-%d'`.tar.gz")

# DEPENDENCIES
DOPPIO_DIR := $(CURDIR)
COFFEEC  := $(DOPPIO_DIR)/node_modules/coffee-script/bin/coffee
UGLIFYJS := $(DOPPIO_DIR)/node_modules/uglify-js/bin/uglifyjs
OPTIMIST := $(DOPPIO_DIR)/node_modules/optimist/index.js
DOCCO    := $(DOPPIO_DIR)/node_modules/docco/bin/docco
ADMZIP   := $(DOPPIO_DIR)/node_modules/adm-zip/adm-zip.js
JAZZLIB  := $(DOPPIO_DIR)/vendor/classes/java/util/zip/DeflaterEngine.class
JRE      := $(DOPPIO_DIR)/vendor/classes/java/lang/Object.class
SED      := $(shell if command -v gsed >/dev/null; then echo "gsed"; else echo "sed"; fi;)

# JAVA TEST CLASSES & DEMOS
SOURCES = $(wildcard classes/test/*.java)
DISASMS = $(SOURCES:.java=.disasm)
RUNOUTS = $(SOURCES:.java=.runout)
CLASSES = $(SOURCES:.java=.class)
RESULTS = $(SOURCES:.java=.result)
DEMO_SRCS = $(wildcard classes/demo/*.java) classes/test/FileRead.java
DEMO_CLASSES = $(DEMO_SRCS:.java=.class)

# HTML
BROWSER_HTML = $(wildcard browser/[^_]*.html)
release_BUILD_DIR = build/release
benchmark_BUILD_DIR = build/benchmark
release_BUILD_HTML = $(addprefix $(release_BUILD_DIR)/, $(notdir $(BROWSER_HTML)))
benchmark_BUILD_HTML = $(addprefix $(benchmark_BUILD_DIR)/, $(notdir $(BROWSER_HTML)))

# SCRIPTS
# the order here is important: must match the order of includes
# in the browser frontend html.
COMMON_BROWSER_SRCS = vendor/_.js \
	vendor/gLong.js \
	browser/util.coffee \
	browser/node.coffee \
	src/util.coffee \
	src/exceptions.coffee \
	src/logging.coffee \
	src/types.coffee \
	src/java_object.coffee \
	src/opcodes.coffee \
	src/attributes.coffee \
	src/ConstantPool.coffee \
	src/disassembler.coffee \
	src/natives.coffee \
	src/methods.coffee \
	src/ClassFile.coffee \
	src/runtime.coffee \
	src/jvm.coffee \
	browser/untar.coffee
# Release uses the actual jQuery console.
release_BROWSER_SRCS = $(COMMON_BROWSER_SRCS) \
	vendor/jquery.console.js \
	browser/frontend.coffee
# Benchmark uses the mock jQuery console.
benchmark_BROWSER_SRCS = $(COMMON_BROWSER_SRCS) \
	browser/mockconsole.coffee \
	browser/frontend.coffee
# they don't survive uglifyjs and are already minified, so include them
# separately. also, this allows us to put them at the end of the document to
# reduce load time.
ACE_SRCS = vendor/ace/src-min/ace.js \
	vendor/ace/src-min/mode-java.js \
	vendor/ace/src-min/theme-twilight.js
CLI_SRCS = $(wildcard src/*.coffee console/*.coffee)

# Variable setting that is conditional on the target
ifeq ($(MAKECMDGOALS),benchmark)
BUILD_DIR = $(benchmark_BUILD_DIR)
BUILD_HTML = $(benchmark_BUILD_HTML)
BROWSER_SRCS = $(benchmark_BROWSER_SRCS)
else
BUILD_DIR = $(release_BUILD_DIR)
BUILD_HTML = $(release_BUILD_HTML)
BROWSER_SRCS = $(release_BROWSER_SRCS)
endif
BROWSER_COFFEE = $(shell echo $(BROWSER_SRCS) | fmt -1 | grep '.coffee')

################################################################################
# TARGETS
################################################################################
# Protect non-file-based targets from not functioning if a file with the
# target's name is present.
.PHONY: release benchmark dist dependencies java test clean docs build dev development

# Builds a release or benchmark version of Doppio without the documentation.
# These targets differ in the variables that are set before they are run; see
# MAKECMDGOALS above.
release: build $(BUILD_DIR)/browser/listings.json
benchmark: build $(BUILD_DIR)/browser/listings.json
dev development: $(DEMO_CLASSES) browser/mini-rt.tar browser/listings.json
	$(COFFEEC) -c $(BROWSER_COFFEE)
	cpp -P browser/index.html index.html
# optimized CLI build
opt: $(CLI_SRCS:.coffee=.js)
jsclean:
	rm -f $(CLI_SRCS:.coffee=.js)
# hack. overwriting .js means that we won't detect if we previously did an
# unoptimized compile.
%.js: %.coffee
	$(SED) -r "s/^( *)(debug|v?trace).*$$/\1\`\`/" $? | $(COFFEEC) --stdio --print > $@
	$(UGLIFYJS) --define RELEASE --define UNSAFE --no-mangle --unsafe --beautify --overwrite $@

# Builds a distributable version of Doppio.
dist: $(DIST_NAME)
$(DIST_NAME): release docs
	tar czf $(DIST_NAME) $(release_BUILD_DIR)

# Installs or checks for any required dependencies.
dependencies: $(COFFEEC) $(UGLIFYJS) $(OPTIMIST) $(JAZZLIB) $(JRE) $(DOCCO) $(ADMZIP)
	git submodule update --init --recursive
$(COFFEEC):
	npm install coffee-script@1.3.3
$(UGLIFYJS):
	npm install uglify-js
$(OPTIMIST):
	npm install optimist
$(DOCCO):
	npm install docco
$(ADMZIP):
	npm install adm-zip
$(JAZZLIB):
	$(error JazzLib not found. Unzip it to vendor/classes/, or run ./tools/setup.sh.)
$(JRE):
	$(error Java class library not found. Unzip it to vendor/classes/, or run ./tools/setup.sh.)

# Used to test the chosen Java compiler in setup.sh.
java: $(CLASSES) $(DISASMS) $(RUNOUTS) $(DEMO_CLASSES)

# Runs the Java tests in classes/test with the node runner.
test: dependencies $(RESULTS)
	cat $(RESULTS)
	@rm -f $(RESULTS)
# compiling each one by itself is really inefficient...
%.class: %.java
	javac $^
classes/test/%.result: classes/test/%.class classes/test/%.disasm classes/test/%.runout
	tools/run_one_test.rb classes/test/$* >classes/test/$*.result
classes/test/%.disasm: classes/test/%.class
	javap -c -verbose -private classes/test/$* >classes/test/$*.disasm
# some tests may throw exceptions. The '-' flag tells make to carry on anyway.
classes/test/%.runout: classes/test/%.class
	-java classes/test/$* &>classes/test/$*.runout

clean:
	@rm -f $(CLASSES) $(DISASMS) $(RUNOUTS) $(RESULTS)
	@rm -f src/*.js browser/*.js console/*.js tools/*.js
	@rm -rf build/* browser/mini-rt.tar $(DEMO_CLASSES)
	@rm -f index.html

# docs need to be generated in one shot so docco can create the full jumplist.
# This is slow, so we have it as a separate target (even though it is needed
# for a full release build).
docs: dependencies $(release_BUILD_DIR)
	$(DOCCO) $(filter %.coffee, $(release_BROWSER_SRCS))
	rm -rf $(release_BUILD_DIR)/docs
	mv docs $(release_BUILD_DIR)

browser/mini-rt.tar: tools/preload
	COPYFILE_DISABLE=true && tar -c -T tools/preload -f $@

################################################################################
# BUILD DIRECTORY TARGETS
################################################################################
# Double colon: Can execute multiple times in one `make' invocation.
$(BUILD_DIR) $(BUILD_DIR)/browser::
	mkdir -p $@

browser/listings.json:
	$(COFFEEC) tools/gen_dir_listings.coffee > browser/listings.json
$(BUILD_DIR)/browser/listings.json:
	cd $(BUILD_DIR); $(COFFEEC) $(DOPPIO_DIR)/tools/gen_dir_listings.coffee > browser/listings.json

browser/_about.html: browser/_about.md
	rdiscount $? > $@
browser/about.html: browser/_about.html

$(BUILD_DIR)/%.html: $(BROWSER_HTML) $(wildcard browser/_*.html)
	cpp -P -traditional-cpp -DRELEASE browser/$*.html $@

$(BUILD_DIR)/compressed.js: $(BROWSER_SRCS)
	for src in $(BROWSER_SRCS); do \
		if [ "$${src##*.}" == "coffee" ]; then \
			$(: `` is essentially Coffeescript's equivalent of Python's 'pass') \
			$(SED) -r "s/^( *)(debug|v?trace).*$$/\1\`\`/" $${src} | $(COFFEEC) --stdio --print; \
		else \
			cat $${src}; \
		fi; \
		echo ";"; \
	done | $(UGLIFYJS) --define RELEASE --define UNSAFE --no-mangle --unsafe > $@

$(BUILD_DIR)/ace.js: $(ACE_SRCS)
	for src in $(ACE_SRCS); do \
		cat $${src}; \
		echo ";"; \
	done > $@

# The | prevents the rule from being included in $^.
$(BUILD_DIR)/browser/style.css: vendor/bootstrap/css/bootstrap.min.css \
	browser/style.css | $(BUILD_DIR)/browser
	cat $^ > $@

build: dependencies $(BUILD_DIR) $(BUILD_DIR)/browser $(BUILD_HTML) \
	$(BUILD_DIR)/compressed.js browser/mini-rt.tar $(BUILD_DIR)/ace.js \
	$(BUILD_DIR)/browser/style.css $(DEMO_CLASSES)
	rsync -R $(DEMO_SRCS) $(DEMO_CLASSES) $(BUILD_DIR)/
	rsync browser/*.svg $(BUILD_DIR)/browser/
	rsync browser/*.png $(BUILD_DIR)/browser/
	rsync browser/mini-rt.tar $(BUILD_DIR)/browser/mini-rt.tar
	ln -sfn $(DOPPIO_DIR)/vendor $(BUILD_DIR)/vendor

# Never delete these files in the event of a failure.
.SECONDARY: $(CLASSES) $(DISASMS) $(RUNOUTS) $(DEMO_CLASSES)
