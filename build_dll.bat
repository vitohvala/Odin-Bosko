@echo off

set common=-show-timings -debug -o:minimal -vet-unused -vet-using-stmt -vet-using-param -vet-style -vet-semicolon


pushd build

odin build ../code/game -build-mode:dll -out:game.dll %common%

popd build