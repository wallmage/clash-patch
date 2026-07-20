const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '..');
const enginePath = path.join(root, 'clash-patch/scripts/windows/clash_verge_global.js');
const policyPath = path.join(root, 'clash-patch/references/policy.json');
const installerPath = path.join(root, 'clash-patch/scripts/install_windows.ps1');
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
  assert.ok(!patched.rules.includes('DOMAIN,raw.githubusercontent.com,AI'));
  assert.ok(!patched.rules.includes('DOMAIN,storage.googleapis.com,AI'));
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

test('keeps a narrow rule set ahead of generic UDP', { skip: !available }, () => {
  const config = baseConfig();
  config.rules.splice(2, 0, 'RULE-SET,private-special,DIRECT');
  const rules = engine.clashPatchTransform(config, 'fixture').rules;
  const udpIndex = rules.findIndex((rule) => rule.startsWith('NETWORK,UDP,') && rule !== 'NETWORK,UDP,REJECT');
  assert.ok(rules.indexOf('RULE-SET,private-special,DIRECT') < udpIndex);
  assert.equal(rules[udpIndex + 1], 'NETWORK,UDP,REJECT');
  assert.ok(udpIndex < rules.indexOf('GEOSITE,CN,DIRECT'));
});

test('exports the canonical policy without divergence', { skip: !available }, () => {
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  const mapping = {
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

test('PowerShell installer structurally edits YAML and rolls back failed transactions', () => {
  const source = fs.readFileSync(installerPath, 'utf8');
  assert.match(source, /function Find-YamlMappingNode/);
  assert.match(source, /function Set-YamlTopLevelScalar/);
  assert.match(source, /function Set-YamlTunMapping/);
  assert.match(source, /function Test-GeneratedYaml/);
  assert.match(source, /function Restore-Transaction/);
  assert.doesNotMatch(source, /function Set-TunBlock/);
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
