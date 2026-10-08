#!/bin/sh
# Enable root SSH password login on Debian/Ubuntu and Alpine.
set -eu
[ "$(id -u)" = 0 ] || { echo '请使用 root 执行。' >&2; exit 1; }
[ -r /etc/os-release ] || { echo '无法识别操作系统。' >&2; exit 1; }
. /etc/os-release
case "$ID" in debian|ubuntu|alpine) :;; *) echo '仅支持 Debian、Ubuntu、Alpine。' >&2; exit 1;; esac
CONFIG=/etc/ssh/sshd_config
[ -f "$CONFIG" ] || { echo '尚未安装 SSH 服务。' >&2; exit 1; }
SSHD=$(command -v sshd || true)
[ -n "$SSHD" ] || { echo '找不到 sshd。' >&2; exit 1; }
if [ "$ID" = alpine ]; then
    command -v rc-service >/dev/null || exit 1
    reload_ssh() { rc-service sshd reload; }
else
    if systemctl cat ssh.service >/dev/null 2>&1; then SSH_UNIT=ssh;
    elif systemctl cat sshd.service >/dev/null 2>&1; then SSH_UNIT=sshd;
    else echo '找不到 SSH systemd 服务。' >&2; exit 1; fi
    reload_ssh() { systemctl reload "$SSH_UNIT"; }
fi
printf '系统：%s\n将启用 root SSH 密码登录。保留当前连接，新开窗口测试登录。\n' "${PRETTY_NAME:-$ID}"
printf '继续？输入 y 确认，其他输入取消：'
IFS= read -r answer </dev/tty || exit 1
case "$answer" in y|Y|yes|YES) :;; *) echo '已取消。'; exit 0;; esac
"$SSHD" -t
BACKUP=$(mktemp /etc/ssh/sshd_config.backup.XXXXXX)
cp -p "$CONFIG" "$BACKUP"
TEMP=$(mktemp /etc/ssh/.sshd_config.XXXXXX)
cleanup() { rm -f "$TEMP"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Prepend global settings; keep Includes and Match sections intact.
{
    printf '# VPSKit root password login\nPermitRootLogin yes\nPasswordAuthentication yes\n'
    awk 'NR==1 && $0=="# VPSKit root password login" {skip=2;next} skip>0 {skip--;next} {print}' "$CONFIG"
} > "$TEMP"
chmod 600 "$TEMP"
"$SSHD" -t -f "$TEMP"
EFFECTIVE=$("$SSHD" -T -f "$TEMP")
printf '%s\n' "$EFFECTIVE" | grep -qx 'permitrootlogin yes'
printf '%s\n' "$EFFECTIVE" | grep -qx 'passwordauthentication yes'
printf '\n请设置新的 root 密码（输入时不显示）：\n'
passwd root </dev/tty || { echo '密码设置失败，SSH 配置未修改。' >&2; exit 1; }
rollback() {
    cp -p "$BACKUP" "$CONFIG"
    reload_ssh || true
    echo "SSH 配置已恢复。root 密码已修改，不会回滚。备份：$BACKUP" >&2
}
# Preserve existing ownership and permissions.
if ! cat "$TEMP" > "$CONFIG"; then rollback; exit 1; fi
if ! "$SSHD" -t || ! reload_ssh; then rollback; exit 1; fi
printf '\n配置已检查，SSH 已重载。备份：%s\n' "$BACKUP"
printf '请新开 SSH 窗口，使用 root 和新密码测试登录。\n'
printf '若仍被拒绝，检查 Match、AllowUsers、AuthenticationMethods 或服务商限制。\n'
