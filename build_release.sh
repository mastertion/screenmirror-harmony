#!/usr/bin/env bash
# V2 发布包构建: bash build_release.sh  → 产物 .app + 签名 hap
set +e
cd "F:/AICODE/spacedesk/SpacedeskV2" || exit 1
export NODE_HOME="/d/deveco-setup/deveco-26/tools/node"
export DEVECO_SDK_HOME="D:/deveco-setup/deveco-26/sdk"
export PATH="$NODE_HOME:/d/deveco-setup/deveco-26/tools/hvigor/bin:/d/deveco-setup/deveco-26/tools/ohpm/bin:$PATH"
node /d/deveco-setup/deveco-26/tools/hvigor/bin/hvigorw.js --mode project -p product=default -p buildMode=release assembleApp --no-daemon 2>&1 | tail -15
echo "APP_BUILD_DONE"
ls -la entry/build/default/outputs/default/*.app 2>/dev/null
