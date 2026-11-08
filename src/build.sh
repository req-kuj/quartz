#!/bin/sh
# usage: build.sh <compiler> <out> [extra flags]
set -e
CXX=$1; OUT=$2; shift 2
MI=${MI:-$(dirname "$0")/third_party}
SC=${SC:-/usr/include/SuperCollider}
SRC="Quartz.cpp $MI/beads/dsp/processor.cc $MI/beads/dsp/synth.cc $MI/beads/dsp/delay_clock.cc $MI/beads/dsp/delay_controller.cc $MI/beads/dsp/mu_law.cc $MI/beads/dsp/trigger_generator.cc $MI/beads/resources.cc $MI/stmlib/utils/random.cc $MI/stmlib/dsp/units.cc $MI/stmlib/dsp/atan.cc"
$CXX -O2 -std=c++11 -fPIC -shared -DTEST -ffast-math -fno-exceptions -Wno-narrowing \
  -I$MI -I$SC/plugin_interface -I$SC/common -I$SC/server "$@" $SRC -o $OUT
