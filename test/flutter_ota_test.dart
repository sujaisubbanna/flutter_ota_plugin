import 'package:flutter_ota/diff_match_patch/DMPClass.dart';
import 'package:flutter_ota/diff_match_patch/PatchClass.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ota/flutter_ota.dart';

void main() {
  test('adds one to input values', () async {
    final flutterOTA = FlutterOTA(channel: 'main');
    final dmp = DiffMatchPatch();
    final result = await flutterOTA.init();
    final List<Patch> patches = dmp.patch_fromText(result[0].patches);
    final sample = dmp.patch_apply(patches, '''{
      "featureEnabled": false
    }''')[0];
    expect(sample, 1);
  });
}
