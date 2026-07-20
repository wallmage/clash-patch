// Clash Patch — Clash Verge Rev global enhancement script.
// This file intentionally has no Node.js runtime dependency.

const CLASH_PATCH_POLICY = {
  resolvers: [
    "https://1.1.1.1/dns-query",
    "https://1.0.0.1/dns-query",
    "https://8.8.8.8/dns-query"
  ],
  proxyBootstrapResolvers: [
    "https://223.5.5.5/dns-query",
    "https://1.1.1.1/dns-query"
  ],
  defaultBootstrapResolvers: ["223.5.5.5", "1.1.1.1"],
  mainGroupNames: ["Proxy", "PROXY", "Final", "Fallback", "节点选择", "节点列表", "兜底分流"],
  aiGroupNames: ["AI", "OpenAI", "人工智能", "🤖 AI"],
  taiwanTokens: ["台湾", "台灣", "Taiwan", "TW", "🇹🇼"],
  japanTokens: ["日本", "Japan", "JP", "🇯🇵"],
  forbiddenAiDomains: ["raw.githubusercontent.com", "storage.googleapis.com"],
  aiRules: [
    "DOMAIN-SUFFIX,anthropic.com,{AI}",
    "DOMAIN-SUFFIX,claude.ai,{AI}",
    "DOMAIN-SUFFIX,claude.com,{AI}",
    "DOMAIN-SUFFIX,claude.site,{AI}",
    "DOMAIN-SUFFIX,claudeusercontent.com,{AI}",
    "DOMAIN-SUFFIX,claudemcpclient.com,{AI}",
    "DOMAIN-SUFFIX,claudemcpcontent.com,{AI}",
    "DOMAIN,servd-anthropic-website.b-cdn.net,{AI}",
    "DOMAIN-SUFFIX,openai.com,{AI}",
    "DOMAIN-SUFFIX,chatgpt.com,{AI}",
    "DOMAIN-SUFFIX,chatgpt.livekit.cloud,{AI}",
    "DOMAIN-SUFFIX,host.livekit.cloud,{AI}",
    "DOMAIN-SUFFIX,turn.livekit.cloud,{AI}",
    "DOMAIN-SUFFIX,oaistatic.com,{AI}",
    "DOMAIN-SUFFIX,oaiusercontent.com,{AI}",
    "DOMAIN-SUFFIX,oaistatsig.com,{AI}",
    "DOMAIN-SUFFIX,ct.sendgrid.net,{AI}",
    "DOMAIN-SUFFIX,intercom.io,{AI}",
    "DOMAIN-SUFFIX,intercomcdn.com,{AI}",
    "DOMAIN-SUFFIX,cdn.openaimerge.com,{AI}",
    "DOMAIN-SUFFIX,workos.com,{AI}",
    "DOMAIN-SUFFIX,workoscdn.com,{AI}",
    "DOMAIN,workos.imgix.net,{AI}",
    "DOMAIN-SUFFIX,challenges.cloudflare.com,{AI}",
    "DOMAIN,js.stripe.com,{AI}",
    "DOMAIN-SUFFIX,browser-intake-datadoghq.com,{AI}",
    "DOMAIN-SUFFIX,sentry.io,{AI}",
    "DOMAIN-SUFFIX,auth0.com,{AI}",
    "DOMAIN-SUFFIX,api.statsig.com,{AI}",
    "DOMAIN-SUFFIX,events.statsigapi.net,{AI}",
    "DOMAIN-SUFFIX,featuregates.org,{AI}",
    "DOMAIN-SUFFIX,client-api.arkoselabs.com,{AI}",
    "DOMAIN,openai-api.arkoselabs.com,{AI}",
    "DOMAIN,chat.openai.com.cdn.cloudflare.net,{AI}",
    "DOMAIN,openaiapi-site.azureedge.net,{AI}",
    "DOMAIN,openaicom.imgix.net,{AI}",
    "DOMAIN,openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net,{AI}",
    "DOMAIN,openaicomproductionae4b.blob.core.windows.net,{AI}",
    "DOMAIN,production-openaicom-storage.azureedge.net,{AI}",
    "DOMAIN,static.cloudflareinsights.com,{AI}",
    "DOMAIN-SUFFIX,ai.com,{AI}",
    "DOMAIN-SUFFIX,algolia.net,{AI}",
    "DOMAIN-SUFFIX,identrust.com,{AI}",
    "DOMAIN-SUFFIX,launchdarkly.com,{AI}",
    "DOMAIN-SUFFIX,observeit.net,{AI}",
    "DOMAIN-SUFFIX,segment.io,{AI}",
    "DOMAIN,ai.google.dev,{AI}",
    "DOMAIN-SUFFIX,aistudio.google.com,{AI}",
    "DOMAIN-SUFFIX,gemini.google.com,{AI}",
    "DOMAIN-SUFFIX,gemini.google,{AI}",
    "DOMAIN-SUFFIX,gemini.gstatic.com,{AI}",
    "DOMAIN-SUFFIX,bard.google.com,{AI}",
    "DOMAIN-SUFFIX,makersuite.google.com,{AI}",
    "DOMAIN,alkalimakersuite-pa.clients6.google.com,{AI}",
    "DOMAIN,webchannel-alkalimakersuite-pa.clients6.google.com,{AI}",
    "DOMAIN-SUFFIX,generativelanguage.googleapis.com,{AI}",
    "DOMAIN,aiplatform.googleapis.com,{AI}",
    "DOMAIN-SUFFIX,generativeai.google,{AI}",
    "DOMAIN-KEYWORD,openai,{AI}",
    "IP-CIDR,24.199.123.28/32,{AI},no-resolve",
    "IP-CIDR,64.23.132.171/32,{AI},no-resolve",
    "IP-CIDR,160.79.104.0/21,{AI},no-resolve",
    "IP-CIDR6,2607:6bc0::/48,{AI},no-resolve",
    "IP-CIDR,102.37.57.54/32,{AI},no-resolve",
    "IP-CIDR,13.71.25.29/32,{AI},no-resolve",
    "IP-CIDR,135.220.40.201/32,{AI},no-resolve",
    "IP-CIDR,172.203.39.49/32,{AI},no-resolve",
    "IP-CIDR,172.207.173.200/32,{AI},no-resolve",
    "IP-CIDR,172.214.226.198/32,{AI},no-resolve",
    "IP-CIDR,191.233.251.27/32,{AI},no-resolve",
    "IP-CIDR,20.162.96.163/32,{AI},no-resolve",
    "IP-CIDR,20.168.48.117/32,{AI},no-resolve",
    "IP-CIDR,20.184.36.134/32,{AI},no-resolve",
    "IP-CIDR,20.203.144.245/32,{AI},no-resolve",
    "IP-CIDR,20.74.221.21/32,{AI},no-resolve",
    "IP-CIDR,4.151.200.38/32,{AI},no-resolve",
    "IP-CIDR,4.155.146.196/32,{AI},no-resolve",
    "IP-CIDR,4.197.172.116/32,{AI},no-resolve",
    "IP-CIDR,4.217.235.100/32,{AI},no-resolve",
    "IP-CIDR,4.245.198.13/32,{AI},no-resolve",
    "IP-CIDR,40.118.236.137/32,{AI},no-resolve",
    "IP-CIDR,51.4.112.173/32,{AI},no-resolve",
    "IP-CIDR,52.143.181.161/32,{AI},no-resolve",
    "IP-CIDR,68.155.152.41/32,{AI},no-resolve",
    "IP-CIDR,72.146.20.246/32,{AI},no-resolve",
    "IP-CIDR,74.248.148.7/32,{AI},no-resolve"
  ]
};

