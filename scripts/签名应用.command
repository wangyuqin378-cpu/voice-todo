#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
print "正在使用随口清单专用的本地开发身份签名。"
zsh scripts/sign-app.sh 2>&1 | tee .build/signing.log
