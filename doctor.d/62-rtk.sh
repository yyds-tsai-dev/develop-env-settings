# rtk and ccusage checks (every role). Protocol: see bin/doctor.

# _rtk_hint SCRIPT: the command that reinstalls what SCRIPT installs: DOCTOR_FIX
# when it failed and left a retry marker, DOCTOR_FORCE when it succeeded earlier
# and its binary went missing later (apply alone never reruns it).
_rtk_hint() {
  if [ -e "$HOME/.local/state/develop-env/retry/$1" ]; then echo "$DOCTOR_FIX"; else echo "$DOCTOR_FORCE"; fi
}

# FAIL: rtk missing or not at the locked version. WARN: `rtk init --show` does
# not report the Claude hook (`rtk hook claude` in ~/.claude/settings.json).
check_rtk() {
  local want have
  command -v rtk >/dev/null 2>&1 || { echo "rtk not on PATH: $(_rtk_hint 35-rtk)"; return 1; }
  want="$(sed -n "s/^  rtk: *'\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$DOCTOR_ROOT/home/.chezmoidata/versions.yaml")"
  have="$(rtk --version 2>/dev/null)"
  if [ -n "$want" ] && [ "$have" != "rtk $want" ]; then
    echo "rtk is ${have:-unknown}, the Version lock wants $want: $(_rtk_hint 35-rtk)"; return 1
  fi
  rtk init --show 2>/dev/null | grep -q '^\[ok\] Hook:' && return 0
  echo "rtk init --show reports no Claude hook (rtk hook claude in ~/.claude/settings.json): $DOCTOR_FIX"; return 3
}
register check_rtk

# WARN (never FAIL): ccusage (usage reports) is not on PATH.
check_ccusage() {
  command -v ccusage >/dev/null 2>&1 && return 0
  echo "ccusage not on PATH: $(_rtk_hint 26-ccusage)"; return 3
}
register check_ccusage
