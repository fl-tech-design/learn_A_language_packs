// tools/build_packs.dart
//
// Build pipeline for the learn_A_language language packs (Ticket #68).
//
// Creates one ZIP per language (`lal-pack-<lang>-<version>.zip`) inside
// `build/` and regenerates `manifest/manifest.json` with SHA-256 checksums
// and immutable download URLs.
//
// Requirements: Dart SDK plus `zip` and `sha256sum` (Linux/macOS).
//
// Usage (from the repository root):
//   dart run tools/build_packs.dart
//
// The script is intentionally dependency-free: it orchestrates the standard
// `zip` and `sha256sum` command-line tools instead of bundling a Dart
// compression library.
//
// ZIP layout (mirrors the app's asset paths, so extracted packs work without
// path rewrites):
//   pack.json
//   language_dict/<lang>/...
//   audio/<lang>/...
//   grammar/grammar_<lang>/...   (only if present)

import 'dart:convert';
import 'dart:io';

/// Pack version. Bump this for every content change. The matching GitHub
/// Release tag is `packs-v<version>` – all download URLs are derived from it
/// and are therefore immutable.
const String packVersion = '1.0.0';

/// Format version of `pack.json` and `manifest/manifest.json`.
const int schemaVersion = 1;

/// All course languages in stable order.
const List<String> languageCodes = [
  'de', 'en', 'fr', 'es', 'el', 'ru', 'it', 'pt',
];

/// Directories that may be part of a pack, in stable order.
const List<String> packContents = [
  'language_dict',
  'audio',
  'grammar',
];

/// Minimum app version required to install these packs.
/// The app is currently at 1.12.2+26; this is the expected next release –
/// adjust here if the release number differs.
const String minAppVersion = '1.13.0';

/// Base URL for immutable download assets: versioned paths under `dist/`
/// in this repository's `main` branch (served via raw.githubusercontent.com).
const String downloadUrlBase =
    'https://raw.githubusercontent.com/fl-tech-design/learn_A_language_packs/main/dist';

const String licenseNote = 'See repository / app license';

Future<void> main() async {
  final root = Directory.current;
  if (!await Directory('${root.path}/tools').exists()) {
    stderr.writeln('ERROR: run this script from the repository root '
        '(missing tools/ in "${root.path}").');
    exitCode = 2;
    return;
  }

  final manifestDir = Directory('${root.path}/manifest');
  await manifestDir.create(recursive: true);

  final buildDir = Directory('${root.path}/build');
  if (await buildDir.exists()) await buildDir.delete(recursive: true);
  await buildDir.create(recursive: true);

  // Veröffentlichtes, versioniertes Ausgabeverzeichnis (wird committet).
  final distDir = Directory('${root.path}/dist/packs-v$packVersion');
  await distDir.create(recursive: true);

  final packs = <Map<String, dynamic>>[];

  for (final lang in languageCodes) {
    stdout.writeln('-- Building pack "$lang" ...');

    final stage = Directory('${buildDir.path}/stage_$lang');
    await stage.create(recursive: true);

    final included = <String>[];
    for (final content in packContents) {
      final source = _sourceDir(root, content, lang);
      if (await _isNonEmptyDir(source)) {
        included.add(content);
        // Ziel-Ordner VOR dem cp anlegen: erst dann legt `cp -r` den
        // Quellordner als Unterordner an (sonst würde der Sprachcode-Level
        // verloren gehen, z. B. audio/de/verbs -> audio/verbs).
        final parent = Directory('${stage.path}/$content');
        await parent.create(recursive: true);
        await _run(['cp', '-r', source.path, parent.path]);
      }
    }

    if (included.isEmpty) {
      stdout.writeln('  nothing to pack for "$lang" - skipped');
      await stage.delete(recursive: true);
      continue;
    }

    // pack.json
    final packJson = <String, dynamic>{
      'id': lang,
      'version': packVersion,
      'schema_version': schemaVersion,
      'contents': included,
      'license': licenseNote,
    };
    await File('${stage.path}/pack.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(packJson));
    stdout.writeln('  contents: ${included.join(', ')}');

    // ZIP
    final zipName = 'lal-pack-$lang-$packVersion.zip';
    final zipPath = '${distDir.path}/$zipName';
    await _run(['zip', '-r', '-q', zipPath, '.'], workingDir: stage.path);

    // SHA-256 + size
    final sha = (await _run(['sha256sum', zipPath])).trim().split(' ').first;
    final size = await File(zipPath).length();

    packs.add(<String, dynamic>{
      'id': lang,
      'version': packVersion,
      'url': '$downloadUrlBase/packs-v$packVersion/$zipName',
      'size_bytes': size,
      'sha256': sha,
      'min_app_version': minAppVersion,
      'contents': included,
    });

    stdout.writeln('  -> $zipName (${_human(size)}, sha256 $sha)');
    await stage.delete(recursive: true);
  }

  // Manifest
  final manifest = <String, dynamic>{
    'schema_version': schemaVersion,
    'version': packVersion,
    'packs': packs,
  };
  final manifestPath = '${manifestDir.path}/manifest.json';
  await File(manifestPath)
      .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
  stdout.writeln('\nManifest written: $manifestPath (${packs.length} packs)');
}

Directory _sourceDir(Directory root, String content, String lang) =>
    Directory('${root.path}/$content/'
        '${content == 'grammar' ? 'grammar_$lang' : lang}');

Future<bool> _isNonEmptyDir(Directory dir) async {
  if (!await dir.exists()) return false;
  await for (final _ in dir.list()) {
    return true;
  }
  return false;
}

Future<String> _run(List<String> cmd, {String? workingDir}) async {
  final result = await Process.run(cmd.first, cmd.sublist(1),
      workingDirectory: workingDir);
  if (result.exitCode != 0) {
    stderr.writeln('ERROR: ${cmd.join(' ')} failed with exit ${result.exitCode}');
    stderr.writeln(result.stderr);
    exitCode = 1;
    throw ProcessException(
        cmd.first, cmd.sublist(1), result.stderr, result.exitCode);
  }
  return (result.stdout as String).trim();
}

String _human(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}
