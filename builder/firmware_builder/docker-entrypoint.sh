#!/bin/bash
set -e

exec build_server.pl >> /proc/1/fd/1 2>> /proc/1/fd/2
