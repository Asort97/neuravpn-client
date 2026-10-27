abstract class ProxyLink {
  String get host;
  int get port;
  Map<String, String> get params;
  String? get tag;
  String get protocolLabel;
  String? get security => params['security'];
  String? get flow => params['flow'];
  String? get sni => params['sni'];
  String? get type => params['type'];
  bool get isReality => security == 'reality';
  bool get isTls => security == 'tls' || isReality;
}
