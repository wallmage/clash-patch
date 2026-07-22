const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '..');
const enginePath = path.join(root, 'clash-patch/scripts/windows/clash_verge_global.js');
const policyPath = path.join(root, 'clash-patch/references/policy.json');
const installerPath = path.join(root, 'clash-patch/scripts/install_windows.ps1');
const uninstallerPath = path.join(root, 'clash-patch/scripts/uninstall_windows.ps1');
const routeVerifierPath = path.join(root, 'clash-patch/scripts/windows/verify_routes.ps1');
const installWrapperPath = path.join(root, 'clash-patch/scripts/install_windows.cmd');
const uninstallWrapperPath = path.join(root, 'clash-patch/scripts/uninstall_windows.cmd');
const fixturePath = path.join(root, 'tests/fixtures/main_group_cases.json');
const available = fs.existsSync(enginePath) && fs.existsSync(policyPath);
const fixturesAvailable = available && fs.existsSync(fixturePath);
const engine = available ? require(enginePath) : null;

test('Windows engine files exist', () => {
  assert.equal(fs.existsSync(enginePath), true, 'Windows enhancement script is missing');
  assert.equal(fs.existsSync(policyPath), true, 'canonical policy is missing');
});

test('global transform applies common policy', { skip: !available }, () => {
  const patched = engine.clashPatchTransform(baseConfig(), 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === 'AI');
  const safeGroup = engine.clashPatchRouteGroupName(patched);

  assert.equal(patched.ipv6, false);
  assert.equal(patched.dns.ipv6, false);
  assert.deepEqual(patched.tun['dns-hijack'], ['any:53', 'tcp://any:53']);
  assert.deepEqual(patched.dns['direct-nameserver'], engine.CLASH_PATCH_POLICY.directResolvers);
  assert.equal(patched.dns['direct-nameserver-follow-policy'], false);
  assert.deepEqual(patched.dns['nameserver-policy']['geosite:cn'], engine.CLASH_PATCH_POLICY.directResolvers);
  assert.ok(patched.dns['nameserver-policy']['+.openai.com'].every((value) => value.endsWith(`#${ai.name}`)));
  assert.deepEqual(ai.proxies, ['Main']);
  const udpIndex = patched.rules.indexOf(`NETWORK,UDP,${ai.name}`);
  assert.ok(udpIndex >= 0);
  assert.equal(patched.rules[udpIndex + 1], 'NETWORK,UDP,REJECT');
  assert.equal(udpIndex, 0);
  assert.ok(patched.rules.includes('DOMAIN,raw.githubusercontent.com,AI'));
  assert.ok(patched.rules.includes('DOMAIN,storage.googleapis.com,AI'));
});

test('reuses the existing AI group without creating visible groups', { skip: !available }, () => {
  const config = baseConfig();
  const originalAi = structuredClone(config['proxy-groups'].find((group) => group.name === 'AI'));

  const patched = engine.clashPatchTransform(config, 'fixture');

  assert.deepEqual(patched['proxy-groups'].find((group) => group.name === 'AI'), originalAi);
  assert.equal(patched['proxy-groups'].some((group) => /^🤖 AI · Clash Patch(?: \d+)?$/.test(group.name)), false);
  assert.equal(patched['proxy-groups'].some((group) => /^🛡 安全代理 · Clash Patch(?: \d+)?$/.test(group.name)), false);
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,openai.com,AI'));
  assert.deepEqual(patched.rules.slice(0, 2), ['NETWORK,UDP,AI', 'NETWORK,UDP,REJECT']);
  assert.ok(patched.dns.nameserver.every((value) => value.endsWith('#Main')));
  assert.ok(patched.dns['nameserver-policy']['+.openai.com'].every((value) => value.endsWith('#AI')));
});

test('creates an AI group with all inline nodes when the subscription has none', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');

  const patched = engine.clashPatchTransform(config, 'fixture');

  const ai = patched['proxy-groups'].find((group) => group.name === '🤖 AI · Clash Patch');
  assert.deepEqual(ai.proxies, ['台湾家宽 01', '日本家宽 01', '美国家宽 01']);
  assert.equal(Object.hasOwn(ai, 'use'), false);
  assert.equal(patched['proxy-groups'].some((group) => /^🛡 安全代理 · Clash Patch(?: \d+)?$/.test(group.name)), false);
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,openai.com,🤖 AI · Clash Patch'));
  assert.deepEqual(patched.rules.slice(0, 2), ['NETWORK,UDP,🤖 AI · Clash Patch', 'NETWORK,UDP,REJECT']);
  assert.ok(patched.dns['nameserver-policy']['+.openai.com'].every((value) => value.endsWith('#🤖 AI · Clash Patch')));
});

test('new AI group includes every proxy provider', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  config['proxy-providers'] = {
    'airport-a': { type: 'http', url: 'https://example.invalid/a' },
    'airport-b': { type: 'file', path: './providers/b.yaml' }
  };

  const patched = engine.clashPatchTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === '🤖 AI · Clash Patch');

  assert.deepEqual(ai.proxies, ['台湾家宽 01', '日本家宽 01', '美国家宽 01']);
  assert.deepEqual(ai.use, ['airport-a', 'airport-b']);
});

test('new AI group supports provider-only subscriptions', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies = [];
  config['proxy-groups'] = [{ name: 'Main', type: 'select', use: ['airport-a'] }];
  config['proxy-providers'] = {
    'airport-a': { type: 'http', url: 'https://example.invalid/a' }
  };
  config.rules = ['MATCH,Main'];

  const first = engine.clashPatchTransform(config, 'fixture');
  const ai = first['proxy-groups'].find((group) => group.name === '🤖 AI · Clash Patch');

  assert.deepEqual(ai.proxies, []);
  assert.deepEqual(ai.use, ['airport-a']);
  assert.deepEqual(engine.clashPatchTransform(first, 'fixture'), first);
});