function clashPatchClone(value) {
  return JSON.parse(JSON.stringify(value));
}

function clashPatchUsable(config) {
  return config && typeof config === "object" && !Array.isArray(config) &&
    Array.isArray(config["proxy-groups"]) && Array.isArray(config.rules) &&
    (Array.isArray(config.proxies) || (config["proxy-providers"] && typeof config["proxy-providers"] === "object"));
}

function clashPatchSelectableGroups(config) {
  return (config["proxy-groups"] || []).filter(function (group) {
    return group && typeof group.name === "string" && String(group.type).toLowerCase() === "select";
  });
}

// AI-named groups are never main-group candidates: the managed DNS and UDP
// rules must not make the AI group target itself.
function clashPatchDetectMain(config) {
  const groups = clashPatchSelectableGroups(config);
  const candidates = groups.filter(function (group) { return !clashPatchAiName(group.name); });
  const names = candidates.map(function (group) { return group.name; });

  const matchRule = config.rules.slice().reverse().find(function (rule) { return String(rule).indexOf("MATCH,") === 0; });
  const matchTarget = matchRule ? String(matchRule).split(",")[1] : null;
  if (matchTarget && matchTarget !== "DIRECT" && names.indexOf(matchTarget) !== -1) return matchTarget;

  const references = {};
  config.rules.forEach(function (rule) {
    if (!clashPatchBroadRule(rule)) return;
    const parts = String(rule).split(",");
    let target = parts[parts.length - 1];
    if (target === "no-resolve") target = parts[parts.length - 2];
    if (names.indexOf(target) !== -1) references[target] = (references[target] || 0) + 1;
  });
  let frequentName = null;
  let frequentCount = 0;
  names.forEach(function (name) {
    const count = references[name] || 0;
    if (count > frequentCount) {
      frequentCount = count;
      frequentName = name;
    }
  });
  if (frequentName && frequentCount > 1) return frequentName;

  for (let i = 0; i < CLASH_PATCH_POLICY.mainGroupNames.length; i += 1) {
    const preferred = CLASH_PATCH_POLICY.mainGroupNames[i].toLowerCase();
    const found = names.find(function (name) { return name.toLowerCase() === preferred; });
    if (found) return found;
  }
  for (let i = 0; i < candidates.length; i += 1) {
    const uses = Array.isArray(candidates[i].use) ? candidates[i].use : [];
    if (uses.length) return candidates[i].name;
    const members = Array.isArray(candidates[i].proxies) ? candidates[i].proxies : [];
    if (members.length && !members.every(function (member) { return member === "DIRECT"; })) return candidates[i].name;
  }
  return null;
}

