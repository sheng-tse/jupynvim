# shellcheck shell=bash
# jnv_vkitty_python: print the path of the first python3 that can run the
# headless Kitty graphics harness (tests/lib/vkitty). That needs numpy,
# fontTools and Pillow built with raqm (for shaped text). Sourced, never
# executed, and safe under `set -u`.
#
#   source "$ROOT/tests/lib/vkitty/python.sh"
#   PY="$(jnv_vkitty_python)" || exit 1
#
# Candidates, in order, each taken once: $JUPYNVIM_TEST_VKITTY_PYTHON,
# $JNV_KERNEL_PYTHON, then every python3 on PATH (type -a -P). A candidate
# passes when it imports the three modules and Pillow reports raqm. The probe
# runs from / with -I, so nothing next to the repo or in the caller's
# environment can change what it finds. Requirements: tests/lib/vkitty/requirements.txt.
jnv_vkitty_python() {
  local _jnv_vk_probe='import numpy, fontTools; from PIL import features; import sys; sys.exit(0 if features.check("raqm") else 1)'
  local _jnv_vk_seen=" "
  local _jnv_vk_list=""
  local _jnv_vk_c=""
  local _jnv_vk_path=""

  _jnv_vk_list="${JUPYNVIM_TEST_VKITTY_PYTHON:-}"$'\n'"${JNV_KERNEL_PYTHON:-}"$'\n'
  _jnv_vk_list="${_jnv_vk_list}$(type -a -P python3 2>/dev/null)"

  while IFS= read -r _jnv_vk_c; do
    [ -n "$_jnv_vk_c" ] || continue
    case "$_jnv_vk_seen" in
      *" $_jnv_vk_c "*) continue ;;
    esac
    _jnv_vk_seen="${_jnv_vk_seen}${_jnv_vk_c} "
    # A candidate given by name (not a path) is looked up on PATH first.
    _jnv_vk_path="$_jnv_vk_c"
    case "$_jnv_vk_c" in
      */*) ;;
      *) _jnv_vk_path="$(type -P "$_jnv_vk_c" 2>/dev/null || true)" ;;
    esac
    [ -n "$_jnv_vk_path" ] && [ -x "$_jnv_vk_path" ] || continue
    if (cd / && "$_jnv_vk_path" -I -c "$_jnv_vk_probe") >/dev/null 2>&1; then
      printf '%s\n' "$_jnv_vk_path"
      return 0
    fi
  done <<EOF_CANDIDATES
$_jnv_vk_list
EOF_CANDIDATES

  printf '%s\n' "vkitty: no python3 with numpy, Pillow (raqm) and fontTools; see tests/lib/vkitty/requirements.txt" >&2
  return 1
}