test('does not create an AI group without nodes or providers', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies = [];
  delete config['proxy-providers'];
  config['proxy-groups'] = [{ name: 'Main', type: 'select', proxies: ['Ghost'] }];
  config.rules = ['MATCH,Main'];

  assert.deepEqual(engine.clashPatchTransform(config, 'fixture'), config);
});

test('migrates owned single-main AI group to an independent node selector', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  const aiName = '🤖 AI · Clash Patch';
  config['proxy-groups'].push({ name: aiName, type: 'select', proxies: ['Main'] });
  config.rules = engine.clashPatchRenderAiRules(aiName).concat(config.rules);

  const patched = engine.clashPatchTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === aiName);

  assert.deepEqual(ai.proxies, ['台湾家宽 01', '日本家宽 01', '美国家宽 01']);
  assert.equal(ai.proxies.includes('Main'), false);
});

test('removes groups created by an older patch', { skip: !available }, () => {
  const config = baseConfig();
  const aiName = '🤖 AI · Clash Patch';
  const safeName = '🛡 安全代理 · Clash Patch';
  config['proxy-groups'].push({ name: aiName, type: 'select', proxies: ['台湾家宽 01'] });
  config['proxy-groups'].push({
    name: safeName, type: 'select', proxies: ['台湾家宽 01', '日本家宽 01'],
    'include-all': true, 'exclude-type': 'Direct|Dns|Reject|Pass|Compatible|Rematch', 'empty-fallback': 'REJECT'
  });
  config.dns.nameserver = [`https://dns.alidns.com/dns-query#${safeName}`];
  config.dns['nameserver-policy'] = { '+.openai.com': [`https://dns.alidns.com/dns-query#${safeName}`] };
  config.rules = [`NETWORK,UDP,${safeName}`, 'NETWORK,UDP,REJECT']
    .concat(engine.clashPatchRenderAiRules(aiName), config.rules);

  const patched = engine.clashPatchTransform(config, 'fixture');

  assert.equal(patched['proxy-groups'].some((group) => group.name === aiName || group.name === safeName), false);
  assert.equal(patched.rules.some((rule) => rule.includes(aiName) || rule.includes(safeName)), false);
  assert.equal(JSON.stringify(patched.dns).includes(safeName), false);
  assert.deepEqual(patched.rules.slice(0, 2), ['NETWORK,UDP,AI', 'NETWORK,UDP,REJECT']);
});

test('preserves bootstrap and replaces direct resolvers with managed mainland DoH', { skip: !available }, () => {
  const config = baseConfig();
  config.dns['default-nameserver'] = ['223.5.5.5', '119.29.29.29'];
  config.dns['proxy-server-nameserver'] = ['223.5.5.5', '120.53.53.53'];
  config.dns['direct-nameserver'] = ['system'];

  const dns = engine.clashPatchTransform(config, 'fixture').dns;

  assert.deepEqual(dns['default-nameserver'], ['223.5.5.5', '119.29.29.29']);
  assert.deepEqual(dns['proxy-server-nameserver'], ['223.5.5.5', '120.53.53.53']);
  assert.deepEqual(dns['direct-nameserver'], engine.CLASH_PATCH_POLICY.directResolvers);
  assert.equal(dns['direct-nameserver-follow-policy'], false);
});

test('managed DNS uses bootstrap-free IP DoH and rewrites other endpoints', { skip: !available }, () => {
  const expectedResolvers = [
    'https://94.140.14.140/dns-query',
    'https://94.140.14.141/dns-query',
    'https://101.101.101.101/dns-query'
  ];
  assert.deepEqual(engine.CLASH_PATCH_POLICY.resolvers, expectedResolvers);
  assert.deepEqual(engine.CLASH_PATCH_POLICY.directResolvers, [
    'https://223.5.5.5/dns-query#DIRECT',
    'https://1.12.12.12/dns-query#DIRECT'
  ]);

  const config = baseConfig();
  config.dns['proxy-server-nameserver'] = ['223.5.5.5', '120.53.53.53'];
  config.dns['nameserver-policy'] = {
    '+.hostname-resolver.example': ['https://dns.alidns.com/dns-query#台湾家宽 01'],
    '+.blocked-prone.example': ['https://8.8.8.8/dns-query#台湾家宽 01'],
    '+.managed.example': ['https://94.140.14.140/dns-query#台湾家宽 01']
  };

  const patched = engine.clashPatchTransform(config, 'fixture');
  const policies = patched.dns['nameserver-policy'];
  const managed = expectedResolvers.map((resolver) => `${resolver}#台湾家宽 01`);

  assert.deepEqual(policies['+.hostname-resolver.example'], managed);
  assert.deepEqual(policies['+.blocked-prone.example'], managed);
  assert.deepEqual(policies['+.managed.example'], managed);
  assert.deepEqual(patched.dns['proxy-server-nameserver'], ['223.5.5.5', '120.53.53.53']);
});

test('uses system only when proxy bootstrap is missing', { skip: !available }, () => {
  const dns = engine.clashPatchTransform(baseConfig(), 'fixture').dns;

  assert.equal(Object.hasOwn(dns, 'default-nameserver'), false);
  assert.deepEqual(dns['proxy-server-nameserver'], ['system']);
  assert.deepEqual(dns['direct-nameserver'], engine.CLASH_PATCH_POLICY.directResolvers);
  assert.equal(dns['direct-nameserver-follow-policy'], false);
});

test('migrates the old unsafe bootstrap signature to system', { skip: !available }, () => {
  const config = baseConfig();
  config.dns['default-nameserver'] = ['1.1.1.1', '8.8.8.8'];
  config.dns['proxy-server-nameserver'] = ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query'];

  const dns = engine.clashPatchTransform(config, 'fixture').dns;

  assert.deepEqual(dns['default-nameserver'], ['system']);
  assert.deepEqual(dns['proxy-server-nameserver'], ['system']);
});