function clashPatchAiName(name) {
  if (typeof name !== "string") return false;
  if (CLASH_PATCH_POLICY.aiGroupNames.some(function (candidate) { return candidate.toLowerCase() === name.toLowerCase(); })) return true;
  const normalized = name.toLowerCase();
  return normalized.indexOf("openai") !== -1 || normalized.indexOf("人工智能") !== -1 || /(^|[^a-z])ai([^a-z]|$)/.test(normalized);
}

function clashPatchTokenMatch(name, token) {
  if (token !== "TW" && token !== "JP") return name.toLowerCase().indexOf(token.toLowerCase()) !== -1;
  return new RegExp("(?:^|[^A-Za-z])" + token + "(?:[^A-Za-z]|$)", "i").test(name);
}

function clashPatchHomeCandidate(config) {
  const groupNames = (config["proxy-groups"] || []).map(function (group) { return group && group.name; }).filter(Boolean);
  const names = [];
  (config.proxies || []).forEach(function (proxy) {
    if (proxy && typeof proxy.name === "string") names.push(proxy.name);
  });
  (config["proxy-groups"] || []).forEach(function (group) {
    (Array.isArray(group && group.proxies) ? group.proxies : []).forEach(function (name) {
      if (typeof name === "string" && groupNames.indexOf(name) === -1) names.push(name);
    });
  });
  const candidates = names.filter(function (name, index) {
    return name.indexOf("家宽") !== -1 && names.indexOf(name) === index;
  });
  const taiwan = candidates.find(function (name) {
    return CLASH_PATCH_POLICY.taiwanTokens.some(function (token) { return clashPatchTokenMatch(name, token); });
  });
  if (taiwan) return taiwan;
  return candidates.find(function (name) {
    return CLASH_PATCH_POLICY.japanTokens.some(function (token) { return clashPatchTokenMatch(name, token); });
  }) || null;
}

