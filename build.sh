#!/bin/sh
# Modified from ivandavidov/minimal-linux-script
# https://github.com/ivandavidov/minimal-linux-script
# This script includes a dynamic linked busybox, openssl, python and
# network support

set -ex

KERNEL_VERSION=4.17.2
BUSYBOX_VERSION=1.28.4
GLIBC_VERSION=2.27
SYSLINUX_VERSION=6.03
BASH_VERSION=4.4.18
ZLIB_VERSION=1.2.11
OPENSSL_VERSION=1.0.2p
LIBFFI_VERSION=3.2.1
PYTHON_VERSION=3.7.0

CPU_CORES=$(grep ^processor /proc/cpuinfo | wc -l)
CFLAGS="-Os -s -fno-stack-protector -fomit-frame-pointer -U_FORTIFY_SOURCE"

PROJECT_ROOT=$(pwd)
KERNEL_ROOT=$PROJECT_ROOT/kernel
GLIBC_ROOT=$PROJECT_ROOT/glibc
BUSYBOX_ROOT=$PROJECT_ROOT/busybox
BASH_ROOT=$PROJECT_ROOT/bash
ZLIB_ROOT=$PROJECT_ROOT/zlib
OPENSSL_ROOT=$PROJECT_ROOT/openssl
LIBFFI_ROOT=$PROJECT_ROOT/libffi
PYTHON_ROOT=$PROJECT_ROOT/python
SYSLINUX_ROOT=$PROJECT_ROOT/syslinux

ROOTFS=$BUSYBOX_ROOT/_install
GLIBC_SYSROOT=$GLIBC_ROOT/out
KERNEL_HEADER_DIR=$KERNEL_ROOT/usr/include

prepare_source () {
    local name=$1
    local url=$2
    mkdir -p $PROJECT_ROOT/source
    if [ ! -d "$PROJECT_ROOT/$name" ]; then
        if [ ! -f "$PROJECT_ROOT/source/$name" ]; then
            wget -O $PROJECT_ROOT/source/$name $url
        fi
        mkdir -p $PROJECT_ROOT/$name
        tar -xvf $PROJECT_ROOT/source/$name -C $PROJECT_ROOT/$name --strip 1
    fi
    return 0
}

# Install build tools
sudo apt install wget make gawk gcc bc bison flex xorriso libelf-dev libssl-dev libffi-dev

mkdir -p $PROJECT_ROOT/isoimage

# --------------------------------------------------
#     Compile Linux kernal and install headers
# --------------------------------------------------
prepare_source kernel http://kernel.org/pub/linux/kernel/v4.x/linux-$KERNEL_VERSION.tar.xz
cd $KERNEL_ROOT
if [ ! -f "$PROJECT_ROOT/isoimage/kernel.gz" ]; then
    make clean
    make mrproper defconfig
    sed -i "s/.*CONFIG_LOGO.*/CONFIG_LOGO=n/" .config
    sed -i "s/.*CONFIG_FB_VESA.*/CONFIG_FB_VESA=y/" .config
    sed -i "s/.*CONFIG_DEFAULT_HOSTNAME.*/CONFIG_DEFAULT_HOSTNAME=\"minimal\"/" .config
    make CFLAGS="$CFLAGS" bzImage -j $CPU_CORES
    cp arch/x86/boot/bzImage $PROJECT_ROOT/isoimage/kernel.gz
fi
if [ ! -d "$KERNEL_ROOT/usr/include" ]; then
    make headers_install
fi


# --------------------------------------------------
#        Compile glibc and prepare headers
# --------------------------------------------------
prepare_source glibc https://ftp.gnu.org/gnu/glibc/glibc-$GLIBC_VERSION.tar.gz
cd $GLIBC_ROOT
if [ ! -d "$GLIBC_SYSROOT" ]; then
    rm -rf _build
    mkdir _build
    cd _build
    ../configure CFLAGS="$CFLAGS" --prefix= --with-headers=$KERNEL_HEADER_DIR \
        --without-gd --without-selinux --disable-werror
    make clean
    make -j $CPU_CORES
    mkdir $GLIBC_SYSROOT
    make install DESTDIR=$GLIBC_SYSROOT
fi
if [ ! -d "$GLIBC_SYSROOT/usr" ]; then
    cd $GLIBC_SYSROOT
    cp -r $KERNEL_HEADER_DIR .
    mkdir -p usr
    ln -s $GLIBC_SYSROOT/include $GLIBC_SYSROOT/usr/include
    ln -s $GLIBC_SYSROOT/lib $GLIBC_SYSROOT/usr/lib
fi