test('main delegates to the same transform', { skip: !available }, () => {
  assert.deepEqual(engine.main(baseConfig(), 'fixture'), engine.clashPatchTransform(baseConfig(), 'fixture'));
});

test('transform is idempotent', { skip: !available }, () => {
  const once = engine.clashPatchTransform(baseConfig(), 'fixture');
  const twice = engine.clashPatchTransform(once, 'fixture');
  assert.deepEqual(twice, once);
});

test('global transform verifies a second pass before returning a candidate', () => {
  const source = fs.readFileSync(enginePath, 'utf8');

  assert.match(source, /function clashPatchApply/);
  assert.match(source, /const secondPass = clashPatchApply\(clashPatchClone\(candidate\)/);
  assert.match(source, /JSON\.stringify\(candidate\) !== JSON\.stringify\(secondPass\)/);
});

test('new AI group lists US home broadband without auto selecting it', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies = config.proxies.filter((proxy) => proxy.name === '美国家宽 01');
  config['proxy-groups'] = [{ name: 'Main', type: 'select', proxies: ['美国家宽 01'] }];
  const patched = engine.clashPatchTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === '🤖 AI · Clash Patch');
  assert.deepEqual(ai.proxies, ['美国家宽 01']);
  assert.equal(Object.hasOwn(ai, 'now'), false);
});

test('does not select Japan home broadband automatically', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies = config.proxies.filter((proxy) => !proxy.name.includes('台湾'));
  config['proxy-groups'][0].proxies = config['proxy-groups'][0].proxies.filter((name) => !name.includes('台湾'));
  const patched = engine.clashPatchTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === 'AI');
  assert.deepEqual(ai.proxies, ['Main']);
});

test('puts the UDP guard ahead of a narrow rule set', { skip: !available }, () => {
  const config = baseConfig();
  config.rules.splice(2, 0, 'RULE-SET,private-special,DIRECT');
  const rules = engine.clashPatchTransform(config, 'fixture').rules;
  const udpIndex = rules.findIndex((rule) => rule.startsWith('NETWORK,UDP,') && rule !== 'NETWORK,UDP,REJECT');
  assert.equal(udpIndex, 0);
  assert.equal(rules[udpIndex + 1], 'NETWORK,UDP,REJECT');
  assert.ok(udpIndex < rules.indexOf('GEOSITE,CN,DIRECT'));
  assert.ok(udpIndex < rules.indexOf('RULE-SET,private-special,DIRECT'));
});

test('preserves a user AI target ahead of the managed rule', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'].push({ name: 'MyGroup', type: 'select', proxies: ['台湾家宽 01'] });
  const userRule = 'DOMAIN-SUFFIX,openai.com,MyGroup';
  config.rules.unshift(userRule);
  const patched = engine.clashPatchTransform(config, 'fixture');
  const managed = 'DOMAIN-SUFFIX,openai.com,AI';
  assert.equal(patched.rules.filter((rule) => rule === userRule).length, 1);
  assert.ok(patched.rules.indexOf(userRule) < patched.rules.indexOf(managed));
});

test('main-group AI rules do not bypass the independent AI selector', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  const providerRules = [
    'DOMAIN-SUFFIX,openai.com,Main',
    'DOMAIN-SUFFIX,claude.ai,Main',
    'DOMAIN-KEYWORD,openai,Main'
  ];
  config.rules = providerRules.concat(config.rules);

  const patched = engine.clashPatchTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === '🤖 AI · Clash Patch');

  for (const rule of providerRules) assert.equal(patched.rules.includes(rule), false, rule);
  assert.ok(patched.rules.includes(`DOMAIN-SUFFIX,openai.com,${ai.name}`));
  assert.ok(patched.rules.includes(`DOMAIN-SUFFIX,claude.ai,${ai.name}`));
  assert.ok(patched.rules.includes(`DOMAIN-KEYWORD,openai,${ai.name}`));
});

test('UDP guard precedes leaking rules without deleting them', { skip: !available }, () => {
  const config = baseConfig();
  const userRules = [
    'NETWORK,udp,DIRECT',
    'NETWORK, UDP, DIRECT',
    'DST-PORT,3478,DIRECT',
    'PROCESS-NAME,chrome.exe,DIRECT'
  ];
  config.rules = userRules.concat(config.rules);
  const patched = engine.clashPatchTransform(config, 'fixture');
  const guard = 'NETWORK,UDP,AI';
  assert.equal(patched.rules.indexOf(guard), 0);
  assert.equal(patched.rules[1], 'NETWORK,UDP,REJECT');
  for (const rule of userRules) {
    assert.ok(patched.rules.includes(rule), rule);
    assert.ok(patched.rules.indexOf(guard) < patched.rules.indexOf(rule), rule);
  }
});

test('managed AI rules precede every rule set', { skip: !available }, () => {
  const config = baseConfig();
  config.rules = ['RULE-SET,gfw,DIRECT', 'RULE-SET,geolocation-!cn,Main', 'MATCH,Main'];
  const patched = engine.clashPatchTransform(config, 'fixture');
  const managed = patched.rules.find((rule) => rule.startsWith('DOMAIN-SUFFIX,openai.com,🤖 AI · Clash Patch'));
  assert.ok(patched.rules.indexOf(managed) < patched.rules.indexOf('RULE-SET,gfw,DIRECT'));
  assert.ok(patched.rules.indexOf(managed) < patched.rules.indexOf('RULE-SET,geolocation-!cn,Main'));
});

