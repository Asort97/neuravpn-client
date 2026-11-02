import 'dart:io';

import 'package:happycat_vpnclient/services/subscription_request_identity.dart';
import 'package:package_info_plus/package_info_plus.dart';

SubscriptionRequestIdentity testSubscriptionIdentity(
  Directory directory, {
  String version = '1.0.14',
  String buildNumber = '14',
  String os = 'Windows',
  String model = 'Test PC',
}) => SubscriptionRequestIdentity(
  loadDeviceInfo: () async => {'os': os, 'model': model},
  loadPackageInfo: () async => PackageInfo(
    appName: 'neuravpn',
    packageName: 'com.neuravpn.app',
    version: version,
    buildNumber: buildNumber,
  ),
  supportDirectory: () async => directory,
);
