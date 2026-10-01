/// HoH music 的平台显示别名。
///
/// 这些名称只用于界面和用户文案；`wy`、`tx`、`kg`、`kw`、`mg` 等协议键
/// 以及音源脚本收到的 musicInfo 保持不变。
const Map<String, String> kPlatformDisplayAliases = <String, String>{
  'wy': '芸音',
  'tx': '鹅音',
  'kg': '苟音',
  'kw': '沃音',
  'mg': '菇音',
};

String platformDisplayAlias(String key) => kPlatformDisplayAliases[key] ?? key;
