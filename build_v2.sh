#!/usr/bin/env bash
# V2 一键编译: bash build_v2.sh
set +e
cd "F:/AICODE/spacedesk/SpacedeskV2" || exit 1
export NODE_HOME="/d/deveco-setup/deveco-26/tools/node"
export DEVECO_SDK_HOME="D:/deveco-setup/deveco-26/sdk"
export PATH="$NODE_HOME:/d/deveco-setup/deveco-26/tools/hvigor/bin:/d/deveco-setup/deveco-26/tools/ohpm/bin:$PATH"
node /d/deveco-setup/deveco-26/tools/hvigor/bin/hvigorw.js --mode module -p product=default assembleHap --no-daemon 2>&1 | tail -12
echo "BUILD_DONE"
