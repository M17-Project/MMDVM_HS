#!/bin/bash

#
# MMDVM_HS FW build script
#
set -x
if [ -d './release' ]; then
    rm -rfv ./release/*
fi

if [ ! -d './release' ]; then
    mkdir ./release
fi

git submodule init
git submodule update

make clean

rm -rfv bin/* release/*

mv Config.h Config.h.dist

# generic_duplex_gpio
cp configs/generic_duplex_gpio.h ./Config.h
make -j$(nproc)
mv bin/mmdvm_*.bin release/generic_duplex_gpio.bin
make clean

# generic_duplex_usb
# cp configs/generic_duplex_usb.h ./Config.h
# make -j$(nproc)
# mv bin/mmdvm_*.bin release/generic_duplex_usb.bin
# make clean

# generic_gpio
cp configs/generic_gpio.h ./Config.h
make -j$(nproc)
mv bin/mmdvm_*.bin release/generic_gpio.bin
make clean

# MMDVM_HS_Dual_Hat-12mhz
cp configs/MMDVM_HS_Dual_Hat-12mhz.h ./Config.h
make -j$(nproc)
mv bin/mmdvm_*.bin release/MMDVM_HS_Dual_Hat-12mhz.bin
make clean

# MMDVM_HS_Dual_Hat
cp configs/MMDVM_HS_Dual_Hat.h ./Config.h
make -j$(nproc)
mv bin/mmdvm_*.bin release/MMDVM_HS_Dual_Hat.bin
make clean

# MMDVM_HS_Hat-12mhz
cp configs/MMDVM_HS_Hat-12mhz.h ./Config.h
make -j$(nproc)
mv bin/mmdvm_*.bin release/MMDVM_HS_Hat-12mhz.bin
make clean

# MMDVM_HS_Hat
cp configs/MMDVM_HS_Hat.h ./Config.h
make -j$(nproc)
mv bin/mmdvm_*.bin release/MMDVM_HS_Hat.bin
make clean

mv Config.h.dist Config.h
