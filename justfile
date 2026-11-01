[private]
default:
    @just --list

check:
    prettier -c *.md
    shfmt -s -i 2 -ci -sr -d *.bash
    shellcheck *.bash

fmt:
    prettier -w *.md
    shfmt -s -i 2 -ci -sr -w *.bash
    just --fmt
