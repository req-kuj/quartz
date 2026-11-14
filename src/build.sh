#!/bin/sh
# Build the Quartz UGen from the wrapper and the vendored Beads source.
#
# usage: build.sh <compiler> <out> [extra flags]
#   on norns:        ./build.sh g++ Quartz.so
#   cross-compiling: ./build.sh arm-linux-gnueabihf-g++ Quartz.so \
#                      -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard \
#                      -static-libstdc++ -static-libgcc
#
# MI points at the Mutable Instruments source, SC at the SuperCollider
# headers. Only the DSP files are compiled, not the module's hardware code.
# -DTEST is Mutable's own flag for building the DSP off the hardware.
set -e
CXX=$1; OUT=$2; shift 2
MI=${MI:-$(dirname "$0")/third_party}
SC=${SC:-/usr/include/SuperCollider}
SRC="Quartz.cpp $MI/beads/dsp/processor.cc $MI/beads/dsp/synth.cc $MI/beads/dsp/delay_clock.cc $MI/beads/dsp/delay_controller.cc $MI/beads/dsp/mu_law.cc $MI/beads/dsp/trigger_generator.cc $MI/beads/resources.cc $MI/stmlib/utils/random.cc $MI/stmlib/dsp/units.cc $MI/stmlib/dsp/atan.cc"
$CXX -O2 -std=c++11 -fPIC -shared -DTEST -ffast-math -fno-exceptions -Wno-narrowing \
  -I$MI -I$SC/plugin_interface -I$SC/common -I$SC/server "$@" $SRC -o $OUT
