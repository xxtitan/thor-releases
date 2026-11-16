#!/bin/sh
# thor 一键安装脚本（macOS / Linux）。
#
#   curl -fsSL https://raw.githubusercontent.com/xxtitan/thor-releases/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/xxtitan/thor-releases/main/install.sh | sh -s -- --service
#
# 从 GitHub Release 下载当前平台的 thor 并校验 SHA-256，直连 GitHub 失败时改经 gh-proxy.com 下载。
# 默认安装到执行用户（经 sudo 执行时为调用 sudo 的用户）的 ~/.local/bin，以 root 登录执行时安装到 /usr/local/bin。
# --service 把 thor web serve 安装为自启服务：Linux 为 systemd 系统服务，macOS 为登录后启动的 launchd 代理。
# 重复执行即升级到最新版本，并重启已安装的服务。
set -eu

REPO="xxtitan/thor-releases"
MIRROR="https://gh-proxy.com/"
SYSTEMD_UNIT="/etc/systemd/system/thor.service"
LAUNCHD_LABEL="com.xxtitan.thor"

channel="stable"
install_dir=""
service=false
listen="127.0.0.1:7998"
uninstall=false
tmp=""

usage() {
	cat <<EOF
用法: install.sh [选项]

  --channel <stable|nightly>  发布通道（默认 stable）
  --dir <目录>                安装目录（默认 ~/.local/bin；以 root 登录执行时为 /usr/local/bin）
  --service                   安装为自启服务，运行 thor web serve
  --listen <地址>             自启服务的管理中心监听地址（默认 127.0.0.1:7998）
  --uninstall                 卸载 thor 与自启服务，保留数据目录
  -h, --help                  显示帮助
EOF
}

log() {
	printf '==> %s\n' "$*" >&2
}

die() {
	printf '错误: %s\n' "$*" >&2
	exit 1
}

has() {
	command -v "$1" >/dev/null 2>&1
}

# as_root 以 root 身份执行命令：当前已是 root 时直接执行，否则经 sudo。
as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif has sudo; then
		sudo "$@"
	else
		die "需要 root 权限执行 $*，但未找到 sudo"
	fi
}

