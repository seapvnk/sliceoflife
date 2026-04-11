#!/bin/bash

# Define the folders
CONCORD="benchmark/concord_impl"
SLICE="benchmark/sliceoflife_impl"

luajit -e "package.path='$CONCORD/?.lua;$CONCORD/?/init.lua;'..package.path" -jp=v $CONCORD/main.lua
luajit -e "package.path='$SLICE/?.lua;$SLICE/?/init.lua;'..package.path" -jp=v $SLICE/main.lua