test('exports the canonical policy without divergence', { skip: !available }, () => {
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  const mapping = {
    version: 'version',
    resolvers: 'resolvers',
    direct_resolvers: 'directResolvers',
    bootstrap_fallback_resolvers: 'bootstrapFallbackResolvers',
    main_group_names: 'mainGroupNames',
    ai_group_names: 'aiGroupNames',
    taiwan_tokens: 'taiwanTokens',
    japan_tokens: 'japanTokens',
    forbidden_ai_domains: 'forbiddenAiDomains',
    legacy_ai_rules: 'legacyAiRules',
    ai_rules: 'aiRules'
  };
  for (const [jsonKey, jsKey] of Object.entries(mapping)) {
    assert.deepEqual(engine.CLASH_PATCH_POLICY[jsKey], policy[jsonKey], `policy divergence at ${jsonKey}`);
  }
});

test('unknown policy version is rejected without mutation', { skip: !available }, () => {
  const config = baseConfig();
  const snapshot = JSON.parse(JSON.stringify(config));
  const originalVersion = engine.CLASH_PATCH_POLICY.version;
  try {
    engine.CLASH_PATCH_POLICY.version = 2;
    assert.deepEqual(engine.clashPatchTransform(config, 'fixture'), config);
    assert.deepEqual(config, snapshot);
  } finally {
    engine.CLASH_PATCH_POLICY.version = originalVersion;
  }
});

test('shared main-group fixtures match the Ruby engine', { skip: !fixturesAvailable }, () => {
  const cases = JSON.parse(fs.readFileSync(fixturePath, 'utf8')).cases;
  for (const fixture of cases) {
    const snapshot = JSON.parse(JSON.stringify(fixture.config));
    assert.equal(engine.clashPatchDetectMain(fixture.config), fixture.expected_main_group, fixture.name);
    if (fixture.expected_main_group === null) {
      engine.clashPatchTransform(fixture.config, 'fixture');
      assert.deepEqual(fixture.config, snapshot, fixture.name);
    }
  }
});

test('keeps a non-select AI group and creates a non-conflicting selector', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  config['proxy-groups'].push({ name: 'AI', type: 'url-test', proxies: ['台湾家宽 01'], url: 'https://example.invalid', interval: 300 });
  const patched = engine.clashPatchTransform(config, 'fixture');

  const original = patched['proxy-groups'].find((group) => group.name === 'AI');
  assert.equal(original.type, 'url-test');
  const created = patched['proxy-groups'].find((group) => group.name === '🤖 AI · Clash Patch');
  assert.ok(created, 'a new AI selector must be created');
  assert.equal(created.type, 'select');
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,openai.com,🤖 AI · Clash Patch'));
  assert.ok(patched.rules.includes('NETWORK,UDP,🤖 AI · Clash Patch'));
  for (const group of patched['proxy-groups']) {
    assert.ok(!(Array.isArray(group.proxies) && group.proxies.includes(group.name)), `group ${group.name} references itself`);
  }
});

test('an AI-only selectable group is never the main group', { skip: !available }, () => {
  const config = {
    proxies: [{ name: '台湾家宽 01', type: 'ss', server: 'tw.example' }],
    'proxy-groups': [{ name: 'AI', type: 'select', proxies: ['台湾家宽 01'] }],
    rules: ['MATCH,AI']
  };
  const snapshot = JSON.parse(JSON.stringify(config));

  assert.equal(engine.clashPatchDetectMain(config), null);
  engine.clashPatchTransform(config, 'fixture');
  assert.deepEqual(config, snapshot);
});

test('patches and preserves a provider-only profile', { skip: !available }, () => {
  const providers = { provider1: { type: 'http', url: 'https://example.invalid/sub', interval: 3600 } };
  const config = {
    'proxy-providers': providers,
    'proxy-groups': [
      { name: 'Main', type: 'select', use: ['provider1'] },
      { name: 'AI', type: 'select', use: ['provider1'] }
    ],
    rules: ['MATCH,Main']
  };
  const patched = engine.clashPatchTransform(config, 'fixture');

  assert.equal(engine.clashPatchDetectMain(config), 'Main');
  assert.deepEqual(patched['proxy-providers'], providers);
  assert.deepEqual(patched['proxy-groups'].find((group) => group.name === 'Main').use, ['provider1']);
  assert.ok(patched.rules.includes('NETWORK,UDP,AI'));
  for (const group of patched['proxy-groups']) {
    assert.ok(!(Array.isArray(group.proxies) && group.proxies.includes(group.name)), `group ${group.name} references itself`);
  }
});

test('composes an existing main before Clash Patch', { skip: !available }, () => {
  const previous = (config) => {
    config.marker = 'previous-ran';
    return config;
  };
  const patched = engine.clashPatchCompose(previous, baseConfig(), 'fixture');
  assert.equal(patched.marker, 'previous-ran');
  assert.equal(patched.ipv6, false);
});

test('returns invalid configurations unchanged', { skip: !available }, () => {
  const invalid = { message: '401 unauthorized' };
  assert.deepEqual(engine.clashPatchTransform(invalid, 'fixture'), invalid);
});

test('PowerShell installer uses the documented global script and app settings', () => {
  assert.equal(fs.existsSync(installerPath), true, 'Windows installer is missing');
  const source = fs.readFileSync(installerPath, 'utf8');
  assert.match(source, /io\.github\.clash-verge-rev\.clash-verge-rev/);
  assert.match(source, /profiles[\\/]Script\.js/);
  assert.match(source, /enable_tun_mode/);
  assert.match(source, /enable_dns_settings/);
  assert.match(source, /config\.yaml/);
  assert.match(source, /\.backup/);
  assert.match(source, /[\p{Script=Han}]/u);
  assert.match(source, /function Build-GlobalScript/);
  assert.match(source, /function Write-Utf8Atomic/);
  const preflight = source.indexOf('$scriptOutput = Build-GlobalScript');
  const firstBackup = source.indexOf('Backup-Versioned $target.Path $backupRoot "prewrite"');
  assert.ok(preflight !== -1 && firstBackup !== -1 && preflight < firstBackup, 'all transformations must be prepared before files change');
});

