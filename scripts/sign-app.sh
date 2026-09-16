#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
# Reuse the same local identity for every personal build. An Apple identity can
# be selected explicitly for a separate distribution workflow.
signing_identity="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    exec swift -suppress-warnings scripts/local-sign.swift
fi
if [[ "$signing_identity" == "-" ]]; then
    print -u2 "请使用稳定签名；临时签名会使更新后的系统权限失效。"
    exit 1
fi
app_dir="$PWD/dist/随口清单.app"
codesign --force --sign "$signing_identity" --identifier com.wyq.voicetodo "$app_dir"
codesign --verify --deep --strict "$app_dir"
print "签名与验证已完成。"
