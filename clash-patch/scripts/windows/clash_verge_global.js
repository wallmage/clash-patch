// Clash Patch — Clash Verge Rev global enhancement script.
// This file intentionally has no Node.js runtime dependency.

// CLASH PATCH POLICY BEGIN
const CLASH_PATCH_POLICY = {
  "version": 1,
  "resolvers": [
    "https://1.1.1.1/dns-query",
    "https://1.0.0.1/dns-query",
    "https://8.8.8.8/dns-query"
  ],
  "proxyBootstrapResolvers": [
    "https://1.1.1.1/dns-query",
    "https://8.8.8.8/dns-query"
  ],
  "defaultBootstrapResolvers": [
    "1.1.1.1",
    "8.8.8.8"
  ],
  "mainGroupNames": [
    "Proxy",
    "PROXY",
    "Final",
    "Fallback",
    "节点选择",
    "节点列表",
    "兜底分流"
  ],
  "aiGroupNames": [
    "AI",
    "OpenAI",
    "人工智能",
    "🤖 AI"
  ],
  "taiwanTokens": [
    "台湾",
    "台灣",
    "Taiwan",
    "TW",
    "🇹🇼"
  ],
  "japanTokens": [
    "日本",
    "Japan",
    "JP",
    "🇯🇵"
  ],
  "forbiddenAiDomains": [
    "raw.githubusercontent.com",
    "storage.googleapis.com"
  ],
  "legacyAiRules": [
    "DOMAIN-SUFFIX,ai.com,{AI}",
    "IP-CIDR,160.79.104.0/21,{AI},no-resolve"
  ],
  "aiRules": [
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
    "DOMAIN-SUFFIX,oaistatic.com,{AI}",
    "DOMAIN-SUFFIX,oaiusercontent.com,{AI}",
    "DOMAIN-SUFFIX,oaistatsig.com,{AI}",
    "DOMAIN-SUFFIX,cdn.openaimerge.com,{AI}",
    "DOMAIN,openai-api.arkoselabs.com,{AI}",
    "DOMAIN,chat.openai.com.cdn.cloudflare.net,{AI}",
    "DOMAIN,openaiapi-site.azureedge.net,{AI}",
    "DOMAIN,openaicom.imgix.net,{AI}",
    "DOMAIN,openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net,{AI}",
    "DOMAIN,openaicomproductionae4b.blob.core.windows.net,{AI}",
    "DOMAIN,production-openaicom-storage.azureedge.net,{AI}",
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
    "IP-CIDR,160.79.104.0/23,{AI},no-resolve",
    "IP-CIDR6,2607:6bc0::/48,{AI},no-resolve"
  ]
};
// CLASH PATCH POLICY END

const CLASH_PATCH_AI_GROUP = "🤖 AI · Clash Patch";
const CLASH_PATCH_SAFE_GROUP = "🛡 安全代理 · Clash Patch";
const CLASH_PATCH_DIRECT_NAMES = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "REMATCH"];
const CLASH_PATCH_DIRECT_TYPES = ["direct", "dns", "reject", "pass", "compatible", "rematch"];

function clashPatchClone(value) {
  return JSON.parse(JSON.stringify(value));
}

function clashPatchUsable(config) {
  return config && typeof config === "object" && !Array.isArray(config) &&
    Array.isArray(config["proxy-groups"]) && (config.rules == null || Array.isArray(config.rules)) &&
    (Array.isArray(config.proxies) || (config["proxy-providers"] && typeof config["proxy-providers"] === "object" &&
      !Array.isArray(config["proxy-providers"])));
}

function clashPatchSelectableGroups(config) {
  return (config["proxy-groups"] || []).filter(function (group) {
    return group && typeof group.name === "string" && String(group.type).toLowerCase() === "select";
  });
}

function clashPatchManagedName(name, base) {
  if (typeof name !== "string") return false;
  if (name === base) return true;
  if (name.indexOf(base + " ") !== 0) return false;
  return /^(?:[2-9]|[1-9][0-9]+)$/.test(name.slice(base.length + 1));
}

