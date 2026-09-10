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

@test "btrfs: root mapping mounted at MANY targets (multiline) is left open" {
    # Regression (CRITICAL): on a btrfs-subvolume root the SAME mapping is mounted
    # at /, /home, /.snapshots… so `findmnt --source` returns MULTIPLE lines. The
    # old `[[ "$mp" == "/" ]]` test failed (mp != "/") → the guard was bypassed and
    # the live root was force-removed BEFORE luksErase → data recoverable.
    export STUB_DMSETUP_CRYPT=$'root\t(254:0)'
    findmnt() {
        case "$*" in
            *"--source"*"/dev/mapper/root"*) printf '/\n/home\n/.snapshots\n' ;;
            *SOURCE*)                        printf '/dev/mapper/root\n' ;;
        esac
    }
    run close_all_crypt_mappings
    assert_ok
    run grep -E '^dmsetup\b.*remove --force root' "$DURESSD_STUB_LOG"
    assert_fail   # multiline "/" still recognised → NOT removed
}

@test "LVM/stacked: crypt device not mounted but an ancestor of / is left open" {
    # Regression (CRITICAL): on LVM-on-LUKS the LV (not the crypt device) is mounted
    # at /, so `findmnt --source <crypt>` is EMPTY. The old guard saw mp="" != "/"
    # and force-removed the crypt device backing the live root. The new guard checks
    # root's ancestry chain (lsblk -nso NAME) and leaves an ancestor open.
    export STUB_DMSETUP_CRYPT=$'cryptlvm\t(254:0)'
    export STUB_LSBLK_NAME=$'vg-root\ncryptlvm\nsda2\nsda'   # lsblk -nso NAME → ancestry
    findmnt() {
        case "$*" in
            *"--source"*"/dev/mapper/cryptlvm"*) printf '' ;;                 # not mounted
            *SOURCE*)                            printf '/dev/mapper/vg-root\n' ;;
        esac
    }
    run close_all_crypt_mappings
    assert_ok
    run grep -E '^dmsetup\b.*remove --force cryptlvm' "$DURESSD_STUB_LOG"
    assert_fail   # crypt device is a root ancestor → NOT removed
}

@test "reorder: luksErase runs BEFORE any dm-crypt mapping teardown" {
    # Regression (CRITICAL): phase1 must destroy the header FIRST, then close
    # mappings — so a teardown that would error-target the live root can never
    # pre-empt the one step that makes data irrecoverable.
    export STUB_LUKS_DEVICES="/dev/sda2"
    export STUB_LSBLK_NAME="/dev/sda2"
    export STUB_DMSETUP_CRYPT=$'data\t(254:5)'   # a non-root crypt mapping to close
    findmnt() { case "$*" in *"--source"*) printf '/mnt/data\n' ;; *SOURCE*) printf '' ;; esac; }
    run phase1_crypto_destruction "/dev/sda2"
    assert_ok
    # Log format is "<name><TAB><args>", so match on the distinctive arg tokens.
    local le dr
    le=$(grep -n 'luksErase'     "$DURESSD_STUB_LOG" | head -1 | cut -d: -f1)
    dr=$(grep -n 'remove --force' "$DURESSD_STUB_LOG" | head -1 | cut -d: -f1)
    [ -n "$le" ] && [ -n "$dr" ] && [ "$le" -lt "$dr" ]
}
