#!/bin/bash
# 本地一键构建（需 macOS + 命令行工具：xcode-select --install）
# 用法：cd 本目录后执行 ./build.sh
set -e

if [ -z "$SDK" ]; then
  if [ ! -d "iPhoneOS.sdk" ]; then
    echo "[*] 下载 theos/sdks 的 iPhoneOS.sdk ..."
    URL=$(curl -s https://api.github.com/repos/theos/sdks/releases/latest \
          | grep -o 'https://[^"]*iPhoneOS.sdk.tar.xz' | head -1)
    curl -L -o iPhoneOS.sdk.tar.xz "$URL"
    tar -xf iPhoneOS.sdk.tar.xz
  fi
  export SDK="$PWD/iPhoneOS.sdk"
fi

echo "[*] 用 SDK=$SDK 编译 tweak.dylib ..."
make clean
make SDK="$SDK"
echo "[+] 完成，产出：tweak.dylib"
echo "    用 TrollFools 注入小红书（com.xingin.discover）后杀掉重开即可。"
