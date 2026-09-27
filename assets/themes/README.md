# 内置主题资源

该目录供 Flutter asset manifest 保留主题资源入口。当前液态流光背景定义及主题包序列化由 `lib/shared/theme/` 与 `assets/backgrounds/` 管理；用户导入主题和自定义图片应进入应用数据目录，不直接写入此只读 asset 目录。

`.hohtheme` 是可导入/导出的主题包格式；在此放置可随应用分发的新素材前，先登记来源与许可证，并同步 `docs/开源项目与协议清单.md`。