// Static contract only: pwsh is unavailable on macOS, so exit codes cannot be
// executed natively here. Verify on Windows before relying on them.
test('PowerShell installer keeps exit codes by avoiding Write-Error', () => {
  const source = fs.readFileSync(installerPath, 'utf8');
  assert.doesNotMatch(source, /\bWrite-Error\b/, 'Write-Error becomes terminating under $ErrorActionPreference = "Stop"');
  assert.match(source, /\[Console\]::Error\.WriteLine/);
  for (const code of ['exit 0', 'exit 1', 'exit 2', 'exit 3']) {
    assert.ok(source.includes(code), `missing ${code}`);
  }
  const notFound = source.indexOf('没有找到受支持的 Clash Verge Rev');
  assert.ok(notFound !== -1 && source.indexOf('exit 2') > notFound, 'missing client must exit 2');
  const missingEngine = source.indexOf('安装包不完整');
  assert.ok(missingEngine !== -1 && source.indexOf('exit 3') > missingEngine, 'missing engine must exit 3');
  const failure = source.indexOf('安装失败');
  assert.ok(failure !== -1 && source.lastIndexOf('exit 1') > failure, 'install failure must exit 1');
});

test('DNS fragments must resolve to a non-direct proxy or group', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'].push({ name: 'SafeExisting', type: 'select', proxies: ['台湾家宽 01'] });
  config['proxy-groups'].push({ name: 'CanDirect', type: 'select', proxies: ['台湾家宽 01', 'DIRECT'] });
  config.dns['nameserver-policy'] = {
    '+.proxy.example': ['https://1.1.1.1/dns-query#台湾家宽 01'],
    '+.group.example': ['https://1.1.1.1/dns-query#SafeExisting'],
    '+.direct.example': ['https://1.1.1.1/dns-query#CanDirect'],
    '+.option.example': ['https://1.1.1.1/dns-query#h3=true'],
    '+.interface.example': ['https://1.1.1.1/dns-query#en0']
  };
  const patched = engine.clashPatchTransform(config, 'fixture');
  const policy = patched.dns['nameserver-policy'];
  assert.deepEqual(policy['+.proxy.example'], engine.CLASH_PATCH_POLICY.resolvers.map((resolver) => `${resolver}#台湾家宽 01`));
  assert.deepEqual(policy['+.group.example'], engine.CLASH_PATCH_POLICY.resolvers.map((resolver) => `${resolver}#SafeExisting`));
  for (const pattern of ['+.direct.example', '+.option.example', '+.interface.example']) {
    assert.ok(policy[pattern].every((value) => value.endsWith(`#${engine.clashPatchRouteGroupName(patched)}`)), pattern);
  }
});

test('DNS policy rejects plaintext and dynamic group targets', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-providers'] = { provider1: { type: 'http', url: 'https://example.invalid/sub' } };
  config['proxy-groups'].push({ name: 'ProviderGroup', type: 'select', use: ['provider1'] });
  config['proxy-groups'].push({ name: 'IncludeAllGroup', type: 'select', 'include-all': true, 'exclude-type': 'Indirect' });
  config.dns['nameserver-policy'] = {
    '+.encrypted.example': ['https://1.1.1.1/dns-query#台湾家宽 01'],
    '+.plaintext.example': ['1.1.1.1#台湾家宽 01'],
    '+.provider.example': ['https://1.1.1.1/dns-query#ProviderGroup'],
    '+.include-all.example': ['https://1.1.1.1/dns-query#IncludeAllGroup']
  };
  const patched = engine.clashPatchTransform(config, 'fixture');
  const policies = patched.dns['nameserver-policy'];
  const safeSuffix = `#${engine.clashPatchRouteGroupName(patched)}`;
  assert.deepEqual(policies['+.encrypted.example'], engine.CLASH_PATCH_POLICY.resolvers.map((resolver) => `${resolver}#台湾家宽 01`));
  for (const pattern of ['+.plaintext.example', '+.provider.example', '+.include-all.example']) {
    assert.ok(policies[pattern].every((endpoint) => endpoint.endsWith(safeSuffix)), pattern);
  }
});

test('DNS policy accounts for exclusion, empty fallback, and DNS outbounds', { skip: !available }, () => {
  const config = baseConfig();
  const originalMain = structuredClone(config['proxy-groups'].find((group) => group.name === 'Main'));
  config.proxies.push({ name: 'InternalDNS', type: 'dns' });
  config['proxy-groups'].push(
    { name: 'FilteredToCompatible', type: 'select', proxies: ['台湾家宽 01'], 'exclude-filter': '台湾' },
    {
      name: 'FilteredToSafeProxy', type: 'select', proxies: ['台湾家宽 01'],
      'exclude-filter': '台湾', 'empty-fallback': '日本家宽 01'
    },
    { name: 'DnsOutboundGroup', type: 'select', proxies: ['InternalDNS'] }
  );
  config.dns['nameserver-policy'] = {
    '+.compatible.example': ['https://1.1.1.1/dns-query#FilteredToCompatible'],
    '+.fallback.example': ['https://1.1.1.1/dns-query#FilteredToSafeProxy'],
    '+.dns-out.example': ['https://1.1.1.1/dns-query#DnsOutboundGroup']
  };

  const patched = engine.clashPatchTransform(config, 'fixture');
  const policies = patched.dns['nameserver-policy'];
  const safeName = engine.clashPatchRouteGroupName(patched);
  const safeSuffix = `#${safeName}`;
  const mainGroup = patched['proxy-groups'].find((group) => group.name === safeName);
  assert.ok(policies['+.compatible.example'].every((endpoint) => endpoint.endsWith(safeSuffix)));
  assert.deepEqual(policies['+.fallback.example'], engine.CLASH_PATCH_POLICY.resolvers.map((resolver) => `${resolver}#FilteredToSafeProxy`));
  assert.ok(policies['+.dns-out.example'].every((endpoint) => endpoint.endsWith(safeSuffix)));
  assert.deepEqual(mainGroup, originalMain);
});

