# OTrans HarmonyOS

面向 HarmonyOS 26.0.0 Release 的 OTrans 手机客户端。目前支持：

1. 打开应用时读取一次当前剪贴板，支持文本、图片和文件，不持续监听剪贴板。
2. 用户可以在待发送区确认或修改文本，并继续添加图片和文件。
3. 使用飞牛服务地址和一次性配对码完成设备注册。
4. 把文本、图片和多个文件组合为一条混合中转记录后提交。
5. 从系统图库选择图片，或从系统文件选择器选择普通文件。
6. 计算 SHA-256、上传飞牛缺失的 Blob，并在所有文件完整到达后提交中转记录。
7. 进入应用时拉取中转站记录，不在后台自动下载文件。
8. 对其他设备发送的文本一键复制；图片和文件由用户点击后通过系统文件选择器保存。
9. 在手机端全局删除中转记录，其他 Windows 客户端下次同步时删除各自的受管副本。
10. 分别配置内网和外网地址，网络变化时自动重新选路并优先使用内网。
11. 使用飞牛服务持久化的 `serverId` 校验两个地址，上传重试使用同一幂等标识，避免重复记录。
12. v0.5 实验：保存文件时优先从同一局域网内已开启直传的 Windows 客户端获取，校验失败或不可达时自动回退飞牛。
13. 接收系统中转站或其他应用拖入的文本、图片、视频和普通文件；拖入内容先复制到应用目录并加入待发送列表，不会自动上传。

一条记录最多包含 64 项；当前手机端最多暂存 63 个文件，另可附带一段文本，单文件上限为 128 MiB。选择器和系统拖拽只授予用户主动选择内容的读取权限，不需要持续读取相册或文件目录。首版不接收文件夹。

本项目不兼容低于 API 26 的系统版本。

## 本机工具链

- HarmonyOS SDK 26.0.0.105 Release
- ohpm 26.0.0.630
- Hvigor 6.26.4

构建前需要在 DevEco Studio 中配置签名。命令行检查可使用 DevEco Studio 自带工具：

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin\ohpm.bat' install
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=entry@default -p product=default assembleHap
```

当前由飞牛端管理页创建一次性配对码。手机端进入前台时拉取最近 100 条有效中转记录，并支持按需保存和全局删除；它不会在后台持续下载或监听剪贴板。

当前 HarmonyOS 端只作为局域网直传接收方，不在手机上开放文件服务端口；因此 Windows 到手机可走局域网直连，手机发送到 Windows 仍从飞牛下载。无论实际下载路径如何，文件都会先上传飞牛，记录和全局删除语义保持一致。