function clashPatchManagedGroupName(name) {
  return clashPatchManagedName(name, CLASH_PATCH_AI_GROUP) || clashPatchManagedName(name, CLASH_PATCH_SAFE_GROUP);
}

// AI-named groups are never main-group candidates: the managed DNS and UDP
// rules must not make the AI group target itself.
function clashPatchDetectMain(config) {
  const groups = clashPatchSelectableGroups(config);
  const candidates = groups.filter(function (group) {
    return !clashPatchAiName(group.name) && !clashPatchManagedGroupName(group.name);
  });
  const names = candidates.map(function (group) { return group.name; });

  const matchRule = config.rules.slice().reverse().map(clashPatchRuleInfo).find(function (info) { return info.type === "MATCH"; });
  const matchTarget = matchRule ? matchRule.target : null;
  if (matchTarget && !clashPatchDirectName(matchTarget) && names.indexOf(matchTarget) !== -1) return matchTarget;

  const references = {};
  config.rules.forEach(function (rule) {
    if (!clashPatchBroadRule(rule)) return;
    const target = clashPatchRuleInfo(rule).target;
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
    if (members.length && !members.every(clashPatchDirectName)) return candidates[i].name;
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
  const names = [];
  (config.proxies || []).forEach(function (proxy) {
    if (!proxy || typeof proxy.name !== "string") return;
    if (CLASH_PATCH_DIRECT_TYPES.indexOf(String(proxy.type || "").toLowerCase()) !== -1) return;
    names.push(proxy.name);
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

function clashPatchUniqueGroupName(config, base) {
  const names = (config["proxy-groups"] || []).map(function (group) { return group && group.name; });
  (config.proxies || []).forEach(function (proxy) {
    if (proxy && typeof proxy.name === "string") names.push(proxy.name);
  });
  if (names.indexOf(base) === -1) return base;
  let suffix = 2;
  while (names.indexOf(base + " " + suffix) !== -1) suffix += 1;
  return base + " " + suffix;
}

function clashPatchManagedAiFingerprint(group) {
  if (!group || Object.keys(group).sort().join("\u0000") !== ["name", "proxies", "type"].sort().join("\u0000")) return false;
  return String(group.type).toLowerCase() === "select" && Array.isArray(group.proxies) && group.proxies.length === 1 &&
    typeof group.proxies[0] === "string" && group.proxies[0] !== group.name;
}

function clashPatchManagedSafeFingerprint(group) {
  const expected = ["empty-fallback", "exclude-type", "include-all", "name", "proxies", "type"].sort().join("\u0000");
  if (!group || Object.keys(group).sort().join("\u0000") !== expected) return false;
  if (String(group.type).toLowerCase() !== "select" || group["include-all"] !== true) return false;
  if (String(group["empty-fallback"]).toUpperCase() !== "REJECT") return false;
  if (["Direct|Dns|Reject|Pass|Compatible|Rematch", "Direct|Reject|Pass|Compatible|Rematch", "Direct|Reject|Pass|Compatible"].indexOf(group["exclude-type"]) === -1) return false;
  return Array.isArray(group.proxies) && group.proxies.every(function (name) {
    return typeof name === "string" && name !== group.name;
  });
}

function clashPatchOwnedAiGroup(config, name) {
  const group = clashPatchSelectableGroups(config).find(function (item) { return item.name === name; });
  if (!clashPatchManagedAiFingerprint(group)) return false;
  const keys = CLASH_PATCH_POLICY.aiRules.concat(CLASH_PATCH_POLICY.legacyAiRules || []).map(clashPatchManagedRuleKey);
  const matches = (config.rules || []).filter(function (rule) {
    const info = clashPatchRuleInfo(rule);
    return info.target === name && keys.indexOf(clashPatchManagedRuleKey(rule)) !== -1;
  });
  if (matches.length < 2) return false;
  return clashPatchSelectableGroups(config).some(function (group) {
    return clashPatchManagedName(group.name, CLASH_PATCH_SAFE_GROUP) && clashPatchOwnedSafeGroup(config, group.name);
  });
}

function clashPatchResolverTarget(endpoint) {
  const parts = String(endpoint).split("#", 2);
  if (parts.length < 2 || !parts[1]) return null;
  const target = parts[1].split("&", 1)[0];
  if (!target || target.indexOf("=") !== -1) return null;
  return target;
}

function clashPatchResolverTargets(config) {
  const dns = config.dns;
  if (!dns || typeof dns !== "object" || Array.isArray(dns)) return [];
  let endpoints = [];
  ["nameserver", "fallback", "direct-nameserver"].forEach(function (field) {
    const value = dns[field];
    endpoints = endpoints.concat(Array.isArray(value) ? value : (value == null ? [] : [value]));
  });
  const policy = dns["nameserver-policy"];
  if (policy && typeof policy === "object" && !Array.isArray(policy)) {
    Object.keys(policy).forEach(function (key) {
      const value = policy[key];
      endpoints = endpoints.concat(Array.isArray(value) ? value : [value]);
    });
  }
  return endpoints.map(clashPatchResolverTarget).filter(Boolean);
}

function clashPatchOwnedSafeGroup(config, name) {
  const group = clashPatchSelectableGroups(config).find(function (item) { return item.name === name; });
  if (!clashPatchManagedSafeFingerprint(group)) return false;
  const rules = config.rules || [];
  const guarded = rules.some(function (rule, index) {
    if (index + 1 >= rules.length) return false;
    const first = clashPatchRuleInfo(rule);
    const second = clashPatchRuleInfo(rules[index + 1]);
    return first.type === "NETWORK" && first.payload.toUpperCase() === "UDP" && first.target === name &&
      second.type === "NETWORK" && second.payload.toUpperCase() === "UDP" && String(second.target).toUpperCase() === "REJECT";
  });
  return guarded && clashPatchResolverTargets(config).indexOf(name) !== -1;
}

function clashPatchFindManagedSelect(config, base, kind) {
  return clashPatchSelectableGroups(config).find(function (group) {
    if (!clashPatchManagedName(group.name, base)) return false;
    return kind === "ai" ? clashPatchOwnedAiGroup(config, group.name) : clashPatchOwnedSafeGroup(config, group.name);
  });
}

function clashPatchResetGroup(group) {
  Object.keys(group).forEach(function (key) {
    if (key !== "name" && key !== "type") delete group[key];
  });
  group.type = "select";
}

function clashPatchEnsureAiGroup(config, mainGroup, candidate) {
  let group = clashPatchFindManagedSelect(config, CLASH_PATCH_AI_GROUP, "ai");
  if (!group) {
    group = { name: clashPatchUniqueGroupName(config, CLASH_PATCH_AI_GROUP), type: "select" };
    config["proxy-groups"].push(group);
  }
  clashPatchResetGroup(group);
  group.proxies = [candidate || mainGroup].filter(function (name) { return name !== group.name; });
  return group.name;
}

function clashPatchSafeInlineProxies(config) {
  const names = [];
  (config.proxies || []).forEach(function (proxy) {
    if (!proxy || typeof proxy.name !== "string") return;
    if (CLASH_PATCH_DIRECT_TYPES.indexOf(String(proxy.type || "").toLowerCase()) !== -1) return;
    if (names.indexOf(proxy.name) === -1) names.push(proxy.name);
  });
  return names;
}

function clashPatchEnsureSafeGroup(config, candidate) {
  let group = clashPatchFindManagedSelect(config, CLASH_PATCH_SAFE_GROUP, "safe");
  if (!group) {
    group = { name: clashPatchUniqueGroupName(config, CLASH_PATCH_SAFE_GROUP), type: "select" };
    config["proxy-groups"].push(group);
  }
  const proxies = clashPatchSafeInlineProxies(config);
  const index = candidate ? proxies.indexOf(candidate) : -1;
  if (index !== -1) {
    proxies.splice(index, 1);
    proxies.unshift(candidate);
  }
  clashPatchResetGroup(group);
  group.proxies = proxies.filter(function (name) { return name !== group.name; });
  group["include-all"] = true;
  group["exclude-type"] = "Direct|Dns|Reject|Pass|Compatible|Rematch";
  group["empty-fallback"] = "REJECT";
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

function clashPatchLegacyDnsPatterns() {
  const patterns = [];
  (CLASH_PATCH_POLICY.legacyAiRules || []).forEach(function (template) {
    const parts = template.split(",");
    const pattern = parts[0] === "DOMAIN-SUFFIX" ? "+." + parts[1] : (parts[0] === "DOMAIN" ? parts[1] : null);
    if (pattern && patterns.indexOf(pattern) === -1) patterns.push(pattern);
  });
  return patterns;
}

function clashPatchDirectName(name) {
  return CLASH_PATCH_DIRECT_NAMES.some(function (candidate) {
    return candidate.toLowerCase() === String(name || "").toLowerCase();
  });
}

function clashPatchSafeProxyTarget(config, target) {
  return (config.proxies || []).some(function (proxy) {
    return proxy && proxy.name === target && CLASH_PATCH_DIRECT_TYPES.indexOf(String(proxy.type || "").toLowerCase()) === -1;
  });
}

function clashPatchGroupCannotReachDirect(config, target, visiting) {
  visiting = visiting || [];
  if (clashPatchDirectName(target) || visiting.indexOf(target) !== -1) return false;
  const group = (config["proxy-groups"] || []).find(function (item) { return item && item.name === target; });
  if (!group) return false;

  let members = Array.isArray(group.proxies) ? group.proxies.slice() : [];
  if (Array.isArray(group.use) && group.use.length) return false;
  if (group["include-all"] === true || group["include-all-proxies"] === true || group["include-all-providers"] === true) return false;
  const exclusion = String(group["exclude-filter"] || "");
  if (exclusion) {
    let pattern = exclusion;
    let flags = "";
    if (pattern.indexOf("(?i)") === 0) {
      pattern = pattern.slice(4);
      flags = "i";
    }
    if (/\(\?/.test(pattern) || /\\[1-9]/.test(pattern)) return false;
    let matcher;
    try {
      matcher = new RegExp(pattern, flags);
    } catch (_error) {
      return false;
    }
    members = members.filter(function (member) { return !matcher.test(String(member)); });
  }
  if (!members.length) return clashPatchSafeProxyTarget(config, group["empty-fallback"]);
  return members.every(function (member) {
    return clashPatchSafeProxyTarget(config, member) || clashPatchGroupCannotReachDirect(config, member, visiting.concat([target]));
  });
}

function clashPatchSafeResolverEndpoint(config, endpoint) {
  if (!/^(?:https|tls|quic):\/\//i.test(String(endpoint))) return false;
  const fragment = String(endpoint).split("#", 2)[1] || "";
  const options = fragment.split("&").slice(1);
  for (let index = 0; index < options.length; index += 1) {
    const pieces = options[index].split("=", 2);
    const key = String(pieces[0] || "").toLowerCase();
    const value = String(pieces[1] || "").toLowerCase();
    if (key === "ecs" || key === "ecs-override") return false;
    if (key === "skip-cert-verify" && value === "true") return false;
  }
  const target = clashPatchResolverTarget(endpoint);
  if (!target || clashPatchDirectName(target)) return false;
  return clashPatchSafeProxyTarget(config, target) || clashPatchGroupCannotReachDirect(config, target, []);
}

function clashPatchDns(config, safeGroup) {
  const dns = config.dns && typeof config.dns === "object" && !Array.isArray(config.dns) ? config.dns : {};
  config.dns = dns;
  dns.enable = true;
  dns.ipv6 = false;
  dns["respect-rules"] = true;
  dns["use-hosts"] = true;
  dns["use-system-hosts"] = true;
  const safeResolvers = clashPatchTaggedResolvers(safeGroup);
  dns["default-nameserver"] = CLASH_PATCH_POLICY.defaultBootstrapResolvers.slice();
  dns["proxy-server-nameserver"] = CLASH_PATCH_POLICY.proxyBootstrapResolvers.slice();
  dns.nameserver = safeResolvers.slice();
  if (Object.prototype.hasOwnProperty.call(dns, "fallback")) dns.fallback = safeResolvers.slice();
  if (Object.prototype.hasOwnProperty.call(dns, "direct-nameserver")) dns["direct-nameserver"] = safeResolvers.slice();

  const existing = dns["nameserver-policy"] && typeof dns["nameserver-policy"] === "object" ? dns["nameserver-policy"] : {};
  const policies = {};
  const legacyPatterns = clashPatchLegacyDnsPatterns();
  const ownedSafeNames = clashPatchSelectableGroups(config).map(function (group) { return group.name; }).filter(function (name) {
    return clashPatchManagedName(name, CLASH_PATCH_SAFE_GROUP) && clashPatchOwnedSafeGroup(config, name);
  });
  if (ownedSafeNames.indexOf(safeGroup) === -1) ownedSafeNames.push(safeGroup);
  Object.keys(existing).forEach(function (combined) {
    String(combined).split(",").map(function (item) { return item.trim(); }).filter(Boolean).forEach(function (pattern) {
      const values = (Array.isArray(existing[combined]) ? existing[combined] : [existing[combined]]).map(String);
      const legacyOwned = legacyPatterns.indexOf(pattern) !== -1 && values.length > 0 && values.every(function (value) {
        return ownedSafeNames.indexOf(clashPatchResolverTarget(value)) !== -1;
      });
      if (legacyOwned) return;
      const safe = values.length > 0 && values.every(function (value) {
        return clashPatchSafeResolverEndpoint(config, value);
      });
      policies[pattern] = safe ? values : safeResolvers.slice();
    });
  });
  clashPatchDnsPatterns().forEach(function (pattern) { policies[pattern] = safeResolvers.slice(); });
  dns["nameserver-policy"] = policies;
}

function clashPatchSplitRule(rule) {
  const fields = [];
  let buffer = "";
  let depth = 0;
  String(rule).split("").forEach(function (character) {
    if (character === "(") {
      depth += 1;
      buffer += character;
    } else if (character === ")") {
      if (depth > 0) depth -= 1;
      buffer += character;
    } else if (character === "," && depth === 0) {
      fields.push(buffer.trim());
      buffer = "";
    } else {
      buffer += character;
    }
  });
  fields.push(buffer.trim());
  return fields;
}

function clashPatchRuleInfo(rule) {
  const parts = clashPatchSplitRule(rule);
  const noResolve = String(parts[parts.length - 1] || "").toLowerCase() === "no-resolve";
  const targetIndex = noResolve ? parts.length - 2 : parts.length - 1;
  return {
    parts: parts,
    type: String(parts[0] || "").toUpperCase(),
    payload: String(parts[1] || ""),
    target: targetIndex > 0 ? parts[targetIndex] : null
  };
}

function clashPatchManagedRuleKey(rule) {
  const info = clashPatchRuleInfo(rule);
  if (!info.type || !info.payload) return null;
  return info.type + "\u0000" + info.payload.toLowerCase();
}

function clashPatchBroadRule(rule) {
  return ["MATCH", "GEOSITE", "GEOIP", "RULE-SET"].indexOf(clashPatchRuleInfo(rule).type) !== -1;
}

function clashPatchRenderAiRules(aiGroup) {
  return CLASH_PATCH_POLICY.aiRules.map(function (template) {
    return template.replace(/\{AI\}/g, function () { return aiGroup; });
  });
}

function clashPatchRules(config, aiGroup, safeGroup) {
  const managed = clashPatchRenderAiRules(aiGroup);
  const managedKeys = managed.map(clashPatchManagedRuleKey);
  const legacyKeys = (CLASH_PATCH_POLICY.legacyAiRules || []).map(clashPatchManagedRuleKey);
  const ownedAiNames = clashPatchSelectableGroups(config).map(function (group) { return group.name; }).filter(function (name) {
    return clashPatchManagedName(name, CLASH_PATCH_AI_GROUP) && clashPatchOwnedAiGroup(config, name);
  });
  if (ownedAiNames.indexOf(aiGroup) === -1) ownedAiNames.push(aiGroup);
  const ownedSafeNames = clashPatchSelectableGroups(config).map(function (group) { return group.name; }).filter(function (name) {
    return clashPatchManagedName(name, CLASH_PATCH_SAFE_GROUP) && clashPatchOwnedSafeGroup(config, name);
  });
  if (ownedSafeNames.indexOf(safeGroup) === -1) ownedSafeNames.push(safeGroup);

  const original = config.rules || [];
  const ownedUdpIndexes = [];
  original.forEach(function (rule, index) {
    const info = clashPatchRuleInfo(rule);
    if (info.type !== "NETWORK" || info.payload.toUpperCase() !== "UDP" || ownedSafeNames.indexOf(info.target) === -1) return;
    ownedUdpIndexes.push(index);
    if (index + 1 < original.length) {
      const next = clashPatchRuleInfo(original[index + 1]);
      if (next.type === "NETWORK" && next.payload.toUpperCase() === "UDP" && String(next.target).toUpperCase() === "REJECT") {
        ownedUdpIndexes.push(index + 1);
      }
    }
  });

  const userOverrides = [];
  const remaining = [];
  original.forEach(function (rule, index) {
    if (ownedUdpIndexes.indexOf(index) !== -1) return;
    const info = clashPatchRuleInfo(rule);
    const key = clashPatchManagedRuleKey(rule);
    const patchOwnedAi = managedKeys.indexOf(key) !== -1 && ownedAiNames.indexOf(info.target) !== -1;
    const legacyOwnedAi = legacyKeys.indexOf(key) !== -1 && ownedAiNames.indexOf(info.target) !== -1;
    const forbiddenAi = (info.type === "DOMAIN" || info.type === "DOMAIN-SUFFIX") &&
      CLASH_PATCH_POLICY.forbiddenAiDomains.some(function (domain) { return domain.toLowerCase() === info.payload.toLowerCase(); }) &&
      ownedAiNames.indexOf(info.target) !== -1;
    if (patchOwnedAi || legacyOwnedAi || forbiddenAi) return;
    if (managedKeys.indexOf(key) !== -1) userOverrides.push(rule);
    else remaining.push(rule);
  });

  config.rules = ["NETWORK,UDP," + safeGroup, "NETWORK,UDP,REJECT"].concat(userOverrides, managed, remaining);
}

function clashPatchTransform(config, profileName) {
  if (CLASH_PATCH_POLICY.version !== 1) return config;
  if (!clashPatchUsable(config)) return config;
  const patched = clashPatchClone(config);
  if (!Array.isArray(patched.rules)) patched.rules = [];
  const mainGroup = clashPatchDetectMain(patched);
  if (!mainGroup) return config;
  const candidate = clashPatchHomeCandidate(patched);
  const aiGroup = clashPatchEnsureAiGroup(patched, mainGroup, candidate);
  const safeGroup = clashPatchEnsureSafeGroup(patched, candidate);
  patched.ipv6 = false;
  patched.tun = patched.tun && typeof patched.tun === "object" && !Array.isArray(patched.tun) ? patched.tun : {};
  patched.tun.enable = true;
  patched.tun.stack = "system";
  patched.tun["dns-hijack"] = ["any:53", "tcp://any:53"];
  patched.tun["auto-route"] = true;
  patched.tun["auto-detect-interface"] = true;
  patched.tun["strict-route"] = true;
  clashPatchDns(patched, safeGroup);
  clashPatchRules(patched, aiGroup, safeGroup);
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
    clashPatchRenderAiRules: clashPatchRenderAiRules,
    clashPatchSafeGroupName: function (config) {
      const group = clashPatchFindManagedSelect(config, CLASH_PATCH_SAFE_GROUP, "safe");
      return group ? group.name : null;
    },
    clashPatchTransform: clashPatchTransform,
    main: main
  };
}
