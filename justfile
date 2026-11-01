[private]
default:
    @just --list

check:
    just --fmt --check
    prettier -c .
    shfmt -s -i 2 -ci -sr -d *.bash
    shellcheck *.bash
    actionlint

fmt:
    prettier -w .
    shfmt -s -i 2 -ci -sr -w *.bash
    just --fmt
