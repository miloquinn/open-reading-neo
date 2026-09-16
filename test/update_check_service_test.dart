import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/core/app_update_download_service.dart';
import 'package:xxread/services/core/update_check_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'check reads installed build from PackageInfo and detects build-only update',
    () async {
      PackageInfo.setMockInitialValues(
        appName: 'Origo',
        packageName: 'com.niki.xxread',
        version: '2.2.0',
        buildNumber: '14118',
        buildSignature: '',
      );
      const channel = MethodChannel('com.niki.xxread/app_update');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => '14118');
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: options.uri.host == 'open.xxread.top'
                    ? {
                        ..._websitePayload(),
                        'github_release_url':
                            'https://github.com/miloquinn/open-reading/releases/tag/v2.2.0+14119',
                      }
                    : {
                        'tag_name': 'v2.2.0+14119',
                        'html_url':
                            'https://github.com/miloquinn/open-reading/releases/tag/v2.2.0+14119',
                      },
              ),
            );
          },
        ),
      );
      final result = await UpdateCheckService(
        dio: dio,
        targetResolver: () async =>
            const UpdateTarget(platform: 'android', architecture: 'arm64-v8a'),
      ).check();
      expect(result.currentBuildNumber, '14118');
      expect(result.currentDisplayVersion, '2.2.0 (14118)');
      expect(result.hasUpdate, isTrue);
      expect(result.latestRelease.websiteAsset?.buildNumber, '14119');
      dio.close();
    },
  );

  group('build-aware updates', () {
    AppRelease release(String version, String? build) => AppRelease(
      version: version,
      buildNumber: build,
      name: 'Release',
      notes: '',
      releaseUrl: Uri.parse(
        'https://github.com/miloquinn/open-reading/releases',
      ),
      publishedAt: null,
    );

    test('compares semantic version before numeric build', () {
      for (final sample in [
        ('2.6.7', '10', '2.6.7', '9', true),
        ('2.6.7', '10', '2.6.7', '10', false),
        ('2.6.7', '9', '2.6.7', '10', false),
        ('2.6.8', '1', '2.6.7', '999', true),
        ('2.6.6', '999', '2.6.7', '1', false),
        ('2.6.7-beta.2', '999', '2.6.7', '1', false),
      ]) {
        expect(
          UpdateCheckResult(
            latestRelease: release(sample.$1, sample.$2),
            currentVersion: sample.$3,
            currentBuildNumber: sample.$4,
          ).hasUpdate,
          sample.$5,
        );
      }
    });

    test('unknown build does not invent a same-version update', () {
      expect(
        UpdateCheckResult(
          latestRelease: release('2.6.7', null),
          currentVersion: '2.6.7',
          currentBuildNumber: '10',
        ).hasUpdate,
        false,
      );
      expect(
        UpdateCheckResult(
          latestRelease: release('2.6.7', '10'),
          currentVersion: '2.6.7',
        ).hasUpdate,
        false,
      );
      expect(compareReleaseVersions('2.6.7+10', '2.6.7+9'), greaterThan(0));
    });

    test('GitHub build tags supply release identity and display', () {
      final parsed = AppRelease.fromGithubJson({
        'tag_name': 'v2.6.7+260908001',
        'html_url':
            'https://github.com/miloquinn/open-reading/releases/tag/v2.6.7+260908001',
      });
      expect(parsed.version, '2.6.7');
      expect(parsed.buildNumber, '260908001');
      expect(parsed.releaseId, '2.6.7+260908001');
      expect(parsed.displayVersion, '2.6.7 (260908001)');
    });

    test('source selection never attaches an older build download', () {
      final website = AppRelease.fromWebsiteJson({
        ..._websitePayload(),
        'github_release_url':
            'https://github.com/miloquinn/open-reading/releases/tag/v2.2.0+14119',
      });
      final newerGithub = release('2.2.0', '14120');
      expect(
        selectLatestRelease(website: website, github: newerGithub),
        same(newerGithub),
      );
      expect(
        selectLatestRelease(
          website: website,
          github: release('2.2.0', '14118'),
        ),
        same(website),
      );
      final matching = selectLatestRelease(
        website: website,
        github: release('2.2.0', '14119'),
      );
      expect(matching.websiteAsset, same(website.websiteAsset));
      expect(matching.effectiveBuildNumber, '14119');
      expect(
        selectLatestRelease(website: website, github: release('2.2.0', null)),
        same(website),
      );
    });
  });

  group('compareVersions', () {
    test('compares stable semantic versions', () {
      expect(compareVersions('v1.2.0', '1.1.9'), greaterThan(0));
      expect(compareVersions('1.0', '1.0.0'), 0);
      expect(compareVersions('0.9.1', '0.10.0'), lessThan(0));
    });

    test('treats stable versions as newer than prereleases', () {
      expect(compareVersions('1.0.0', '1.0.0-beta.2'), greaterThan(0));
      expect(compareVersions('1.0.0-beta.2', '1.0.0-beta.1'), greaterThan(0));
    });
  });

  test('parses the GitHub release payload used by the update dialog', () {
    final release = AppRelease.fromGithubJson({
      'tag_name': 'v1.2.3',
      'name': 'Origo v1.2.3',
      'body': 'Bug fixes and improvements',
      'html_url':
          'https://github.com/miloquinn/open-reading/releases/tag/v1.2.3',
      'published_at': '2026-07-12T00:00:00Z',
    });

    expect(release.version, '1.2.3');
    expect(release.notes, 'Bug fixes and improvements');
    expect(release.releaseUrl.host, 'github.com');
    expect(release.publishedAt, DateTime.utc(2026, 7, 12));
  });

  test('parses and validates official website APK metadata', () {
    final release = AppRelease.fromWebsiteJson(
      {
        'schema_version': 1,
        'version': '2.2.0',
        'build_number': '14119',
        'platform': 'android',
        'architecture': 'arm64-v8a',
        'package_type': 'apk',
        'release_notes': 'Official website updates.',
        'download_url':
            'https://open.xxread.top/download/file/open-reading-arm64.apk',
        'github_release_url':
            'https://github.com/miloquinn/open-reading/releases/tag/v2.2.0',
        'website_url': 'https://open.xxread.top/download',
        'sha256': 'a' * 64,
        'file_size': 63400000,
        'published_at': '2026-07-19T00:00:00Z',
        'mandatory': false,
      },
      targetPlatform: 'android',
      targetArchitecture: 'arm64-v8a',
    );

    expect(release.version, '2.2.0');
    expect(release.releaseUrl.host, 'github.com');
    expect(release.websiteAsset?.architecture, 'arm64-v8a');
    expect(release.websiteAsset?.fileSize, 63400000);
  });

  test(
    'Android split APK codes never compete with cross-platform build numbers',
    () {
      final website = AppRelease.fromWebsiteJson({
        ..._websitePayload(),
        'version': '2.6.7',
        'build_number': '260910001',
        'github_release_url':
            'https://github.com/miloquinn/open-reading/releases/tag/v2.6.7+260908001',
      });
      final github = AppRelease.fromGithubJson({
        'tag_name': 'v2.6.7+260908002',
        'html_url':
            'https://github.com/miloquinn/open-reading/releases/tag/v2.6.7+260908002',
      });
      expect(website.releaseBuildNumber, '260908001');
      expect(website.websiteAsset!.buildNumber, '260910001');
      expect(
        selectLatestRelease(website: website, github: github),
        same(github),
      );
      expect(
        UpdateCheckResult(
          currentVersion: '2.6.7',
          currentBuildNumber: '260908001',
          currentPackageBuildNumber: '260910001',
          latestRelease: website,
        ).hasUpdate,
        isFalse,
      );
      expect(
        UpdateCheckResult(
          currentVersion: '2.6.7',
          currentBuildNumber: '260908001',
          currentPackageBuildNumber: '260910001',
          latestRelease: github,
        ).hasUpdate,
        isTrue,
      );
      expect(
        UpdateCheckResult(
          currentVersion: '2.6.7',
          currentBuildNumber: '260907001',
          currentPackageBuildNumber: '260909001',
          latestRelease: website,
        ).hasUpdate,
        isTrue,
      );
      expect(website.displayVersion, '2.6.7 (260908001)');
      expect(
        UpdateCheckResult(
          currentVersion: '2.6.7',
          currentBuildNumber: '',
          currentPackageBuildNumber: '260909001',
          latestRelease: website,
        ).hasUpdate,
        isTrue,
      );
      expect(
        UpdateCheckResult(
          currentVersion: '2.6.7',
          currentBuildNumber: '',
          currentPackageBuildNumber: '260910001',
          latestRelease: website,
        ).hasUpdate,
        isFalse,
      );
      expect(
        UpdateCheckResult(
          currentVersion: '2.6.7',
          currentBuildNumber: '',
          currentPackageBuildNumber: '260909001',
          latestRelease: github,
        ).hasUpdate,
        isFalse,
      );
    },
  );

  test('rejects conflicting website version metadata and artifact build', () {
    expect(
      () => AppRelease.fromWebsiteJson({
        ..._websitePayload(),
        'version': '2.2.0+14120',
      }),
      throwsFormatException,
    );
    final matching = AppRelease.fromWebsiteJson({
      ..._websitePayload(),
      'version': '2.2.0+14119',
    });
    expect(matching.version, '2.2.0');
    expect(matching.effectiveBuildNumber, '14119');
  });

  test('rejects APK download URLs outside the official HTTPS host', () {
    expect(
      () => AppRelease.fromWebsiteJson({
        'version': '2.2.0',
        'build_number': '14119',
        'platform': 'android',
        'architecture': 'arm64-v8a',
        'package_type': 'apk',
        'download_url': 'https://example.com/open-reading.apk',
        'github_release_url':
            'https://github.com/miloquinn/open-reading/releases/tag/v2.2.0',
        'website_url': 'https://open.xxread.top/download',
        'sha256': 'a' * 64,
        'file_size': 42,
      }),
      throwsFormatException,
    );
  });

  test('rejects official metadata for the wrong platform or ABI', () {
    expect(
      () => AppRelease.fromWebsiteJson(
        {..._websitePayload(), 'platform': 'windows'},
        targetPlatform: 'android',
        targetArchitecture: 'arm64-v8a',
      ),
      throwsFormatException,
    );
    expect(
      () => AppRelease.fromWebsiteJson(
        {..._websitePayload(), 'architecture': 'x86_64'},
        targetPlatform: 'android',
        targetArchitecture: 'arm64-v8a',
      ),
      throwsFormatException,
    );
  });

  test('rejects an assets payload without an exact ABI match', () {
    final topLevel = _websitePayload()
      ..remove('architecture')
      ..remove('download_url')
      ..remove('sha256')
      ..remove('file_size')
      ..['assets'] = [
        {
          'platform': 'android',
          'architecture': 'x86_64',
          'package_type': 'apk',
          'build_number': '16119',
          'download_url':
              'https://open.xxread.top/download/file/open-reading-x64.apk',
          'sha256': 'b' * 64,
          'file_size': 42,
        },
      ];

    expect(
      () => AppRelease.fromWebsiteJson(
        topLevel,
        targetPlatform: 'android',
        targetArchitecture: 'arm64-v8a',
      ),
      throwsFormatException,
    );
  });

  test('rejects GitHub links outside the canonical repository', () {
    expect(
      () => AppRelease.fromGithubJson({
        'tag_name': 'v2.2.0',
        'html_url':
            'https://github.com/attacker/open-reading/releases/tag/v2.2.0',
      }),
      throwsFormatException,
    );
    expect(
      () => AppRelease.fromWebsiteJson({
        ..._websitePayload(),
        'github_release_url':
            'https://github.com/attacker/open-reading/releases/tag/v2.2.0',
      }),
      throwsFormatException,
    );
  });

  test('selects the higher source version and merges equal releases', () {
    final website = AppRelease.fromWebsiteJson(
      _websitePayload(),
      targetPlatform: 'android',
      targetArchitecture: 'arm64-v8a',
    );
    AppRelease github(String version) => AppRelease(
      version: version,
      name: 'Origo v$version',
      notes: 'GitHub notes',
      releaseUrl: Uri.parse(
        'https://github.com/miloquinn/open-reading/releases/tag/v$version',
      ),
      publishedAt: null,
    );

    expect(
      selectLatestRelease(website: website, github: github('2.1.0')),
      same(website),
    );
    expect(
      selectLatestRelease(
        website: website,
        github: github('2.3.0'),
      ).websiteAsset,
      isNull,
    );
    expect(
      selectLatestRelease(
        website: website,
        github: github('2.2.0'),
      ).websiteAsset?.architecture,
      'arm64-v8a',
    );
  });

  test('rejects official APK metadata above the hard size limit', () {
    expect(
      () => AppRelease.fromWebsiteJson(
        {..._websitePayload(), 'file_size': maxOfficialApkSizeBytes + 1},
        targetPlatform: 'android',
        targetArchitecture: 'arm64-v8a',
      ),
      throwsFormatException,
    );
  });

  test(
    'detects received bytes or content length above metadata immediately',
    () {
      expect(
        isUpdateDownloadProgressOverLimit(
          received: 101,
          total: -1,
          expectedFileSize: 100,
        ),
        isTrue,
      );
      expect(
        isUpdateDownloadProgressOverLimit(
          received: 1,
          total: 101,
          expectedFileSize: 100,
        ),
        isTrue,
      );
      expect(
        isUpdateDownloadProgressOverLimit(
          received: 100,
          total: 100,
          expectedFileSize: 100,
        ),
        isFalse,
      );
    },
  );
}

Map<String, dynamic> _websitePayload() => {
  'schema_version': 1,
  'version': '2.2.0',
  'build_number': '14119',
  'platform': 'android',
  'architecture': 'arm64-v8a',
  'package_type': 'apk',
  'release_notes': 'Official website updates.',
  'download_url':
      'https://open.xxread.top/download/file/open-reading-arm64.apk',
  'github_release_url':
      'https://github.com/miloquinn/open-reading/releases/tag/v2.2.0',
  'website_url': 'https://open.xxread.top/download',
  'sha256': 'a' * 64,
  'file_size': 63400000,
  'published_at': '2026-07-19T00:00:00Z',
  'mandatory': false,
};
