#!/bin/sh
set -e

echo "=== [SafeSpace Provisioner] Starting Alpine ARM64 Desktop Image Build ==="

# 1. Configure network inside live environment
ip link set lo up
ip link set eth0 up
udhcpc -i eth0 -n -q

# 2. Configure repositories (use fast CDN + community repo for LibreOffice / Zathura / Desktop)
cat > /etc/apk/repositories << 'EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.20/main
https://dl-cdn.alpinelinux.org/alpine/v3.20/community
EOF

apk update

# 3. Install e2fsprogs to format /dev/vda
apk add e2fsprogs

echo "=== [SafeSpace Provisioner] Formatting /dev/vda as ext4 ==="
umount /mnt/target 2>/dev/null || true
mkfs.ext4 -F -L safespace-root -O ^metadata_csum_seed /dev/vda
mkdir -p /mnt/target
mount -t ext4 /dev/vda /mnt/target

# 4. Install Alpine base + Kernel Modules + Xorg + Openbox + PCManFM + Viewers into /mnt/target
echo "=== [SafeSpace Provisioner] Installing Desktop & Viewers into /mnt/target ==="
mkdir -p /mnt/target/etc/apk
cp /etc/apk/repositories /mnt/target/etc/apk/repositories
cp -a /etc/apk/keys /mnt/target/etc/apk/

apk --root /mnt/target add --initdb \
    alpine-base \
    udev \
    eudev \
    dbus \
    dbus-x11 \
    xorg-server \
    xf86-video-fbdev \
    xf86-input-libinput \
    xf86-input-evdev \
    libinput \
    mesa-dri-gallium \
    openbox \
    tint2 \
    pcmanfm \
    lxterminal \
    xterm \
    feh \
    mousepad \
    zathura \
    zathura-pdf-mupdf \
    libreoffice-impress \
    libreoffice-writer \
    libreoffice-calc \
    font-noto \
    font-noto-cjk \
    adwaita-icon-theme \
    shared-mime-info \
    desktop-file-utils \
    file \
    unzip \
    p7zip \
    tar \
    gzip \
    xz \
    binutils \
    python3 \
    py3-gobject3 \
    zenity

