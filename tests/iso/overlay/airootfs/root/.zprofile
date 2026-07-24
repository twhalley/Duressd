# duressd test ISO — run the self-test once on autologin, then drop to a shell.
# (archiso's root login shell is zsh; this covers it as well as bash.)
[[ -o interactive ]] && command -v duressd-selftest >/dev/null 2>&1 && duressd-selftest
