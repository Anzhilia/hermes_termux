/// GitHub 加速代理配置
class GitHubProxy {
  final String name;
  final String prefix;
  const GitHubProxy({required this.name, required this.prefix});
}

class AppConstants {
  static const String appName = 'Hermes Agent';
  static const String version = '2.0.2';
  static const String packageName = 'com.nousresearch.hermes';

  /// Matches ANSI escape sequences (e.g. color codes in terminal output).
  static final ansiEscape = RegExp(r'\x1b\[[0-9;]*[a-zA-Z]');

  static const String authorName = 'AnZhili';
  static const String authorEmail = 'susuya0712@gmail.com';
  static const String githubUrl =
      'https://github.com/NousResearch/hermes-agent';
  static const String license = 'MIT';

  static const String githubApiLatestRelease =
      'https://api.github.com/repos/NousResearch/hermes-agent/releases/latest';

  // NextGenX
  static const String orgName = 'NextGenX';
  static const String orgEmail = 'susuya0712@gmail.com';
  static const String instagramUrl =
      'https://www.instagram.com/nexgenxplorer_nxg';
  static const String youtubeUrl =
      'https://youtube.com/@nexgenxplorer?si=UG-wBC8UIyeT4bbw';
  static const String playStoreUrl =
      'https://play.google.com/store/apps/dev?id=8262374975871504599';

  static const String gatewayHost = '127.0.0.1';

  /// hermes gateway API Server 端口 (REST API, 供外部应用连接)
  static const int gatewayPort = 8642;
  static const String gatewayUrl = 'http://$gatewayHost:$gatewayPort';


  static const String ubuntuRootfsUrl =
      'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-';
  static const String ubuntuCodename = 'noble';
  static const String rootfsArm64 = '${ubuntuRootfsUrl}arm64.tar.gz';
  static const String rootfsArmhf = '${ubuntuRootfsUrl}armhf.tar.gz';
  static const String rootfsAmd64 = '${ubuntuRootfsUrl}amd64.tar.gz';

  static const String hermesInstallScriptUrl =
      'https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh';

  /// Proxy prefix used for terminal install method (curl | bash).
  /// Accelerates GitHub downloads via gh-proxy.com.
  static const String terminalInstallProxyPrefix = 'https://gh-proxy.com/';

  /// Bundled install.sh asset path (used by terminal install method)
  static const String bundledInstallScriptAsset =
      'assets/scripts/install.sh';

  /// NodeSource setup script URL for installing Node.js 22.x
  static const String nodejsSetupUrl =
      'https://deb.nodesource.com/setup_22.x';

  /// Default pip index URL (empty = use system default with Alibaba Cloud mirror fallback)
  static const String defaultPipIndexUrl = '';

  /// PyPI mirror list for pip install acceleration (国内用户可选)
  static const List<Map<String, String>> pypiMirrors = [
    {'name': '阿里云（推荐）', 'url': 'https://mirrors.aliyun.com/pypi/simple/'},
    {'name': '清华大学', 'url': 'https://pypi.tuna.tsinghua.edu.cn/simple/'},
    {'name': '中科大', 'url': 'https://pypi.mirrors.ustc.edu.cn/simple/'},
    {'name': '豆瓣', 'url': 'https://pypi.douban.com/simple/'},
    {'name': '官方 PyPI', 'url': 'https://pypi.org/simple/'},
  ];

  // Hermes Agent constants
  static const String hermesPyPiPackage = 'hermes-agent';

  /// GitHub 加速代理列表（国内用户可选，按优先级排序）
  /// 使用时自动拼接在 GitHub URL 前面
  static const List<GitHubProxy> githubProxies = [
    GitHubProxy(name: '直连（不加速）', prefix: ''),
    GitHubProxy(name: 'proxy.gitwarp.top（推荐）', prefix: 'https://proxy.gitwarp.top/'),
    GitHubProxy(name: 'ghfast.top', prefix: 'https://ghfast.top/'),
    GitHubProxy(name: 'gh-proxy.com', prefix: 'https://gh-proxy.com/'),
    GitHubProxy(name: 'ghproxy.net', prefix: 'https://ghproxy.net/'),
    GitHubProxy(name: 'mirror.ghproxy.com', prefix: 'https://mirror.ghproxy.com/'),
  ];

