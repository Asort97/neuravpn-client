// Synthetic credentials and documentation-only addresses, never live accounts.
Map<String, dynamic> xraySubscriptionProfile({
  int candidates = 3,
  String owner = '11111111-1111-4111-8111-111111111111',
}) => {
  'remarks':
      '\u26a1 \u0410\u0432\u0442\u043e\u043c\u0430\u0442\u0438\u0447\u0435\u0441\u043a\u0438\u0439 \u0432\u044b\u0431\u043e\u0440',
  'log': {'loglevel': 'warning'},
  'dns': {
    'tag': 'dns_out',
    'queryStrategy': 'UseIPv4',
    'servers': ['https://1.1.1.1/dns-query'],
  },
  'inbounds': [
    {
      'tag': 'socks',
      'listen': '127.0.0.1',
      'port': 10808,
      'protocol': 'socks',
      'settings': {'auth': 'noauth', 'udp': true},
      'sniffing': {
        'enabled': true,
        'routeOnly': true,
        'destOverride': ['http', 'tls', 'quic'],
      },
    },
    {
      'tag': 'http',
      'listen': '127.0.0.1',
      'port': 10809,
      'protocol': 'http',
      'settings': {},
    },
  ],
  'outbounds': [
    for (var i = 0; i < candidates; i++)
      {
        'tag': 'auto-bypass-${i + 1}-ip-192.0.2.${i + 1}',
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': '192.0.2.${i + 1}',
              'port': 443,
              'users': [
                {'id': owner, 'encryption': 'none', 'flow': ''},
              ],
            },
          ],
        },
        'streamSettings': {
          'network': i.isEven ? 'tcp' : 'xhttp',
          'security': 'reality',
          'realitySettings': {
            'serverName': 'example.com',
            'publicKey': 'pkKO6JYPzg5UIiUdyksPj1eK5iPlA_ccqOQmDhGvhmc',
            'shortId': 'abcd',
            'fingerprint': 'chrome',
            'spiderX': '/',
          },
          if (i.isOdd)
            'xhttpSettings': {
              'path': '/',
              'host': '',
              'mode': 'auto',
              'extra': {'xPaddingBytes': '100-1000'},
            },
        },
        'mux': {'enabled': false},
      },
    {
      'tag': 'auto-hysteria2',
      'protocol': 'hysteria',
      'settings': {'version': 2, 'address': '192.0.2.22', 'port': 10010},
      'streamSettings': {
        'network': 'hysteria',
        'security': 'tls',
        'tlsSettings': {
          'serverName': 'example.com',
          'alpn': ['h3'],
        },
        'hysteriaSettings': {'version': 2, 'auth': 'test-auth'},
        'finalmask': {
          'udp': [
            {
              'type': 'salamander',
              'settings': {'password': 'test-obfs'},
            },
          ],
        },
      },
      'mux': {'enabled': false},
    },
    {'tag': 'unavailable', 'protocol': 'blackhole', 'settings': {}},
  ],
  'routing': {
    'domainStrategy': 'AsIs',
    'rules': [
      {'type': 'field', 'network': 'tcp,udp', 'balancerTag': 'auto'},
    ],
    'balancers': [
      {
        'tag': 'auto',
        'selector': ['auto-'],
        'strategy': {'type': 'leastPing'},
        'fallbackTag': 'unavailable',
      },
    ],
  },
  'observatory': {
    'subjectSelector': ['auto-'],
    'probeUrl': 'https://www.google.com/generate_204',
    'probeInterval': '60s',
    'enableConcurrency': true,
  },
};
