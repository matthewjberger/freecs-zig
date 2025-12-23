set windows-shell := ["powershell.exe"]

@just:
    just --list

build:
    zig build

run:
    zig build run-boids

test:
    zig build test

check:
    zig build check

[windows]
clean:
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .zig-cache, zig-out

[unix]
clean:
    rm -rf .zig-cache zig-out

@versions:
    zig version
