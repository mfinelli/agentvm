[private]
default:
    @just --list

fmt:
    prettier -w *.md
    shfmt -s -i 2 -ci -sr -w *.bash
    just --fmt
