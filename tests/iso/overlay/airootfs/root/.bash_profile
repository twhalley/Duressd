# duressd test ISO — run the self-test once on autologin, then drop to a shell.
[[ $- == *i* ]] && command -v duressd-selftest >/dev/null 2>&1 && duressd-selftest
