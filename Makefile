.PHONY: build static test smoke clean run guide install

build:
	./build.sh

static:
	STATIC=1 ./build.sh

test: build
	./test.sh

smoke: test

run: build
	CUZZ_DB=$${CUZZ_DB:-./cuzz.data} ./cuzz serve --port $${PORT:-7700}

guide: build
	./cuzz guide

install: static
	install -m 0755 cuzz $${PREFIX:-$$HOME/bin}/cuzz
	@echo "installed $${PREFIX:-$$HOME/bin}/cuzz"

clean:
	rm -f cuzz cuzz.mfl
	rm -rf cuzz.data