test('DNS policy rejects unsafe group filters and honors case-insensitive exclusions', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies.push(
    { name: 'Taiwan Backup', type: 'ss', server: 'tw-backup.example', password: 'fixture-secret' },
    { name: 'Japan Backup', type: 'ss', server: 'jp-backup.example', password: 'fixture-secret' }
  );
  config['proxy-groups'].push(
    { name: 'CaseFiltered', type: 'select', proxies: ['Taiwan Backup', 'Japan Backup'], 'exclude-filter': '(?i)taiwan' },
    { name: 'InvalidFilter', type: 'select', proxies: ['Japan Backup'], 'exclude-filter': '[' }
  );
  config.dns['nameserver-policy'] = {
    '+.case-filtered.example': ['https://1.1.1.1/dns-query#CaseFiltered'],
    '+.invalid-filter.example': ['https://1.1.1.1/dns-query#InvalidFilter']
  };

  const patched = engine.clashPatchTransform(config, 'fixture');
  const routeGroup = engine.clashPatchRouteGroupName(patched);
  assert.deepEqual(
    patched.dns['nameserver-policy']['+.case-filtered.example'],
    engine.CLASH_PATCH_POLICY.resolvers.map((resolver) => `${resolver}#CaseFiltered`)
  );
  assert.ok(patched.dns['nameserver-policy']['+.invalid-filter.example'].every((endpoint) => {
    return endpoint.endsWith(`#${routeGroup}`);
  }));
});

test('nested rules and the legacy QUIC guard are handled without weakening user rules', { skip: !available }, () => {
  const config = baseConfig();
  const nestedUserRule = 'AND,((NETWORK,UDP),(DST-PORT,3478)),REJECT';
  const legacyQuicGuard = 'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT';
  config.rules.unshift(nestedUserRule, legacyQuicGuard);

  const patched = engine.clashPatchTransform(config, 'fixture');
  assert.ok(patched.rules.includes(nestedUserRule), 'a user nested rule was removed');
  assert.equal(patched.rules.includes(legacyQuicGuard), false, 'the managed legacy guard was retained');
});

test('DNS policy rejects privacy-weakening resolver options', { skip: !available }, () => {
  const config = baseConfig();
  const target = '台湾家宽 01';
  config.dns['nameserver-policy'] = {
    '+.h3.example': [`https://1.1.1.1/dns-query#${target}&h3=true`],
    '+.skip-cert.example': [`https://1.1.1.1/dns-query#${target}&skip-cert-verify=true`],
    '+.ecs.example': [`https://1.1.1.1/dns-query#${target}&ecs=203.0.113.0/24&ecs-override=true`]
  };

  const patched = engine.clashPatchTransform(config, 'fixture');
  const policies = patched.dns['nameserver-policy'];
  const safeSuffix = `#${engine.clashPatchRouteGroupName(patched)}`;
  assert.deepEqual(policies['+.h3.example'], engine.CLASH_PATCH_POLICY.resolvers.map((resolver) => `${resolver}#${target}&h3=true`));
  for (const pattern of ['+.skip-cert.example', '+.ecs.example']) {
    assert.ok(policies[pattern].every((endpoint) => endpoint.endsWith(safeSuffix)), pattern);
  }
});

test('null proxy providers do not crash DNS validation', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-providers'] = null;
  config['proxy-groups'].push({ name: 'NullProviderGroup', type: 'select', use: ['missing'] });
  config.dns['nameserver-policy'] = {
    '+.null-provider.example': ['https://1.1.1.1/dns-query#NullProviderGroup']
  };
  const patched = engine.clashPatchTransform(config, 'fixture');
  assert.ok(patched.dns['nameserver-policy']['+.null-provider.example'].every((endpoint) => {
    return endpoint.endsWith(`#${engine.clashPatchRouteGroupName(patched)}`);
  }));
});

test('direct and rematch home names are not selected automatically', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies.unshift(
    { name: '台湾家宽 DIRECT', type: 'direct' },
    { name: '台湾家宽 REMATCH', type: 'rematch', 'target-rematch-name': 'again' }
  );
  config['proxy-groups'][0].proxies.unshift('台湾家宽 DIRECT', '台湾家宽 REMATCH');
  const patched = engine.clashPatchTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === 'AI');
  const mainGroup = patched['proxy-groups'].find((group) => group.name === 'Main');
  assert.deepEqual(ai.proxies, ['Main']);
  assert.ok(mainGroup.proxies.includes('台湾家宽 DIRECT'));
  assert.ok(mainGroup.proxies.includes('台湾家宽 REMATCH'));
  assert.equal(patched['proxy-groups'].some((group) => /^🛡 安全代理 · Clash Patch/.test(group.name)), false);
});

test('tun arrays are replaced by a mapping', { skip: !available }, () => {
  const config = baseConfig();
  config.tun = [];
  const patched = engine.clashPatchTransform(config, 'fixture');
  assert.equal(Array.isArray(patched.tun), false);
  assert.equal(patched.tun.enable, true);
});

test('owned AI group is independent and collision safe', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  config['proxy-groups'].push({ name: '🤖 AI · Clash Patch', type: 'url-test', proxies: ['台湾家宽 01'] });
  config['proxy-groups'].push({ name: '🤖 AI · Clash Patch 2', type: 'url-test', proxies: ['台湾家宽 01'] });
  const patched = engine.clashPatchTransform(config, 'fixture');
  const names = patched['proxy-groups'].map((group) => group.name);
  assert.deepEqual(names, [...new Set(names)]);
  const managed = patched['proxy-groups'].find((group) => group.name === '🤖 AI · Clash Patch 3');
  assert.deepEqual(managed.proxies, ['台湾家宽 01', '日本家宽 01', '美国家宽 01']);
});

