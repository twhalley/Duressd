#!/usr/bin/env bats
# Unit test for close_all_crypt_mappings' RUNNING-ROOT guard (handler ~195): the
# dm-crypt mapping backing "/" must be left OPEN until poweroff. If it were torn
# down mid-wipe, / breaks and the later phases + poweroff never run — a committed
# wipe would strand the machine. Off-root mappings must still be closed.

load '../lib/common'

setup() { setup_stubs; load_handler; }
teardown() { teardown_stubs; }

@test "the mapping mounted at / is NOT removed; an off-root mapping IS" {
    # dmsetup ls --target crypt → two mappings (name <TAB> dev).
    export STUB_DMSETUP_CRYPT=$'root\t(254:0)\nhome\t(254:1)'
    # Per-mapping mountpoint (the real findmnt takes a single value; override it).
    findmnt() {
        case "$*" in
            *"/dev/mapper/root"*) printf '/\n' ;;
            *"/dev/mapper/home"*) printf '/home\n' ;;
        esac
    }
    run close_all_crypt_mappings
    assert_ok
    # off-root: closed
    stub_called_with dmsetup "remove --force home"
    # running root: left open
    run grep -E '^dmsetup\b.*remove --force root' "$DURESSD_STUB_LOG"
    assert_fail
}
