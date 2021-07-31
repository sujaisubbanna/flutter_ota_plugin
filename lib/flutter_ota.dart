library flutter_ota;

import 'dart:io';

import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter_ota/models/file_diff.model.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class FlutterOTA {
  final Future<SharedPreferences> _prefs = SharedPreferences.getInstance();
  final dmp = DiffMatchPatch();
  late String _channel;
  late String _currentCommit;
  late Map<String, Map<String, dynamic>> data;

  static const String _API_ENDPOINT = 'localhost:3006';

  Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  Future<File> _localFile(String file) async {
    final path = await _localPath;
    final filePath = '$path/$file';
    if (!File(filePath).existsSync()) {
      await File(filePath).create();
    }
    return File(filePath);
  }

  FlutterOTA({String channel = 'main'}) {
    this._channel = channel;
  }

  Future<void> init() async {
    final SharedPreferences prefs = await _prefs;
    _currentCommit = prefs.getString('CURRENT_COMMIT') ??
        '2fd7f4b00af26121e71c7265cb247f9528810074';
  }

  Future<List<FileDiff>> getLatestData() async {
    var url = Uri.http(_API_ENDPOINT, '', {
      'branch': this._channel,
      'commit': this._currentCommit,
    });
    var response = await http.get(url);
    Map<String, dynamic> data = json.decode(response.body);
    List<FileDiff> fileDiffs =
        (data['diff'] as List).map((e) => FileDiff.fromJson(e)).toList();
    return fileDiffs;
  }

  Future<void> sync() async {
    final result = await getLatestData();
    result.forEach((e) async {
      final List<Patch> patches = patchFromText(e.patches);
      final File file = await _localFile(e.file);
      final contents = await file.readAsString();
      final patchedContents = dmp.patch_apply(patches, contents);
      await file.writeAsString(patchedContents[0]);
      data[e.file.split('.')[0]] = json.decode(patchedContents[0]);
    });
  }

  dynamic getValue(String file, String key) {
    return data[file]?[key];
  }
}