  /// 当前选中的代理索引（默认 1 = proxy.gitwarp.top，国内用户友好）
  /// 可通过设置页面动态修改
  static int _selectedProxyIndex = 1;

  static int get selectedProxyIndex => _selectedProxyIndex;
  static set selectedProxyIndex(int index) {
    if (index >= 0 && index < githubProxies.length) {
      _selectedProxyIndex = index;
    }
  }

  static GitHubProxy get currentProxy => githubProxies[_selectedProxyIndex];

  /// 对 GitHub URL 应用当前选中的代理
  static String proxiedGithubUrl(String url) {
    final proxy = currentProxy;
    if (proxy.prefix.isEmpty) return url;
    return '${proxy.prefix}$url';
  }
  static const String hermesEstimatedSize = '~120 MB';
  static const String? defaultRecommendedHermesReleaseVersion = null;
  static const String basicResourcePrebuiltRootfsArm64 = 'bundled';
  static const String basicResourceUbuntuRootfsArm64 = 'default';
  static const String hermesConfigDir = '.hermes';
  static const String hermesConfigFile = 'config.yaml';

  static String ubuntuRootfsArchiveArch(String arch) {
    final normalized = arch.trim().toLowerCase();
    if (normalized == 'aarch64' ||
        normalized == 'arm64' ||
        normalized == 'arm64-v8a') {
      return 'arm64';
    }
    if (normalized == 'arm' ||
        normalized == 'armv7l' ||
        normalized == 'armeabi-v7a' ||
        normalized == 'armhf') {
      return 'armhf';
    }
    if (normalized == 'x86_64' || normalized == 'amd64') {
      return 'amd64';
    }
    return 'arm64';
  }

  static bool isUbuntuPortsArch(String arch) {
    switch (arch) {
      case 'aarch64':
      case 'arm':
        return true;
      default:
        return false;
    }
  }

  static List<String> ubuntuMirrorCandidates(String arch) {
    final isPorts = isUbuntuPortsArch(arch);
    final paths = isPorts
        ? <String>[
            'http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports',
            'http://mirrors.ustc.edu.cn/ubuntu-ports',
            'http://mirrors.aliyun.com/ubuntu-ports',
            'http://ports.ubuntu.com/ubuntu-ports',
          ]
        : <String>[
            'http://mirrors.tuna.tsinghua.edu.cn/ubuntu',
            'http://mirrors.ustc.edu.cn/ubuntu',
            'http://mirrors.aliyun.com/ubuntu',
            'http://archive.ubuntu.com/ubuntu',
          ];
    return paths;
  }

  static String buildUbuntuSourcesList(String baseUrl) {
    final suites = <String>[
      ubuntuCodename,
      '$ubuntuCodename-updates',
      '$ubuntuCodename-backports',
      '$ubuntuCodename-security',
    ];
    final buffer = StringBuffer();
    for (final suite in suites) {
      buffer.writeln(
        'deb $baseUrl $suite main restricted universe multiverse',
      );
    }
    return buffer.toString();
  }

  static const int healthCheckIntervalMs = 5000;
  static const int maxAutoRestarts = 5;

  // Node constants
  static const int wsReconnectBaseMs = 350;
  static const double wsReconnectMultiplier = 1.7;
  static const int wsReconnectCapMs = 8000;
  static const String nodeRole = 'node';
  static const int pairingTimeoutMs = 300000;

  static const String channelName = 'com.nousresearch.hermes/native';
  static const String eventChannelName =
      'com.nousresearch.hermes/gateway_logs';
  static const String setupLogEventChannelName =
      'com.nousresearch.hermes/setup_logs';

  static String? bundledBootstrapAssetPathForUrl(String url) {
    return null;
  }

  static String? prebuiltRootfsAssetPathForArch(String arch) {
    return null;
  }

  static String getRootfsUrl(String arch) {
    switch (arch) {
      case 'aarch64':
        return rootfsArm64;
      case 'arm':
        return rootfsArmhf;
      case 'x86_64':
        return rootfsAmd64;
      default:
        return rootfsArm64;
    }
  }
}
