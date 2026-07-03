.PHONY: check compile test clean

check: compile test clean

compile:
	emacs -Q --batch -L . -f batch-byte-compile netease-radio.el

test:
	emacs -Q --batch -L . -l ert -l netease-radio -l netease-radio-test \
		-f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc
