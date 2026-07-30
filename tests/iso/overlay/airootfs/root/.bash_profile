# duressd test ISO — the self-test runs as a systemd service (duressd-selftest),
# not from here, so the interactive shell is never blocked. This is just a tip.
if [[ $- == *i* ]]; then
    echo "duressd is installed & running. Try: duressd status | health | dry-run | test"
    echo "Self-test log: journalctl -u duressd-selftest    Re-run: duressd-selftest --force"
fi
