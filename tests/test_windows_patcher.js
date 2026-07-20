const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '..');
const enginePath = path.join(root, 'clash-patch/scripts/windows/clash_verge_global.js');
const policyPath = path.join(root, 'clash-patch/references/policy.json');
const installerPath = path.join(root, 'clash-patch/scripts/install_windows.ps1');
const uninstallerPath = path.join(root, 'clash-patch/scripts/uninstall_windows.ps1');
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
  const ai = patched['proxy-groups'].find((group) => group.name === '🤖 AI · Clash Patch');
  const safeGroup = engine.clashPatchSafeGroupName(patched);

  assert.equal(patched.ipv6, false);
  assert.equal(patched.dns.ipv6, false);
  assert.deepEqual(patched.tun['dns-hijack'], ['any:53', 'tcp://any:53']);
  assert.deepEqual(ai.proxies, ['台湾家宽 01']);
  const udpIndex = patched.rules.indexOf(`NETWORK,UDP,${safeGroup}`);
  assert.ok(udpIndex >= 0);
  assert.equal(patched.rules[udpIndex + 1], 'NETWORK,UDP,REJECT');
  assert.ok(patched.rules.includes('DOMAIN,raw.githubusercontent.com,AI'));
  assert.ok(patched.rules.includes('DOMAIN,storage.googleapis.com,AI'));
});

test('main delegates to the same transform', { skip: !available }, () => {
  assert.deepEqual(engine.main(baseConfig(), 'fixture'), engine.clashPatchTransform(baseConfig(), 'fixture'));
});

test('transform is idempotent', { skip: !available }, () => {
  const once = engine.clashPatchTransform(baseConfig(), 'fixture');
  const twice = engine.clashPatchTransform(once, 'fixture');
  assert.deepEqual(twice, once);
});

test('does not choose US home broadband when Taiwan and Japan are absent', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies = config.proxies.filter((proxy) => proxy.name === '美国家宽 01');
  config['proxy-groups'] = [{ name: 'Main', type: 'select', proxies: ['美国家宽 01'] }];
  const patched = engine.clashPatchTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === '🤖 AI · Clash Patch');
  assert.deepEqual(ai.proxies, ['Main']);
});

test('prefers Japan home broadband when Taiwan is absent', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies = config.proxies.filter((proxy) => !proxy.name.includes('台湾'));
  config['proxy-groups'][0].proxies = config['proxy-groups'][0].proxies.filter((name) => !name.includes('台湾'));
  const patched = engine.clashPatchTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === '🤖 AI · Clash Patch');
  assert.deepEqual(ai.proxies, ['日本家宽 01']);
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
  const managed = patched.rules.find((rule) => rule.startsWith('DOMAIN-SUFFIX,openai.com,🤖 AI · Clash Patch'));
  assert.equal(patched.rules.filter((rule) => rule === userRule).length, 1);
  assert.ok(patched.rules.indexOf(userRule) < patched.rules.indexOf(managed));
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
  const guard = `NETWORK,UDP,${engine.clashPatchSafeGroupName(patched)}`;
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
    proxy_bootstrap_resolvers: 'proxyBootstrapResolvers',
    default_bootstrap_resolvers: 'defaultBootstrapResolvers',
    main_group_names: 'mainGroupNames',
    ai_group_names: 'aiGroupNames',
    taiwan_tokens: 'taiwanTokens',
    japan_tokens: 'japanTokens',
    forbidden_ai_domains: 'forbiddenAiDomains',
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
  assert.ok(patched.rules.includes(`NETWORK,UDP,${engine.clashPatchSafeGroupName(patched)}`));
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
  assert.ok(patched.rules.includes(`NETWORK,UDP,${engine.clashPatchSafeGroupName(patched)}`));
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
  const firstBackup = source.indexOf('foreach ($target in $targets) { Backup-Once');
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
  assert.ok(failure !== -1 && source.indexOf('exit 1') > failure, 'install failure must exit 1');
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
  assert.deepEqual(policy['+.proxy.example'], ['https://1.1.1.1/dns-query#台湾家宽 01']);
  assert.deepEqual(policy['+.group.example'], ['https://1.1.1.1/dns-query#SafeExisting']);
  for (const pattern of ['+.direct.example', '+.option.example', '+.interface.example']) {
    assert.ok(policy[pattern].every((value) => value.endsWith(`#${engine.clashPatchSafeGroupName(patched)}`)), pattern);
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
  const safeSuffix = `#${engine.clashPatchSafeGroupName(patched)}`;
  assert.deepEqual(policies['+.encrypted.example'], ['https://1.1.1.1/dns-query#台湾家宽 01']);
  for (const pattern of ['+.plaintext.example', '+.provider.example', '+.include-all.example']) {
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
    return endpoint.endsWith(`#${engine.clashPatchSafeGroupName(patched)}`);
  }));
});

