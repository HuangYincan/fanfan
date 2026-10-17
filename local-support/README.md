# FanFan 本机版

此目录仅属于 `local/machine-build` 分支。上游贡献使用
`fix/system-control-recovery`，不要把本机安装和签名调整带入上游 PR。

运行 `bash local-support/build.sh` 需要 macOS 26 SDK。构建在独立源代码副本中进行，
输出 `fanfan-local-arm64.tar.gz`，版本为 1.8.2 (3301)，界面标明“本机版”。
该压缩包是构建产物，不是公开 Release。

App 保留原 bundle ID 和偏好设置，关闭 Sparkle 更新。App 和辅助程序均使用
ad-hoc 签名及 hardened runtime，双方通过精确 CodeDirectory 哈希校验 XPC 对端。
辅助程序只接受 root 所有且不可由普通用户修改的策略文件，校验失败即拒绝启动。
不修改系统证书信任或 Gatekeeper 设置。

解压后运行 `sudo /bin/bash /absolute/path/install.sh`。安装器备份原版 App，
把风扇交回系统，替换 App、安装独立 root 辅助程序，并停用原版辅助程序。
重复安装本机版保留原版备份；替换期间发生错误会尝试恢复先前安装。

安装后验证：

```sh
/Applications/fanfan.app/Contents/MacOS/fanfan --local-helper-status
/Applications/fanfan.app/Contents/MacOS/fanfan --local-self-test
/absolute/path/unauthorized-probe
```

先退出正常运行的 App 再执行自检。自检短暂请求硬件最大转速，然后交回系统。
必须先确认 App PING 成功，再使用负向测试验证同 bundle ID、不同哈希的程序被拒绝；
测试后再次确认 App PING 成功且辅助程序没有重启，排除服务崩溃造成的错误回复。

原版恢复入口：

```sh
sudo /bin/bash '/Library/Application Support/FanFanLocal/rollback.sh'
```

此修复处理系统模式恢复失败后的重试和错误状态清除，不构成对先前持续 110°C
现象原因的结论。