test('user-owned branded select group is preserved', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  const userGroup = {
    name: '🤖 AI · Clash Patch',
    type: 'select',
    proxies: ['Main', '日本家宽 01'],
    icon: 'https://example.invalid/user-icon.png'
  };
  config['proxy-groups'].push(userGroup);
  const first = engine.clashPatchTransform(config, 'fixture');
  const second = engine.clashPatchTransform(first, 'fixture');
  assert.deepEqual(first['proxy-groups'].find((group) => group.name === userGroup.name), userGroup);
  assert.equal(first['proxy-groups'].some((group) => group.name === '🤖 AI · Clash Patch 2'), false);
  assert.ok(first.rules.includes('DOMAIN-SUFFIX,openai.com,🤖 AI · Clash Patch'));
  assert.deepEqual(second, first);
});

test('branded user group with AI rules is not mistaken for patch ownership', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  const userGroup = {
    name: '🤖 AI · Clash Patch',
    type: 'select',
    proxies: ['Main', '日本家宽 01'],
    icon: 'https://example.invalid/user-icon.png'
  };
  config['proxy-groups'].push(userGroup);
  config.rules.unshift(
    'DOMAIN-SUFFIX,anthropic.com,🤖 AI · Clash Patch',
    'DOMAIN-SUFFIX,openai.com,🤖 AI · Clash Patch'
  );
  const first = engine.clashPatchTransform(config, 'fixture');
  const second = engine.clashPatchTransform(first, 'fixture');
  assert.deepEqual(first['proxy-groups'].find((group) => group.name === userGroup.name), userGroup);
  assert.deepEqual(second['proxy-groups'].find((group) => group.name === userGroup.name), userGroup);
  assert.equal(first['proxy-groups'].some((group) => group.name === '🤖 AI · Clash Patch 2'), false);
  assert.deepEqual(second, first);
});

test('inline proxy names reserve managed group names', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  config.proxies.unshift(
    { name: '🤖 AI · Clash Patch', type: 'ss', server: 'ai.example', port: 443 },
    { name: '🛡 安全代理 · Clash Patch', type: 'ss', server: 'safe.example', port: 443 }
  );
  const patched = engine.clashPatchTransform(config, 'fixture');
  assert.ok(patched['proxy-groups'].some((group) => group.name === '🤖 AI · Clash Patch 2'));
  assert.equal(patched['proxy-groups'].some((group) => /^🛡 安全代理 · Clash Patch(?: \d+)?$/.test(group.name)), false);
});

test('migrates legacy owned AI rules and DNS pattern', { skip: !available }, () => {
  const old = baseConfig();
  old['proxy-groups'] = old['proxy-groups'].filter((group) => group.name !== 'AI');
  const aiGroup = '🤖 AI · Clash Patch';
  const safeGroup = '🛡 安全代理 · Clash Patch';
  old['proxy-groups'].push({ name: aiGroup, type: 'select', proxies: ['台湾家宽 01'] });
  old['proxy-groups'].push({
    name: safeGroup, type: 'select', proxies: ['台湾家宽 01'], 'include-all': true,
    'exclude-type': 'Direct|Dns|Reject|Pass|Compatible|Rematch', 'empty-fallback': 'REJECT'
  });
  old.rules = [`NETWORK,UDP,${safeGroup}`, 'NETWORK,UDP,REJECT']
    .concat(engine.clashPatchRenderAiRules(aiGroup).map((rule) => rule.replace('160.79.104.0/23', '160.79.104.0/21')),
      [`DOMAIN-SUFFIX,ai.com,${aiGroup}`], old.rules);
  old.dns.nameserver = [`https://dns.alidns.com/dns-query#${safeGroup}`];
  old.dns['nameserver-policy'] = { '+.ai.com': old.dns.nameserver.slice() };

  const patched = engine.clashPatchTransform(old, 'fixture');
  assert.ok(!patched.rules.includes(`DOMAIN-SUFFIX,ai.com,${aiGroup}`));
  assert.ok(!patched.rules.includes(`IP-CIDR,160.79.104.0/21,${aiGroup},no-resolve`));
  assert.ok(patched.rules.includes(`IP-CIDR,160.79.104.0/23,${aiGroup},no-resolve`));
  assert.equal(Object.prototype.hasOwnProperty.call(patched.dns['nameserver-policy'], '+.ai.com'), false);
});

test('preserves user legacy AI rules and DNS pattern', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'].push({ name: 'Friend', type: 'select', proxies: ['台湾家宽 01'] });
  config.rules.unshift('DOMAIN-SUFFIX,ai.com,Friend', 'IP-CIDR,160.79.104.0/21,Friend,no-resolve');
  config.dns['nameserver-policy']['+.ai.com'] = ['https://1.1.1.1/dns-query#Friend'];
  const patched = engine.clashPatchTransform(config, 'fixture');
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,ai.com,Friend'));
  assert.ok(patched.rules.includes('IP-CIDR,160.79.104.0/21,Friend,no-resolve'));
  assert.deepEqual(patched.dns['nameserver-policy']['+.ai.com'], engine.CLASH_PATCH_POLICY.resolvers.map((resolver) => `${resolver}#Friend`));
});

test('patches config without a rules array', { skip: !available }, () => {
  const config = baseConfig();
  delete config.rules;
  const patched = engine.clashPatchTransform(config, 'fixture');
  assert.ok(Array.isArray(patched.rules));
  assert.ok(patched.rules.some((rule) => rule.startsWith('DOMAIN-SUFFIX,openai.com,')));
});

test('existing AI group is reused even when many similar names exist', { skip: !available }, () => {
  const config = baseConfig();
  const base = '🤖 AI · Clash Patch';
  config['proxy-groups'].push({ name: base, type: 'select', proxies: ['Main'] });
  for (let suffix = 2; suffix <= 9; suffix += 1) {
    config['proxy-groups'].push({ name: `${base} ${suffix}`, type: 'select', proxies: ['Main'] });
  }
  const first = engine.clashPatchTransform(config, 'fixture');
  const second = engine.clashPatchTransform(first, 'fixture');
  assert.ok(first.rules.includes('DOMAIN-SUFFIX,openai.com,AI'));
  assert.equal(first['proxy-groups'].some((group) => group.name === `${base} 10`), false);
  assert.deepEqual(second, first);
});