function clashPatchEnsureAiGroup(config, mainGroup, candidate) {
  let group = clashPatchSelectableGroups(config).find(function (item) { return clashPatchAiName(item.name); });
  if (!group) {
    let name = "🤖 AI";
    if (config["proxy-groups"].some(function (item) { return item && item.name === name; })) name = "🤖 AI 2";
    group = { name: name, type: "select", proxies: [mainGroup] };
    config["proxy-groups"].push(group);
  }
  // Invariant: a proxy group must never list itself as a member.
  const proxies = (Array.isArray(group.proxies) ? group.proxies : []).filter(function (member) { return member !== group.name; });
  if (candidate && candidate !== group.name) {
    const index = proxies.indexOf(candidate);
    if (index !== -1) proxies.splice(index, 1);
    proxies.unshift(candidate);
    if (mainGroup !== group.name && proxies.indexOf(mainGroup) === -1) proxies.push(mainGroup);
  } else if (!proxies.length && mainGroup !== group.name) {
    proxies.push(mainGroup);
  }
  group.proxies = proxies;
  return group.name;
}

function clashPatchTaggedResolvers(group) {
  return CLASH_PATCH_POLICY.resolvers.map(function (resolver) { return resolver + "#" + group; });
}

function clashPatchDnsPatterns() {
  const patterns = [];
  CLASH_PATCH_POLICY.aiRules.forEach(function (template) {
    const parts = template.split(",");
    const pattern = parts[0] === "DOMAIN-SUFFIX" ? "+." + parts[1] : (parts[0] === "DOMAIN" ? parts[1] : null);
    if (pattern && patterns.indexOf(pattern) === -1) patterns.push(pattern);
  });
  return patterns;
}

function clashPatchDns(config, mainGroup, aiGroup) {
  const dns = config.dns && typeof config.dns === "object" && !Array.isArray(config.dns) ? config.dns : {};
  config.dns = dns;
  dns.enable = true;
  dns.ipv6 = false;
  dns["respect-rules"] = true;
  dns["use-hosts"] = true;
  dns["use-system-hosts"] = true;
  const mainResolvers = clashPatchTaggedResolvers(mainGroup);
  const aiResolvers = clashPatchTaggedResolvers(aiGroup);
  dns["default-nameserver"] = CLASH_PATCH_POLICY.defaultBootstrapResolvers.slice();
  dns["proxy-server-nameserver"] = CLASH_PATCH_POLICY.proxyBootstrapResolvers.slice();
  dns.nameserver = mainResolvers.slice();
  if (Object.prototype.hasOwnProperty.call(dns, "fallback")) dns.fallback = mainResolvers.slice();
  if (Object.prototype.hasOwnProperty.call(dns, "direct-nameserver")) dns["direct-nameserver"] = mainResolvers.slice();

  const existing = dns["nameserver-policy"] && typeof dns["nameserver-policy"] === "object" ? dns["nameserver-policy"] : {};
  const policies = {};
  Object.keys(existing).forEach(function (combined) {
    String(combined).split(",").map(function (item) { return item.trim(); }).filter(Boolean).forEach(function (pattern) {
      const values = (Array.isArray(existing[combined]) ? existing[combined] : [existing[combined]]).map(String);
      const safe = values.some(function (value) {
        const fragment = value.split("#")[1];
        return fragment && fragment.split("&")[0] !== "DIRECT";
      });
      policies[pattern] = safe ? values : mainResolvers.slice();
    });
  });
  clashPatchDnsPatterns().forEach(function (pattern) { policies[pattern] = aiResolvers.slice(); });
  dns["nameserver-policy"] = policies;
}