# in_dir 在安装目录内执行命令：用户目录内以该用户身份执行，让文件归属该用户、thor 可以自行更新；
# 其他目录不可写时以 root 身份执行。
in_dir() {
	case "$install_dir/" in
	"$home"/*) as_user "$@" ;;
	*)
		if [ -w "$install_dir" ]; then
			"$@"
		else
			as_root "$@"
		fi
		;;
	esac
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--channel | --dir | --listen)
			[ $# -ge 2 ] || die "$1 需要一个参数"
			case "$1" in
			--channel) channel="$2" ;;
			--dir) install_dir="$2" ;;
			--listen) listen="$2" ;;
			esac
			shift 2
			;;
		--service) service=true && shift ;;
		--uninstall) uninstall=true && shift ;;
		-h | --help) usage && exit 0 ;;
		*) usage >&2 && die "未知选项 $1" ;;
		esac
	done
	case "$channel" in
	stable | nightly) ;;
	*) die "未知的发布通道 ${channel}，可选 stable、nightly" ;;
	esac
}

detect_platform() {
	case "$(uname -s)" in
	Linux) os=linux ;;
	Darwin) os=darwin ;;
	*) die "不支持的系统 $(uname -s)；Windows 请使用 install.ps1" ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	armv7* | armv8l) arch=arm ;;
	*) die "不支持的架构 $(uname -m)" ;;
	esac
	# Rosetta 转译下运行的 shell 报告 x86_64，Apple 芯片应使用 arm64 版本。
	if [ "$os" = darwin ] && [ "$arch" = amd64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
		arch=arm64
	fi
}

# service_user 是安装与自启服务所属的用户：经 sudo 执行时为调用 sudo 的用户。
service_user() {
	if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
		printf '%s\n' "$SUDO_USER"
	else
		id -un
	fi
}

user_home() {
	eval "printf '%s\n' ~$1"
}

# resolve_user 确定所属用户及其主目录，并据此确定默认安装目录。
resolve_user() {
	user=$(service_user)
	home=$(user_home "$user")
	if [ -z "$install_dir" ]; then
		if [ "$user" = root ]; then
			install_dir="/usr/local/bin"
		else
			install_dir="$home/.local/bin"
		fi
	fi
}

release_url() {
	if [ "$channel" = stable ]; then
		printf 'https://github.com/%s/releases/latest/download/%s\n' "$REPO" "$1"
	else
		printf 'https://github.com/%s/releases/download/nightly/%s\n' "$REPO" "$1"
	fi
}

fetch() {
	if has curl; then
		curl -fsSL --connect-timeout 10 --speed-limit 1024 --speed-time 30 -o "$2" "$1"
	elif has wget; then
		wget -q -T 30 -O "$2" "$1"
	else
		die "需要 curl 或 wget"
	fi
}

# download 下载 Release 中的文件：先直连 GitHub，失败后经 gh-proxy.com。
download() {
	url=$(release_url "$1")
	if fetch "$url" "$2"; then
		return
	fi
	log "直连 GitHub 失败，改经 ${MIRROR} 下载 $1"
	fetch "${MIRROR}${url}" "$2" || die "下载 $1 失败"
}

sha256_of() {
	if has sha256sum; then
		sha256sum "$1" | awk '{print $1}'
	elif has shasum; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		die "需要 sha256sum 或 shasum 校验下载的文件"
	fi
}

install_binary() {
	asset="thor-$os-$arch"
	log "下载 $channel 通道的 $asset"
	download checksums.txt "$tmp/checksums.txt"
	download "$asset" "$tmp/thor"

	expected=$(awk -v name="$asset" '$2 == name {print $1}' "$tmp/checksums.txt")
	[ -n "$expected" ] || die "checksums.txt 中没有 $asset"
	actual=$(sha256_of "$tmp/thor")
	[ "$actual" = "$expected" ] || die "$asset 校验失败：SHA-256 为 ${actual}，应为 $expected"
	chmod 0755 "$tmp/thor"

	in_dir mkdir -p "$install_dir"
	# 先复制到同一目录再重命名，替换正在运行的 thor 也不受影响。
	in_dir cp "$tmp/thor" "$install_dir/.thor.new"
	in_dir mv -f "$install_dir/.thor.new" "$install_dir/thor"
	log "已安装 $("$install_dir/thor" --version)"
}

systemd_unit() {
	cat <<EOF
[Unit]
Description=thor 管理中心
Wants=network-online.target
After=network-online.target

[Service]
User=$1
ExecStart=$install_dir/thor web serve --listen $listen
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

install_systemd() {
	if ! has systemctl || [ ! -d /run/systemd/system ]; then
		die "未检测到 systemd，无法安装自启服务；可直接运行 $install_dir/thor web serve"
	fi
	systemd_unit "$user" >"$tmp/thor.service"
	as_root cp "$tmp/thor.service" "$SYSTEMD_UNIT"
	as_root chmod 0644 "$SYSTEMD_UNIT"
	as_root systemctl daemon-reload
	as_root systemctl enable thor.service
	as_root systemctl restart thor.service
	log "已安装 systemd 服务 thor（运行用户 ${user}），查看日志: journalctl -u thor -f"
}

launchd_plist() {
	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LAUNCHD_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$install_dir/thor</string>
		<string>web</string>
		<string>serve</string>
		<string>--listen</string>
		<string>$listen</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>StandardOutPath</key>
	<string>$1</string>
	<key>StandardErrorPath</key>
	<string>$1</string>
</dict>
</plist>
EOF
}

# as_user 以所属用户的身份执行命令。
as_user() {
	if [ "$(id -un)" = "$user" ]; then
		"$@"
	else
		as_root sudo -u "$user" "$@"
	fi
}

launchd_paths() {
	uid=$(id -u "$user")
	plist="$home/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
	log_file="$home/Library/Logs/thor.log"
}

# launchd_unload 卸载已加载的 launchd 代理，并等到它完全退出：bootout 是异步的，
# 此时立即 bootstrap 同一个标签会失败。
launchd_unload() {
	launchctl bootout "gui/$uid/$LAUNCHD_LABEL" 2>/dev/null || true
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		launchctl print "gui/$uid/$LAUNCHD_LABEL" >/dev/null 2>&1 || return 0
		sleep 0.5
	done
	die "等待 launchd 代理 $LAUNCHD_LABEL 退出超时"
}

install_launchd() {
	launchd_paths
	launchd_plist "$log_file" >"$tmp/thor.plist"
	as_user mkdir -p "$home/Library/LaunchAgents" "$home/Library/Logs"
	as_user cp "$tmp/thor.plist" "$plist"
	launchd_unload
	launchctl bootstrap "gui/$uid" "$plist"
	log "已安装 launchd 代理 ${LAUNCHD_LABEL}（运行用户 ${user}，登录后自动启动），日志: $log_file"
}

install_service() {
	case "$os" in
	linux) install_systemd ;;
	darwin) install_launchd ;;
	esac
	log "管理中心: http://$listen"
}

# restart_service 让已安装的自启服务改用新安装的 thor。
restart_service() {
	case "$os" in
	linux)
		if [ -f "$SYSTEMD_UNIT" ]; then
			as_root systemctl restart thor.service
			log "已重启 systemd 服务 thor"
		fi
		;;
	darwin)
		launchd_paths
		if [ -f "$plist" ]; then
			launchctl kickstart -k "gui/$uid/$LAUNCHD_LABEL"
			log "已重启 launchd 代理 $LAUNCHD_LABEL"
		fi
		;;
	esac
}

uninstall_all() {
	case "$os" in
	linux)
		if [ -f "$SYSTEMD_UNIT" ]; then
			as_root systemctl disable --now thor.service
			as_root rm -f "$SYSTEMD_UNIT"
			as_root systemctl daemon-reload
			log "已移除 systemd 服务 thor"
		fi
		;;
	darwin)
		launchd_paths
		if [ -f "$plist" ]; then
			launchd_unload
			as_user rm -f "$plist"
			log "已移除 launchd 代理 $LAUNCHD_LABEL"
		fi
		;;
	esac
	if [ -e "$install_dir/thor" ]; then
		in_dir rm -f "$install_dir/thor"
		log "已删除 $install_dir/thor"
	fi
	log "数据目录 ~/.config/thor 已保留，不再需要时可手动删除"
}

path_hint() {
	case ":$PATH:" in
	*":$install_dir:"*) ;;
	*) log "$install_dir 不在 PATH 中，请在 shell 配置文件（如 ~/.zshrc、~/.bashrc）中加入: export PATH=\"$install_dir:\$PATH\"" ;;
	esac
}

main() {
	parse_args "$@"
	detect_platform
	resolve_user
	if [ "$uninstall" = true ]; then
		uninstall_all
		return
	fi

	# 经 sudo 执行时以所属用户身份复制下载的文件，临时目录需对其可读。
	tmp=$(mktemp -d)
	chmod 0755 "$tmp"
	trap 'rm -rf "$tmp"' EXIT
	install_binary
	if [ "$service" = true ]; then
		install_service
	else
		restart_service
	fi
	path_hint
}

main "$@"
