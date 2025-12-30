#!/usr/bin/env bash
set -euo pipefail

(cd xdma && make)
(cd v4l2 && make)
