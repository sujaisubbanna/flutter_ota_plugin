library flutter_ota;

import 'package:flutter_ota/models/file_diff.model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class FlutterOTA {
  final Future<SharedPreferences> _prefs = SharedPreferences.getInstance();
  late String _channel;
  late String _currentCommit;
  static const String _API_ENDPOINT = 'localhost:3006';

  FlutterOTA({String channel = 'main'}) {
    this._channel = channel;
  }

  Future<List<FileDiff>> init() async {
    final SharedPreferences prefs = await _prefs;
    _currentCommit = prefs.getString('CURRENT_COMMIT') ??
        '2fd7f4b00af26121e71c7265cb247f9528810074';
    return await getLatestData();
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
}