# --------------------------------------------------
#                  Compile Busybox
# --------------------------------------------------
prepare_source busybox http://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2
if [ ! -d "$ROOTFS" ]; then
    cd $BUSYBOX_ROOT
    make distclean defconfig
    GLIBC_SYSROOT_ESCAPED=$(echo \"$GLIBC_SYSROOT\" | sed 's/\//\\\//g')
    sed -i "s/.*CONFIG_INETD.*/CONFIG_INETD=n/" .config
    sed -i "s/.*CONFIG_SYSROOT.*/CONFIG_SYSROOT=$GLIBC_SYSROOT_ESCAPED/" .config
    make EXTRA_CFLAGS="$CFLAGS" busybox -j $CPU_CORES
    make install
fi


# --------------------------------------------------
#                  Compile Bash
# --------------------------------------------------
prepare_source bash http://ftp.gnu.org/gnu/bash/bash-$BASH_VERSION.tar.gz
if [ ! -f "$BASH_ROOT/out/usr/bin/bash" ]; then
    cd $BASH_ROOT
    ./configure CFLAGS="$CFLAGS --sysroot=$GLIBC_SYSROOT" --prefix=/usr
    make -j $CPU_CORES
    mkdir -p $BASH_ROOT/out
    make install DESTDIR=$BASH_ROOT/out
fi


# --------------------------------------------------
#                  Compile zlib
# --------------------------------------------------
prepare_source zlib https://zlib.net/zlib-$ZLIB_VERSION.tar.gz
if [ ! -f "$ZLIB_ROOT/out/usr/lib/libz.so.1" ]; then
    cd $ZLIB_ROOT
    CFLAGS="$CFLAGS --sysroot=$GLIBC_SYSROOT" ./configure --prefix=/usr
    make -j $CPU_CORES
    mkdir -p $ZLIB_ROOT/out
    make install DESTDIR=$ZLIB_ROOT/out
fi

# --------------------------------------------------
#                  Compile OpenSSL
# --------------------------------------------------
prepare_source openssl https://openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz
if [ ! -f "$OPENSSL_ROOT/out/usr/bin/openssl" ]; then
    cd $OPENSSL_ROOT
    `echo "./config $CFLAGS --sysroot=$GLIBC_SYSROOT -I$ZLIB_ROOT/out/usr/include --prefix=/usr --openssldir=/etc/ssl shared zlib-dynamic"`
    make depend
    make -j $CPU_CORES
    mkdir -p $OPENSSL_ROOT/out
    make INSTALL_PREFIX=$OPENSSL_ROOT/out install_sw
fi


# --------------------------------------------------
#                  Compile libffi
# --------------------------------------------------
prepare_source libffi https://sourceware.org/ftp/libffi/libffi-$LIBFFI_VERSION.tar.gz
if [ ! -f "$LIBFFI_ROOT/out/usr/lib/libffi.so.6" ]; then
    cd $LIBFFI_ROOT
    ./configure CFLAGS="$CFLAGS --sysroot=$GLIBC_SYSROOT" --prefix=/usr --disable-static
    make -j $CPU_CORES
    mkdir -p $LIBFFI_ROOT/out
    make install DESTDIR=$LIBFFI_ROOT/out
fi


# --------------------------------------------------
#                  Compile Python
# --------------------------------------------------
prepare_source python https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tar.xz
if [ ! -f "$PYTHON_ROOT/out/usr/bin/python3" ]; then
    cd $PYTHON_ROOT
    # disable nis module
    sed -i "/def _detect_nis/a \\        return None" setup.py
    ./configure CFLAGS="$CFLAGS --sysroot=$GLIBC_SYSROOT" \
        LDFLAGS="-L$OPENSSL_ROOT/out/usr/lib -L$LIBFFI_ROOT/out/usr/lib" \
        CPPFLAGS="-I$ZLIB_ROOT/out/usr/include -I$OPENSSL_ROOT/out/usr/include -I$LIBFFI_ROOT/out/usr/include" \
        --prefix=/usr --enable-shared --with-ensurepip=yes
    make -j $CPU_CORES
    mkdir -p $PYTHON_ROOT/out
    make install DESTDIR=$PYTHON_ROOT/out
fi


# --------------------------------------------------
#                   Prepare rootfs
# --------------------------------------------------
cd $ROOTFS
rm -f linuxrc
mkdir -p dev proc sys etc tmp
chmod 1777 tmp
rm -f init
cat > init << EOF
#!/bin/sh

exec /sbin/init

EOF
cat > etc/bootscript.sh << EOF
#!/bin/sh

dmesg -n 1
mount -t devtmpfs none /dev
mount -t proc none /proc
mount -t sysfs none /sys

for DEVICE in /sys/class/net/* ; do
  ip link set \${DEVICE##*/} up
  [ \${DEVICE##*/} != lo ] && udhcpc -b -i \${DEVICE##*/} -s /etc/rc.dhcp
done

setsid cttyhack /bin/sh

EOF
chmod +x init
chmod +x etc/bootscript.sh
cat > etc/inittab << EOF
::sysinit:/etc/bootscript.sh
::restart:/sbin/init
::ctrlaltdel:/sbin/reboot
::askfirst:-/bin/login
tty2::askfirst:-/bin/sh
tty3::askfirst:-/bin/sh
tty4::askfirst:-/bin/sh

EOF
cat > etc/group << EOF
root:x:0:root

EOF
cat > etc/passwd << EOF
root::0:0:,,,:/root:/bin/sh

EOF
cat > etc/rc.dhcp << EOF
#!/bin/sh

ip addr add \$ip/\$mask dev \$interface

if [ "\$router" ]; then
  ip route add default via \$router dev \$interface
fi

EOF
chmod +x etc/rc.dhcp
cat > etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4

EOF

rm -rf lib
rm -rf lib64
mkdir -p lib
mkdir -p lib64
# copy executables and libraries
cp $GLIBC_SYSROOT/lib/ld-linux* lib64/
cp $GLIBC_SYSROOT/lib/libm.so.6 lib/
cp $GLIBC_SYSROOT/lib/libc.so.6 lib/
cp $GLIBC_SYSROOT/lib/libdl.so.2 lib/
cp $GLIBC_SYSROOT/lib/libutil.so.1 lib/
cp $GLIBC_SYSROOT/lib/libpthread.so.0 lib/
cp $GLIBC_SYSROOT/lib/libresolv.so.2 lib/
cp $GLIBC_SYSROOT/lib/libnss_dns.so.2 lib/
# bash
cp $BASH_ROOT/out/usr/bin/bash $ROOTFS/usr/bin/
# openssl
cp -r $OPENSSL_ROOT/out/usr/bin $ROOTFS/usr/
cp -r $OPENSSL_ROOT/out/etc/ssl $ROOTFS/etc/
cp $OPENSSL_ROOT/out/usr/lib/libssl.so.1.0.0 $ROOTFS/lib/
cp $OPENSSL_ROOT/out/usr/lib/libcrypto.so.1.0.0 $ROOTFS/lib/
# python
cp $ZLIB_ROOT/out/usr/lib/libz.so.1 lib/
cp $LIBFFI_ROOT/out/usr/lib/libffi.so.6 lib/
cp -r $PYTHON_ROOT/out/usr/bin $ROOTFS/usr/
mkdir -p $ROOTFS/usr/lib/
cp -r $PYTHON_ROOT/out/usr/lib/python${PYTHON_VERSION%.*} -t $ROOTFS/usr/lib/
cp $PYTHON_ROOT/out/usr/lib/libpython${PYTHON_VERSION%.*}m.so.1.0 $ROOTFS/lib/
find $PYTHON_ROOT/out/usr/lib/python* | grep -E "(__pycache__|\.pyc|\.pyo$)" | xargs rm -rf

# set default shell to bash
if [ -f "$ROOTFS/bin/sh" ]; then
    rm $ROOTFS/bin/sh
fi
ln -rs $ROOTFS/usr/bin/bash $ROOTFS/bin/sh

# install static-get
wget https://raw.githubusercontent.com/minos-org/minos-static/master/static-get -O $ROOTFS/usr/bin/static-get
chmod +x $ROOTFS/usr/bin/static-get

# reduce binary size
set +e
for file in $(find $ROOTFS/bin/* $ROOTFS/usr/bin/* $ROOTFS/lib/* $ROOTFS/usr/lib/* ! -name '*.*');
do
    strip -g $file 2>/dev/null
done
set -e

find . | cpio -R root:root -H newc -o | gzip > $PROJECT_ROOT/isoimage/rootfs.gz


# --------------------------------------------------
#                    Make LiveCD
# --------------------------------------------------
prepare_source syslinux http://kernel.org/pub/linux/utils/boot/syslinux/syslinux-$SYSLINUX_VERSION.tar.xz
cd $PROJECT_ROOT/isoimage
cp $SYSLINUX_ROOT/bios/core/isolinux.bin .
cp $SYSLINUX_ROOT/bios/com32/elflink/ldlinux/ldlinux.c32 .
# cp $SYSLINUX_ROOT/bios/com32/menu/menu.c32 .
# cp $SYSLINUX_ROOT/bios/com32/libutil/libutil.c32 .
cat > isolinux.cfg << EOF
SERIAL 0
PROMPT 1
TIMEOUT 3
DEFAULT vga

SAY System is booting
SAY Press <TAB> for all boot options

LABEL vga
  LINUX  /kernel.gz
  APPEND vga=ask
  INITRD /rootfs.gz

LABEL vga_nomodeset
  LINUX  /kernel.gz
  APPEND vga=ask nomodeset
  INITRD /rootfs.gz

LABEL console
  LINUX  /kernel.gz
  APPEND console=tty0 console=ttyS0
  INITRD /rootfs.gz
EOF
xorriso \
  -as mkisofs \
  -o $PROJECT_ROOT/minimal_linux_live.iso \
  -b isolinux.bin \
  -c boot.cat \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  ./

cd $PROJECT_ROOT
set +ex