function clashPatchRuleIdentity(rule) {
  const parts = String(rule).split(",");
  return parts.length >= 2 ? parts[0] + "\u0000" + parts[1] : null;
}

function clashPatchBroadRule(rule) {
  const parts = String(rule).split(",");
  if (parts[0] === "MATCH" || parts[0] === "GEOSITE" || parts[0] === "GEOIP") return true;
  if (parts[0] !== "RULE-SET") return false;
  const provider = parts[1] || "";
  return /(?:^|[-_])(ai|cn|china|direct|domestic|global|notcn|proxy)(?:$|[-_])/i.test(provider) || /国内|国外|节点|兜底/.test(provider);
}

function clashPatchRules(config, mainGroup, aiGroup) {
  const managed = CLASH_PATCH_POLICY.aiRules.map(function (template) { return template.replace("{AI}", aiGroup); });
  const identities = managed.map(clashPatchRuleIdentity);
  const aiNames = (config["proxy-groups"] || []).filter(function (group) { return group && clashPatchAiName(group.name); }).map(function (group) { return group.name; });
  if (aiNames.indexOf(aiGroup) === -1) aiNames.push(aiGroup);
  const rules = config.rules.filter(function (rule) {
    const parts = String(rule).split(",");
    const target = parts[parts.length - 1] === "no-resolve" ? parts[parts.length - 2] : parts[parts.length - 1];
    const managedExisting = identities.indexOf(clashPatchRuleIdentity(rule)) !== -1;
    const forbiddenAi = (parts[0] === "DOMAIN" || parts[0] === "DOMAIN-SUFFIX") &&
      CLASH_PATCH_POLICY.forbiddenAiDomains.indexOf(parts[1]) !== -1 && aiNames.indexOf(target) !== -1;
    const genericUdp = parts[0] === "NETWORK" && parts[1] === "UDP";
    return !managedExisting && !forbiddenAi && !genericUdp;
  });
  let anchor = rules.findIndex(clashPatchBroadRule);
  if (anchor === -1) anchor = rules.length;
  rules.splice.apply(rules, [anchor, 0].concat(managed, ["NETWORK,UDP," + mainGroup]));
  config.rules = rules;
}

function clashPatchTransform(config, profileName) {
  if (!clashPatchUsable(config)) return config;
  const patched = clashPatchClone(config);
  const mainGroup = clashPatchDetectMain(patched);
  if (!mainGroup) return config;
  const candidate = clashPatchHomeCandidate(patched);
  const aiGroup = clashPatchEnsureAiGroup(patched, mainGroup, candidate);
  patched.ipv6 = false;
  patched.tun = patched.tun && typeof patched.tun === "object" ? patched.tun : {};
  patched.tun.enable = true;
  patched.tun.stack = "system";
  patched.tun["dns-hijack"] = ["any:53", "tcp://any:53"];
  patched.tun["auto-route"] = true;
  patched.tun["auto-detect-interface"] = true;
  patched.tun["strict-route"] = true;
  clashPatchDns(patched, mainGroup, aiGroup);
  clashPatchRules(patched, mainGroup, aiGroup);
  return patched;
}

function clashPatchCompose(previousMain, config, profileName) {
  let previousResult = config;
  if (typeof previousMain === "function") previousResult = previousMain(config, profileName) || config;
  return clashPatchTransform(previousResult, profileName);
}

function main(config, profileName) {
  const previous = typeof clashPatchPreviousMain === "function" ? clashPatchPreviousMain : null;
  return clashPatchCompose(previous, config, profileName);
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    CLASH_PATCH_POLICY: CLASH_PATCH_POLICY,
    clashPatchCompose: clashPatchCompose,
    clashPatchDetectMain: clashPatchDetectMain,
    clashPatchTransform: clashPatchTransform,
    main: main
  };
}
