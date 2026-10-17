# OTrans HarmonyOS

面向 HarmonyOS 26.0.0 Release 的 OTrans 手机客户端。目前支持：

1. 打开应用并读取当前剪贴板文本。
2. 用户在待上传区确认或修改文本。
3. 使用飞牛服务地址和一次性配对码完成设备注册。
4. 创建并提交一条文本中转记录。
5. 从系统图库选择图片，或从系统文件选择器选择普通文件。
6. 计算 SHA-256、上传飞牛缺失的 Blob，并在所有文件完整到达后提交中转记录。
7. 进入应用时拉取中转站记录，不在后台自动下载文件。
8. 对其他设备发送的文本一键复制；图片和文件由用户点击后通过系统文件选择器保存。
9. 在手机端全局删除中转记录，其他 Windows 客户端下次同步时删除各自的受管副本。
10. 分别配置内网和外网地址，网络变化时自动重新选路并优先使用内网。
11. 使用飞牛服务持久化的 `serverId` 校验两个地址，上传重试使用同一幂等标识，避免重复记录。

图片和文件每次最多选择 9 项，当前手机端单文件上限为 128 MiB。选择器只授予用户主动选择内容的读取权限，不需要持续读取相册或文件目录。

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
