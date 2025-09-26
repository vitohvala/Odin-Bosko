@echo off

if not exist build mkdir build

rem remember to add -vet-unusued on release 
set common=-show-timings -debug -o:minimal -vet-using-stmt -vet-using-param -vet-style -vet-semicolon

pushd build

odin build ../code/game -build-mode:dll -out:game.dll %common%
echo code :
odin build ../code -out:bosko.exe %common%

popd build