test('direct and rematch home names are never selected', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies.unshift(
    { name: '台湾家宽 DIRECT', type: 'direct' },
    { name: '台湾家宽 REMATCH', type: 'rematch', 'target-rematch-name': 'again' }
  );
  config['proxy-groups'][0].proxies.unshift('台湾家宽 DIRECT', '台湾家宽 REMATCH');
  const patched = engine.clashPatchTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name.startsWith('🤖 AI · Clash Patch'));
  const safe = patched['proxy-groups'].find((group) => group.name === engine.clashPatchSafeGroupName(patched));
  assert.deepEqual(ai.proxies, ['台湾家宽 01']);
  assert.ok(!safe.proxies.includes('台湾家宽 DIRECT'));
  assert.ok(!safe.proxies.includes('台湾家宽 REMATCH'));
  assert.match(safe['exclude-type'], /Rematch/);
});

test('tun arrays are replaced by a mapping', { skip: !available }, () => {
  const config = baseConfig();
  config.tun = [];
  const patched = engine.clashPatchTransform(config, 'fixture');
  assert.equal(Array.isArray(patched.tun), false);
  assert.equal(patched.tun.enable, true);
});

test('owned AI group is deterministic and collision safe', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'].push({ name: '🤖 AI · Clash Patch', type: 'url-test', proxies: ['台湾家宽 01'] });
  config['proxy-groups'].push({ name: '🤖 AI · Clash Patch 2', type: 'url-test', proxies: ['台湾家宽 01'] });
  const patched = engine.clashPatchTransform(config, 'fixture');
  const names = patched['proxy-groups'].map((group) => group.name);
  assert.deepEqual(names, [...new Set(names)]);
  const managed = patched['proxy-groups'].find((group) => group.name === '🤖 AI · Clash Patch 3');
  assert.deepEqual(managed.proxies, ['台湾家宽 01']);
});

test('user-owned branded select group is preserved', { skip: !available }, () => {
  const config = baseConfig();
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
  assert.ok(first['proxy-groups'].some((group) => group.name === '🤖 AI · Clash Patch 2'));
  assert.deepEqual(second, first);
});

test('branded user group with AI rules is not mistaken for patch ownership', { skip: !available }, () => {
  const config = baseConfig();
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
  const patched = engine.clashPatchTransform(config, 'fixture');
  assert.deepEqual(patched['proxy-groups'].find((group) => group.name === userGroup.name), userGroup);
  assert.ok(patched['proxy-groups'].some((group) => group.name === '🤖 AI · Clash Patch 2'));
});

test('managed suffix ten is idempotent', { skip: !available }, () => {
  const config = baseConfig();
  const base = '🤖 AI · Clash Patch';
  config['proxy-groups'].push({ name: base, type: 'select', proxies: ['Main'] });
  for (let suffix = 2; suffix <= 9; suffix += 1) {
    config['proxy-groups'].push({ name: `${base} ${suffix}`, type: 'select', proxies: ['Main'] });
  }
  const first = engine.clashPatchTransform(config, 'fixture');
  const second = engine.clashPatchTransform(first, 'fixture');
  assert.ok(first['proxy-groups'].some((group) => group.name === `${base} 10`));
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
  assert.doesNotMatch(installer, /Get-Process -Name "verge-mihomo"/);
  assert.match(installer, /function Write-BytesAtomic/);
  assert.match(installer, /OriginalBytes/);
  assert.match(installer, /install-state\.json/);
  assert.match(uninstaller, /InstalledSha256/);
  assert.equal(fs.existsSync(installWrapperPath), true);
  assert.equal(fs.existsSync(uninstallWrapperPath), true);
  assert.match(fs.readFileSync(installWrapperPath, 'utf8'), /-ExecutionPolicy Bypass/);
  assert.match(fs.readFileSync(uninstallWrapperPath, 'utf8'), /-ExecutionPolicy Bypass/);
});

test('Windows PowerShell entry scripts have a UTF-8 BOM', () => {
  for (const entry of [installerPath, uninstallerPath]) {
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
