NODE ?= node
PYTHON ?= python3

.PHONY: test browser-test integration-test

test:
	$(NODE) --test tests/*.test.js
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s native -p 'test_*.py'

browser-test:
	$(NODE) tests/run-browser-test.mjs

integration-test:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) native/live_stream_check.py