test('rule templates insert selector names literally', { skip: !available }, () => {
  const rules = engine.clashPatchRenderAiRules('AI $&');
  assert.ok(rules.includes('DOMAIN-SUFFIX,openai.com,AI $&'));
});

test('shared SaaS domains are not routed wholesale through AI', () => {
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  const rules = policy.ai_rules.join('\n');
  for (const domain of ['sentry.io', 'auth0.com', 'segment.io', 'intercom.io', 'js.stripe.com', 'challenges.cloudflare.com', 'ct.sendgrid.net']) {
    assert.ok(!rules.includes(`,${domain},`), domain);
  }
});

test('canonical AI policy excludes unrelated ai.com and uses Anthropic inbound ranges', () => {
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  const rules = policy.ai_rules;
  assert.ok(!rules.includes('DOMAIN-SUFFIX,ai.com,{AI}'));
  assert.ok(rules.includes('IP-CIDR,160.79.104.0/23,{AI},no-resolve'));
  assert.ok(!rules.includes('IP-CIDR,160.79.104.0/21,{AI},no-resolve'));
  assert.ok(rules.includes('IP-CIDR6,2607:6bc0::/48,{AI},no-resolve'));
});

test('PowerShell installer structurally edits YAML and rolls back failed transactions', () => {
  const source = fs.readFileSync(installerPath, 'utf8');
  assert.match(source, /function Find-YamlMappingNode/);
  assert.match(source, /function Set-YamlTopLevelScalar/);
  assert.match(source, /function Set-YamlTunMapping/);
  assert.match(source, /function Test-GeneratedYaml/);
  assert.match(source, /function Restore-Transaction/);
  assert.match(source, /function Get-RedactedYamlChangedPaths/);
  assert.match(source, /ChangedFields/);
  assert.match(source, /Assert-RemoteSubscriptionAutoUpdateDisabled \$output \| Out-Null/);
  assert.doesNotMatch(source, /function Set-TunBlock/);
});

test('Windows installation fails closed and preserves exact restore state', () => {
  const installer = fs.readFileSync(installerPath, 'utf8');
  const uninstaller = fs.readFileSync(uninstallerPath, 'utf8');
  assert.match(installer, /\[string\]\$MihomoPath/);
  assert.match(installer, /function Test-MihomoVersion/);
  assert.match(installer, /Mihomo 1\.19\.27/);
  assert.match(installer, /Join-Path \(Join-Path \$env:LOCALAPPDATA "Clash Verge"\) "verge-mihomo\.exe"/);
  assert.match(installer, /function Test-ClashVergeRunning/);
  assert.match(installer, /if \(\$clientRunning\)[\s\S]*\$runningTargets[\s\S]*Write-BytesAtomic \$target\.Path \$target\.Bytes[\s\S]*exit 0/);
  assert.match(installer, /WaitForExit\(\$TimeoutSeconds \* 1000\)/);
  assert.match(installer, /\$process\.Kill\(\)/);
  assert.doesNotMatch(installer, /Get-Process -Name "verge-mihomo"/);
  assert.match(installer, /function Write-BytesAtomic/);
  assert.match(installer, /function Set-RemoteSubscriptionAutoUpdateDisabled/);
  assert.match(installer, /function Assert-RemoteSubscriptionAutoUpdateDisabled/);
  assert.match(installer, /allow_auto_update/);
  assert.match(installer, /profiles\.yaml/);
  assert.match(installer, /OriginalBytes/);
  assert.match(installer, /install-state\.json/);
  assert.match(installer, /SetAccessRuleProtection/);
  assert.match(installer, /async\\s\+function\\s\+main/);
  assert.match(installer, /不会等待异步 main/);
  assert.match(uninstaller, /InstalledSha256/);
  assert.match(uninstaller, /function New-UninstallBackup/);
  assert.match(uninstaller, /Guid.*NewGuid/);
  assert.equal(fs.existsSync(installWrapperPath), true);
  assert.equal(fs.existsSync(uninstallWrapperPath), true);
  assert.match(fs.readFileSync(installWrapperPath, 'utf8'), /-ExecutionPolicy Bypass/);
  assert.match(fs.readFileSync(uninstallWrapperPath, 'utf8'), /-ExecutionPolicy Bypass/);
});

test('Windows engine contains no unused rule-identity helper', () => {
  const source = fs.readFileSync(enginePath, 'utf8');
  assert.doesNotMatch(source, /function clashPatchRuleIdentity/);
});

test('Windows PowerShell entry scripts have a UTF-8 BOM', () => {
  for (const entry of [installerPath, uninstallerPath, routeVerifierPath]) {
    assert.deepEqual([...fs.readFileSync(entry).subarray(0, 3)], [0xef, 0xbb, 0xbf], entry);
  }
});

function baseConfig() {
  return {
    proxies: [
      { name: '台湾家宽 01', type: 'ss', server: 'tw.example', password: 'fixture-secret' },
      { name: '日本家宽 01', type: 'ss', server: 'jp.example', password: 'fixture-secret' },
      { name: '美国家宽 01', type: 'ss', server: 'us.example', password: 'fixture-secret' }
    ],
    'proxy-groups': [
      { name: 'Main', type: 'select', proxies: ['台湾家宽 01', '日本家宽 01', '美国家宽 01'] },
      { name: 'AI', type: 'select', proxies: ['Main'] }
    ],
    dns: { enable: true, nameserver: ['223.5.5.5'], 'nameserver-policy': {} },
    rules: [
      'DOMAIN,raw.githubusercontent.com,AI',
      'DOMAIN,storage.googleapis.com,AI',
      'GEOSITE,CN,DIRECT',
      'MATCH,Main'
    ]
  };
}