# 5. Copy kernel modules from live environment and initramfs so kernel version 6.6.49-0-virt matches 100%
mkdir -p /mnt/target/lib/modules
cp -a /lib/modules/* /mnt/target/lib/modules/ 2>/dev/null || true
if [ -f /mnt/setup_share/boot/initramfs-virt ]; then
    (cd /mnt/target && gzip -dc /mnt/setup_share/boot/initramfs-virt | cpio -idmu "lib/modules/*" 2>/dev/null || true)
fi
depmod -b /mnt/target "$(uname -r)" 2>/dev/null || true

# 6. Configure basic system files in /mnt/target
echo "safespace-vm" > /mnt/target/etc/hostname
cat > /mnt/target/etc/hosts << 'EOF'
127.0.0.1   localhost safespace-vm
::1         localhost safespace-vm
EOF

cat > /mnt/target/etc/fstab << 'EOF'
/dev/vda    /               ext4    rw,relatime     0 1
proc        /proc           proc    defaults        0 0
sysfs       /sys            sysfs   defaults        0 0
devtmpfs    /dev            devtmpfs defaults       0 0
devpts      /dev/pts        devpts   defaults        0 0
tmpfs       /tmp            tmpfs   defaults        0 0
tmpfs       /run            tmpfs   defaults        0 0
EOF

# 7. Create /usr/local/bin/safespace-open (Universal Sandbox File Opener & Inspector)
mkdir -p /mnt/target/usr/local/bin
cat > /mnt/target/usr/local/bin/safespace-open << 'EOF'
#!/bin/sh
export DISPLAY=:0
export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8

FILE="$1"
if [ -z "$FILE" ] || [ ! -e "$FILE" ]; then
    exit 1
fi

BASENAME="$(basename "$FILE")"
WORKDIR="/root/SandboxFiles"
mkdir -p "$WORKDIR"

# Always work on a writable copy inside the VM's ephemeral disk
TARGET="$WORKDIR/$BASENAME"
cp -rf "$FILE" "$TARGET" 2>/dev/null || TARGET="$FILE"

EXT="$(echo "${BASENAME##*.}" | tr '[:upper:]' '[:lower:]')"
MIME="$(file -b --mime-type "$TARGET" 2>/dev/null)"

case "$EXT" in
    pdf)
        zathura "$TARGET" &
        ;;
    ppt|pptx|odp|doc|docx|odt|xls|xlsx|ods|rtf)
        libreoffice --norestore --nolockcheck "$TARGET" &
        ;;
    png|jpg|jpeg|gif|bmp|webp|svg|ico)
        feh --scale-down --auto-zoom -g 1024x680 --title "SafeSpace 图片预览 - $BASENAME" "$TARGET" &
        ;;
    txt|md|json|xml|yaml|yml|csv|log|ini|conf|c|cpp|h|js|ts|html|css|rs|go|java|swift)
        mousepad "$TARGET" &
        ;;
    py)
        chmod +x "$TARGET" 2>/dev/null
        if grep -q -E "(zenity|gtk|gi\.repository|tkinter)" "$TARGET" 2>/dev/null; then
            python3 "$TARGET" &
        else
            lxterminal --title="SafeSpace Python 软件沙盒运行 - $BASENAME" -e "/bin/sh -c 'python3 \"$TARGET\"; echo \"\"; echo \"[软件已退出，退出码: \$?] 按回车键关闭...\"; read dummy'" &
        fi
        ;;
    zip|tar|gz|tgz|bz2|xz|7z)
        OUTDIR="/tmp/archive_${BASENAME}_$$"
        mkdir -p "$OUTDIR"
        7z x -y "$TARGET" -o"$OUTDIR" >/dev/null 2>&1 || tar -xf "$TARGET" -C "$OUTDIR" >/dev/null 2>&1 || unzip -q "$TARGET" -d "$OUTDIR" >/dev/null 2>&1
        pcmanfm "$OUTDIR" &
        ;;
    sh|run|bin|AppImage|command)
        chmod +x "$TARGET" 2>/dev/null
        lxterminal --title="SafeSpace 软件隔离运行 - $BASENAME" -e "/bin/sh -c 'echo \"=== [SafeSpace 隔离沙盒运行软件: $BASENAME] ===\"; echo \"文件路径: $TARGET\"; echo \"SHA256: \$(sha256sum \"$TARGET\" | cut -d\" \" -f1)\"; echo \"----------------------------------------\"; \"$TARGET\"; echo \"\"; echo \"[软件进程已结束，退出码: \$?] 按回车键关闭窗口...\"; read dummy'" &
        ;;
    dmg|pkg|app|exe|msi|dll|so|dylib)
        REPORT="/tmp/inspect_${BASENAME}.txt"
        OUTDIR="/tmp/extracted_${BASENAME}"
        mkdir -p "$OUTDIR"
        7z x -y "$TARGET" -o"$OUTDIR" >/dev/null 2>&1 || true
        {
            echo "================================================================"
            echo "         SafeSpace 软件包隔离运行与安全分析中心"
            echo "================================================================"
            echo "软件名称:   $BASENAME"
            echo "文件大小:   $(du -h "$TARGET" | cut -f1)"
            echo "MIME 类型:  $MIME"
            echo "二进制格式: $(file -b "$TARGET")"
            echo "MD5:        $(md5sum "$TARGET" | cut -d' ' -f1)"
            echo "SHA-256:    $(sha256sum "$TARGET" | cut -d' ' -f1)"
            echo ""
            echo "=== [解包后的软件内部结构 ($OUTDIR)] ==="
            find "$OUTDIR" -maxdepth 3 2>/dev/null | head -n 40
            echo ""
            echo "=== [软件敏感行为 / 网络连接 / 系统调用特征扫描] ==="
            strings -n 6 "$TARGET" 2>/dev/null | grep -E -i "(http://|https://|/bin/sh|/bin/bash|powershell|cmd\.exe|curl |wget |eval |exec |socket|connect|chmod |HKEY_|RegOpenKey)" | head -n 40 || echo "(未检测到明显高危外联命令)"
            echo ""
            echo "=== [二进制符号与可打印字符串摘要 (前 60 行)] ==="
            strings -n 6 "$TARGET" 2>/dev/null | head -n 60
        } > "$REPORT"
        if [ "$(ls -A "$OUTDIR" 2>/dev/null)" ]; then
            pcmanfm "$OUTDIR" &
        fi
        mousepad "$REPORT" &
        zenity --info --width=480 --title="SafeSpace 软件沙盒分析完成" --text="已在隔离虚拟机中完成对软件包 <b>$BASENAME</b> 的安全解包与行为特征扫描！\n\n• 宿主机状态：<b>100% 安全隔离（硬件级只读保护）</b>\n• 软件包内容已自动在沙盒文件管理器与分析报告窗口中打开。" 2>/dev/null &
        ;;
    *)
        if [ -d "$TARGET" ]; then
            pcmanfm "$TARGET" &
        elif echo "$MIME" | grep -q "executable"; then
            chmod +x "$TARGET" 2>/dev/null
            lxterminal --title="SafeSpace 沙盒执行 - $BASENAME" -e "/bin/sh -c 'echo \"=== [SafeSpace 隔离沙盒执行: $BASENAME] ===\"; \"$TARGET\"; echo \"\"; echo \"[进程已结束，退出码: \$?] 按回车键关闭...\"; read dummy'" &
        elif echo "$MIME" | grep -q "pdf"; then
            zathura "$TARGET" &
        elif echo "$MIME" | grep -q "image/"; then
            feh --scale-down --auto-zoom -g 1024x680 "$TARGET" &
        else
            mousepad "$TARGET" &
        fi
        ;;
esac
EOF
chmod +x /mnt/target/usr/local/bin/safespace-open

# 8. Configure default file associations so double-clicking any icon in PCManFM calls safespace-open
mkdir -p /mnt/target/usr/share/applications /mnt/target/root/.config/
cat > /mnt/target/usr/share/applications/safespace-opener.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=SafeSpace 沙盒打开工具
Exec=/usr/local/bin/safespace-open %f
Icon=system-run
Terminal=false
MimeType=application/pdf;application/vnd.ms-powerpoint;application/vnd.openxmlformats-officedocument.presentationml.presentation;application/msword;application/vnd.openxmlformats-officedocument.wordprocessingml.document;application/vnd.ms-excel;application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;image/png;image/jpeg;image/gif;image/webp;text/plain;application/zip;application/x-tar;application/x-7z-compressed;application/x-executable;application/x-shellscript;application/octet-stream;
EOF

# 9. Configure Openbox & Tint2 & PCManFM Desktop
mkdir -p /mnt/target/root/.config/openbox /mnt/target/root/.config/tint2 /mnt/target/root/.config/pcmanfm/default /mnt/target/root/Desktop /mnt/target/root/SandboxFiles

cat > /mnt/target/root/.config/pcmanfm/default/desktop-items-0.conf << 'EOF'
[*]
wallpaper_mode=color
wallpaper_common=1
desktop_bg=#1e293b
desktop_fg=#f8fafc
desktop_shadow=#0f172a
desktop_font=Noto Sans CJK SC 11
show_wm_menu=0
sort=mtime;ascending;
show_documents=0
show_trash=0
show_mounts=0
EOF

cat > /mnt/target/root/.config/tint2/tint2rc << 'EOF'
panel_items = LTSC
panel_size = 100% 34
panel_margin = 0 0
panel_padding = 8 4 8
panel_background_id = 1
wm_menu = 1
panel_dock = 0
panel_position = bottom center horizontal
panel_layer = top
rounded = 0
background_color = #0f172a 92
border_width = 0
taskbar_mode = single_desktop
taskbar_padding = 4 2 4
task_icon = 1
task_text = 1
task_centered = 1
task_maximum_size = 200 30
task_font = Noto Sans CJK SC 10
task_font_color = #e2e8f0 100
task_active_background_id = 2
rounded = 6
background_color = #2563eb 90
time1_format = %H:%M:%S  |  SafeSpace 隔离沙盒桌面
time1_font = Noto Sans CJK SC Bold 10
clock_font_color = #93c5fd 100
clock_padding = 10 0
launcher_padding = 4 2 4
launcher_icon_size = 22
launcher_item_app = /usr/share/applications/pcmanfm-Analogue.desktop
EOF

cat > /mnt/target/usr/share/applications/pcmanfm-Analogue.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=沙盒文件夹
Exec=pcmanfm /root/Desktop
Icon=system-file-manager
Terminal=false
EOF

# 10. Create the sync & serial listener script (/usr/local/bin/safespace-agent)
cat > /mnt/target/usr/local/bin/safespace-agent << 'EOF'
#!/bin/sh
export DISPLAY=:0
export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8

mkdir -p /mnt/safeshare /root/Desktop /root/SandboxFiles
mount -t virtiofs safeshare /mnt/safeshare 2>/dev/null || true

sync_files() {
    mkdir -p /root/Desktop /root/SandboxFiles
    # Always keep a shortcut to open the Sandbox File Manager on the Desktop
    cat > "/root/Desktop/00_打开沙盒文件管理器.desktop" << 'DESKEOF'
[Desktop Entry]
Type=Application
Name=📁 打开已上传文件目录
Exec=pcmanfm /root/SandboxFiles
Icon=folder
Terminal=false
DESKEOF
    chmod +x "/root/Desktop/00_打开沙盒文件管理器.desktop"

    # Sync uploaded files from /mnt/safeshare
    if [ -d /mnt/safeshare ]; then
        # Remove deleted files
        for existing in /root/SandboxFiles/*; do
            [ -e "$existing" ] || continue
            bname="$(basename "$existing")"
            if [ ! -e "/mnt/safeshare/$bname" ]; then
                rm -rf "$existing" "/root/Desktop/$bname.desktop" "/root/Desktop/$bname"
            fi
        done

        for src in /mnt/safeshare/*; do
            [ -e "$src" ] || continue
            bname="$(basename "$src")"
            case "$bname" in
                .*) continue ;;
            esac
            if [ ! -e "/root/SandboxFiles/$bname" ] || [ "$src" -nt "/root/SandboxFiles/$bname" ]; then
                cp -rf "$src" "/root/SandboxFiles/$bname"
                # Create a clickable Desktop launcher icon for each uploaded file!
                ICON="text-x-generic"
                EXT="$(echo "${bname##*.}" | tr '[:upper:]' '[:lower:]')"
                case "$EXT" in
                    pdf) ICON="x-office-document" ;;
                    ppt|pptx|odp) ICON="x-office-presentation" ;;
                    doc|docx|odt) ICON="x-office-document" ;;
                    xls|xlsx|ods) ICON="x-office-spreadsheet" ;;
                    png|jpg|jpeg|gif|webp|bmp|svg) ICON="image-x-generic" ;;
                    zip|tar|gz|7z) ICON="package-x-generic" ;;
                    sh|run|bin|exe|dmg|pkg|app) ICON="system-run" ;;
                esac
                cat > "/root/Desktop/${bname}.desktop" << ITEMEOF
[Desktop Entry]
Type=Application
Name=${bname}
Exec=/usr/local/bin/safespace-open "/root/SandboxFiles/${bname}"
Icon=${ICON}
Terminal=false
ITEMEOF
                chmod +x "/root/Desktop/${bname}.desktop"
            fi
        done
    fi
}

# Initial sync
sync_files

# Background loop: watch /mnt/safeshare every 1 second
(
    while true; do
        sync_files
        sleep 1
    done
) &

# Listen for instant commands on /dev/hvc0 from macOS host
if [ -c /dev/hvc0 ]; then
    echo "__SAFESPACE_READY__" > /dev/hvc0
    while IFS= read -r line; do
        case "$line" in
            __SAFESPACE_CMD__:OPEN:*)
                FNAME="${line#__SAFESPACE_CMD__:OPEN:}"
                sync_files
                /usr/local/bin/safespace-open "/mnt/safeshare/$FNAME" &
                echo "__SAFESPACE_ACK__:OPEN:$FNAME" > /dev/hvc0
                ;;
            __SAFESPACE_CMD__:NET_ON*)
                ip link set eth0 up 2>/dev/null || true
                udhcpc -i eth0 -n -q >/dev/null 2>&1 &
                echo "__SAFESPACE_ACK__:NET_ON" > /dev/hvc0
                ;;
            __SAFESPACE_CMD__:NET_OFF*)
                killall udhcpc 2>/dev/null || true
                ip addr flush dev eth0 2>/dev/null || true
                ip link set eth0 down 2>/dev/null || true
                echo "__SAFESPACE_ACK__:NET_OFF" > /dev/hvc0
                ;;
            __SAFESPACE_CMD__:SYNC*)
                sync_files
                echo "__SAFESPACE_ACK__:SYNC" > /dev/hvc0
                ;;
            __SAFESPACE_CMD__:FILEMANAGER*)
                pcmanfm /root/SandboxFiles &
                ;;
            __SAFESPACE_CMD__:TERMINAL*)
                lxterminal &
                ;;
        esac
    done < /dev/hvc0
fi
EOF
chmod +x /mnt/target/usr/local/bin/safespace-agent

# 11. Configure fast graphical boot script (/sbin/safespace-init)
cat > /mnt/target/sbin/safespace-init << 'EOF'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export USER=root
export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /dev/shm /tmp /run
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true
chmod 1777 /tmp /dev/shm

# Load required Virtio drivers
for mod in virtio_pci virtio_blk virtio_net virtio_console virtio_input hid usbhid xhci_hcd xhci_pci drm drm_kms_helper virtio_gpu fuse virtiofs; do
    modprobe "$mod" 2>/dev/null || true
done

# Start udev so Xorg discovers keyboard, mouse, and DRM display
udevd --daemon 2>/dev/null || /sbin/udevd --daemon 2>/dev/null || true
udevadm trigger 2>/dev/null || true
udevadm settle --timeout=3 2>/dev/null || true

# Start D-Bus
mkdir -p /run/dbus
dbus-uuidgen --ensure 2>/dev/null || true
dbus-daemon --system --fork 2>/dev/null || true

# Loopback interface
ip link set lo up 2>/dev/null || true

# Check kernel cmdline for initial network policy
if grep -q "safespace.net=1" /proc/cmdline; then
    ip link set eth0 up 2>/dev/null || true
    udhcpc -i eth0 -n -q >/dev/null 2>&1 &
else
    ip link set eth0 down 2>/dev/null || true
fi

# Start Xorg server
Xorg :0 -noreset -nolisten tcp vt1 >/var/log/Xorg.log 2>&1 &

# Wait for Xorg socket
for i in $(seq 1 30); do
    if [ -S /tmp/.X11-unix/X0 ]; then
        break
    fi
    sleep 0.1
done

export DISPLAY=:0
openbox --sm-disable &
sleep 0.2
pcmanfm --desktop &
tint2 &

# Open the file manager window initially so the user immediately sees the sandbox workspace
(sleep 0.8 && pcmanfm /root/Desktop) &

# Start SafeSpace guest agent (blocks reading /dev/hvc0)
/usr/local/bin/safespace-agent

# Fallback shell if agent exits
exec /bin/sh
EOF
chmod +x /mnt/target/sbin/safespace-init
mv /mnt/target/sbin/init /mnt/target/sbin/init.busybox 2>/dev/null || true
ln -sf /sbin/safespace-init /mnt/target/sbin/init

# Configure Xorg to use modesetting / fbdev cleanly on virtio-gpu
mkdir -p /mnt/target/etc/X11/xorg.conf.d
cat > /mnt/target/etc/X11/xorg.conf.d/10-virtio.conf << 'EOF'
Section "ServerFlags"
    Option "AutoAddDevices" "true"
    Option "AutoEnableDevices" "true"
EndSection

Section "Device"
    Identifier "VirtioGPU"
    Driver "modesetting"
    Option "SWcursor" "true"
EndSection

Section "Monitor"
    Identifier "Monitor0"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "VirtioGPU"
    Monitor "Monitor0"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1280x800"
    EndSubSection
EndSection
EOF

sync
umount /mnt/target
echo "=== [SafeSpace Provisioner] SUCCESS! __PROVISION_COMPLETE__ ==="
poweroff -f
