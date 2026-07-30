# Bash customizations used only by terminals running inside cmux.
# This file is sourced at the end of ~/.bashrc.

case $- in
    *i*) ;;
      *) return ;;
esac

[ -n "${CMUX_WORKSPACE_ID:-}" ] || return

# A nested Bash inherits PROMPT_COMMAND hook names from its parent, but not
# their function definitions. Remove only missing cmux/Ghostty hooks, then
# reinstall the affected integration after the user's prompt has been set.
_cmux_remove_stale_prompt_hook() {
    local _cmux_hook="$1"
    local _cmux_pc="${PROMPT_COMMAND:-}"

    if [ "$_cmux_pc" = "$_cmux_hook" ]; then
        PROMPT_COMMAND=
        return
    fi

    _cmux_pc="${_cmux_pc//;"$_cmux_hook";/;}"
    _cmux_pc="${_cmux_pc/#"$_cmux_hook";/}"
    _cmux_pc="${_cmux_pc/%;"$_cmux_hook"/}"
    _cmux_pc="${_cmux_pc//$'\n'"$_cmux_hook"$'\n'/$'\n'}"
    _cmux_pc="${_cmux_pc/#"$_cmux_hook"$'\n'/}"
    _cmux_pc="${_cmux_pc/%$'\n'"$_cmux_hook"/}"
    PROMPT_COMMAND="$_cmux_pc"
}

if [[ "${PROMPT_COMMAND:-}" != *"__cmux_bash_bootstrap_marker__"* ]]; then
    if [[ "${PROMPT_COMMAND:-}" == *"_cmux_prompt_command"* ]] &&
       ! declare -F _cmux_prompt_command >/dev/null 2>&1; then
        _cmux_remove_stale_prompt_hook "_cmux_prompt_command"
        _CMUX_REINSTALL_BASH_INTEGRATION=1
    fi

    if { [[ "${PROMPT_COMMAND:-}" == *"__bp_precmd_invoke_cmd"* ]] ||
         [[ "${PROMPT_COMMAND:-}" == *"__bp_interactive_mode"* ]]; } &&
       ! declare -F __bp_precmd_invoke_cmd >/dev/null 2>&1; then
        _cmux_remove_stale_prompt_hook "__bp_precmd_invoke_cmd"
        _cmux_remove_stale_prompt_hook "__bp_interactive_mode"
        _CMUX_REINSTALL_GHOSTTY_BASH_INTEGRATION=1
    fi

    if [[ "${PROMPT_COMMAND:-}" == *"__bp_install"* ]] &&
       ! declare -F __bp_install >/dev/null 2>&1; then
        _cmux_remove_stale_prompt_hook '__bp_trap_string="$(trap -p DEBUG)"'
        _cmux_remove_stale_prompt_hook "trap - DEBUG"
        _cmux_remove_stale_prompt_hook "__bp_install"
        _CMUX_REINSTALL_GHOSTTY_BASH_INTEGRATION=1
    fi
fi
unset -f _cmux_remove_stale_prompt_hook

# Preserve all unrelated Ghostty features while disabling its title and cursor
# prompt changes. cmux receives a basename-only title below and uses a block
# cursor, while shells in Kitty and other terminals remain untouched.
_cmux_ghostty_features=",${GHOSTTY_SHELL_FEATURES:-},"
_cmux_ghostty_features="${_cmux_ghostty_features/,title,/,}"
_cmux_ghostty_features="${_cmux_ghostty_features/,no-title,/,}"
_cmux_ghostty_features="${_cmux_ghostty_features/,cursor,/,}"
_cmux_ghostty_features="${_cmux_ghostty_features/,no-cursor,/,}"
_cmux_ghostty_features="${_cmux_ghostty_features#,}"
_cmux_ghostty_features="${_cmux_ghostty_features%,}"
if [ -n "$_cmux_ghostty_features" ]; then
    GHOSTTY_SHELL_FEATURES="${_cmux_ghostty_features},no-title,no-cursor"
else
    GHOSTTY_SHELL_FEATURES="no-title,no-cursor"
fi
export GHOSTTY_SHELL_FEATURES
unset _cmux_ghostty_features

# DECSCUSR 2 selects a steady block, including in already-open panes.
printf '\e[2 q'

# Publish only the current directory basename as the terminal-tab title.
case "$PS1" in
    *'\[\e]0;\W\a\]'*) ;;
    *) PS1="\[\e]0;\W\a\]$PS1" ;;
esac
export PS1

if [ "${_CMUX_REINSTALL_GHOSTTY_BASH_INTEGRATION:-0}" = "1" ]; then
    _cmux_ghostty_bash="${GHOSTTY_RESOURCES_DIR:-}/shell-integration/bash/ghostty.bash"
    [ -r "$_cmux_ghostty_bash" ] && source "$_cmux_ghostty_bash"
fi
if [ "${_CMUX_REINSTALL_BASH_INTEGRATION:-0}" = "1" ]; then
    _cmux_bash_integration="${CMUX_SHELL_INTEGRATION_DIR:-}/cmux-bash-integration.bash"
    [ -r "$_cmux_bash_integration" ] && source "$_cmux_bash_integration"
fi

unset _CMUX_REINSTALL_GHOSTTY_BASH_INTEGRATION
unset _CMUX_REINSTALL_BASH_INTEGRATION
unset _cmux_ghostty_bash
unset _cmux_bash_integration
