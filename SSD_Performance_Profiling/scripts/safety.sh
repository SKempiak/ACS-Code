#!/usr/bin/env bash
# safety.sh — refuse to benchmark anything that could hold valuable data.
#
# TODO: before any FIO run, check that the target is a dedicated empty partition, a raw
# device reserved for testing, or a disposable file in a dedicated directory; that nothing
# on a raw target is mounted; and that there is enough free space. Stop otherwise.
