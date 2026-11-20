'use strict';
(() => {
  // ---------- constants ----------
  const TOKEN = window.CP_TOKEN || '';
  const GAME = 'cyberpunk2077';
  const NEXUS = 'https://www.nexusmods.com/' + GAME;
  const NEXUS_NEXT = 'https://next.nexusmods.com/' + GAME;
  const FW = { 107: 'Cyber Engine Tweaks', 1511: 'redscript', 2380: 'RED4ext', 4198: 'ArchiveXL', 4197: 'TweakXL', 7780: 'Codeware', 4885: 'Mod Settings', 4575: 'Input Loader' };
  const SCRIPT_REQ = new Set([107, 1511, 2380, 7780, 4575, 4885, 3518, 12001, 13378]);
  const COSMETIC = ['Appearance', 'Armour and Clothing', 'Characters', 'Atelier Shop', 'Appearance Menu Mod Preset', 'Appearance Change Unlocker Preset'];
  const TAGS = ['Quality of Life', 'Bug Fixes', 'Performance Optimization', 'Gameplay', 'Overhaul', 'Fair and balanced', 'User Interface', 'Camera', 'Lighting', 'Weather', 'Textures', 'Visual Effects/Particles', 'Water', 'Vehicles', 'Weapons', 'Skills/Perks', 'Crafting', 'NPCs', 'NPC Behaviours (AI)', 'Quests', 'Music', 'Sound FX'];
  const SORTS = [['endorsements', 'Most endorsed'], ['downloads', 'Most downloaded'], ['updatedAt', 'Recently updated'], ['createdAt', 'Newest'], ['relevance', 'Best match']];
  const CSORTS = [['endorsements', 'Most endorsed'], ['downloads', 'Most downloaded'], ['updated', 'Recently updated'], ['small', 'Fewest mods']];
  const FILE_CATS = [['MAIN', 'Main files'], ['UPDATE', 'Updates'], ['OPTIONAL', 'Optional files'], ['MISCELLANEOUS', 'Miscellaneous']];
  const LIVE = ['MAIN', 'UPDATE', 'OPTIONAL', 'MISCELLANEOUS'];
  const PAGE = 40;
  const MOD_FIELDS = 'modId name summary version author updatedAt createdAt endorsements downloads adultContent thumbnailUrl thumbnailLargeUrl modCategory { name } uploader { name } tags { name }';
  const REQ_FIELDS = 'modRequirements { nexusRequirements { nodes { modId modName notes externalRequirement } } }';
  // Game: play, launch options, folders, saves; Reports: what happened when the game ran
  const PAGES = [['discover', 'Discover'], ['collections', 'Collections'], ['library', 'Library'], ['compat', 'Compatibility'], ['downloads', 'Downloads'], ['game', 'Game'], ['reports', 'Reports'], ['settings', 'Settings']];
  // what each kind of installed file is, in plain words (server: Get-FileKind)
  const KIND = {
    archive: { l: 'Assets', i: 'box', c: 'k-assets', t: 'Game assets (.archive): models, textures, sounds or game data. The game loads these itself.' },
    xl: { l: 'ArchiveXL', i: 'collections', c: 'k-xl', t: 'Rules for ArchiveXL (.xl): add items, looks or patches without replacing game files.' },
    redscript: { l: 'Script', i: 'code', c: 'k-script', t: 'redscript code (.reds), compiled into the game each time it starts.' },
    cet: { l: 'CET', i: 'term', c: 'k-cet', t: 'Lua mod run by Cyber Engine Tweaks. Many add a window to the CET overlay.' },
    native: { l: 'Plugin', i: 'plug', c: 'k-plugin', t: 'Native plugin (.dll) loaded by RED4ext. Powerful, and usually needs an update after a game patch.' },
    loader: { l: 'Loader', i: 'plug', c: 'k-plugin', t: 'A .dll next to the game exe that Windows loads at start: how frameworks hook in.' },
    tweak: { l: 'Tweak', i: 'db', c: 'k-tweak', t: 'TweakXL edits (.yaml) to the game database: items, stats, vehicles.' },
    input: { l: 'Input', i: 'key', c: 'k-input', t: 'Key bindings (.xml) merged in by Input Loader.' },
    config: { l: 'Settings', i: 'gear', c: 'k-config', t: 'Settings files the mod or the game reads.' },
    plugindata: { l: 'Plugin data', i: 'gear', c: 'k-config', t: 'Data files that sit next to a native plugin.' },
    framework: { l: 'Framework', i: 'shield', c: 'k-fw', t: 'Core files of a modding framework.' },
    redmod: { l: 'REDmod', i: 'box', c: 'k-assets', t: 'Official REDmod content in the mods folder.' },
    docs: { l: 'Docs', i: 'file', c: 'k-docs', t: 'Readme or license: the game does not use it.' },
    other: { l: 'Other', i: 'file', c: 'k-docs', t: 'Other file.' },
  };
  const KIND_FILTER = [['', 'Any type'], ['archive', 'Assets (.archive)'], ['xl', 'ArchiveXL rules (.xl)'], ['redscript', 'Scripts (redscript)'], ['cet', 'Lua mods (CET)'], ['native', 'Native plugins (.dll)'], ['tweak', 'Tweaks (TweakXL)'], ['input', 'Key bindings'], ['config', 'Settings files']];
  // where mods sit in the game folder, who loads them, and why it matters (Library map and file trees)
  const LOCS = [
    { k: 'mod', p: 'archive\\pc\\mod', t: 'Asset mods', i: 'box', c: 'k-assets', by: 'Loaded by the game itself', d: 'Archives (.archive) with models, textures, sounds and game data, plus rule files (.xl) for ArchiveXL. Read in alphabetical order: when two archives change the same thing, the name that sorts first wins.' },
    { k: 'scripts', p: 'r6\\scripts', t: 'Script mods', i: 'code', c: 'k-script', by: 'Compiled by redscript at every launch', d: 'redscript code (.reds) that changes how the game behaves. If one file fails to compile, the game starts with no script mods at all.' },
    { k: 'tweaks', p: 'r6\\tweaks', t: 'Database tweaks', i: 'db', c: 'k-tweak', by: 'Applied by TweakXL', d: 'Edits to the game database (.yaml): items, stats, prices, vehicles.' },
    { k: 'input', p: 'r6\\input', t: 'Key bindings', i: 'key', c: 'k-input', by: 'Merged by Input Loader', d: 'Extra key bindings (.xml) that mods add to the game controls.' },
    { k: 'cet', p: 'bin\\x64\\plugins\\cyber_engine_tweaks\\mods', t: 'Lua mods', i: 'term', c: 'k-cet', by: 'Run by Cyber Engine Tweaks', d: 'One folder per mod with an init.lua. Many add a window to the CET overlay.' },
    { k: 'red4ext', p: 'red4ext\\plugins', t: 'Native plugins', i: 'plug', c: 'k-plugin', by: 'Loaded by RED4ext', d: 'One folder per plugin with a .dll that hooks into the game\'s code. These usually need an update after each game patch.' },
    { k: 'r4core', p: 'red4ext', t: 'RED4ext', i: 'shield', c: 'k-fw', by: 'Started by its loader in bin\\x64', d: 'The RED4ext framework itself, with its logs.' },
    { k: 'bin', p: 'bin\\x64', t: 'Game program folder', i: 'gear', c: 'k-config', by: 'Loaded by Windows when the game starts', d: 'Loader files that frameworks put next to Cyberpunk2077.exe, such as version.dll for Cyber Engine Tweaks and winmm.dll for RED4ext.' },
    { k: 'engine', p: 'engine', t: 'Engine files', i: 'gear', c: 'k-config', by: 'Read by the engine and the script compiler', d: 'Engine settings (.ini) and tools such as the redscript compiler.' },
    { k: 'r6', p: 'r6', t: 'Other game data', i: 'gear', c: 'k-config', by: 'Read by the game', d: 'Other game configuration files.' },
    { k: 'redmod', p: 'mods', t: 'REDmod mods', i: 'box', c: 'k-assets', by: 'Loaded by REDmod', d: 'The official mod format, used only when the game starts with -modded.' },
    { k: 'other', p: '', t: 'Elsewhere', i: 'file', c: 'k-docs', by: '', d: 'Files outside the usual mod folders.' },
  ];
  const LSORTS = [['name', 'Name A-Z'], ['-name', 'Name Z-A'], ['new', 'Recently added'], ['old', 'Oldest first'], ['size', 'Largest first'], ['files', 'Most files'], ['type', 'Type']];
  const DSORTS = [['new', 'Newest first'], ['old', 'Oldest first'], ['size', 'Largest first'], ['small', 'Smallest first'], ['name', 'Name A-Z']];
  const RISK = { high: ['bad', 'High risk'], medium: ['warn', 'Medium risk'], low: ['muted', 'Low risk'], ok: ['ok', 'Intended'] };
  const FOLDERS = [['game', 'Game folder', 'Everything the game installs; mods go in sub-folders.'], ['mods', 'Asset mods', 'archive\\pc\\mod'], ['scripts', 'Script mods', 'r6\\scripts'], ['cet', 'Lua mods (CET)', 'bin\\x64\\plugins\\cyber_engine_tweaks\\mods'], ['red4ext', 'Native plugins', 'red4ext\\plugins'], ['tweaks', 'Tweaks', 'r6\\tweaks'], ['logs', 'Mod logs', 'red4ext\\logs: what plugins wrote at launch'], ['crashes', 'Crash reports', 'What the game saves when it crashes'], ['saves', 'Save games', 'Your saves; back them up before big changes'], ['config', 'Game settings', 'Graphics and control settings of the game'], ['downloads', 'cpmods downloads', 'Archives kept so mods can be turned off and on']];

  const ICONS = {
    discover: '<circle cx="12" cy="12" r="9"/><path d="m15.5 8.5-2.2 4.8-4.8 2.2 2.2-4.8z"/>',
    collections: '<path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/>',
    library: '<rect x="3.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.5"/>',
    downloads: '<path d="M12 4v11"/><path d="m7 10 5 5 5-5"/><path d="M5 20h14"/>',
    settings: '<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    x: '<path d="M6 6l12 12M18 6 6 18"/>',
    back: '<path d="m15 18-6-6 6-6"/>',
    fwd: '<path d="m9 18 6-6-6-6"/>',
    down: '<path d="m6 9 6 6 6-6"/>',
    collapse: '<rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M15 4.5v15"/><path d="m8 9 3 3-3 3"/>',
    expand: '<rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M15 4.5v15"/><path d="m11 9-3 3 3 3"/>',
    ext: '<path d="M14 4h6v6"/><path d="M20 4 11 13"/><path d="M19 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h5"/>',
    more: '<circle cx="5" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="19" cy="12" r="1.3"/>',
    thumb: '<path d="M7 11v9H4v-9z"/><path d="M7 11l4-7a2 2 0 0 1 3.2 1.9L13.4 10H19a2 2 0 0 1 2 2.3l-1.1 6A2 2 0 0 1 17.9 20H7"/>',
    dl: '<path d="M12 4v10"/><path d="m8 10 4 4 4-4"/><path d="M5 19h14"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    grid: '<rect x="4" y="4" width="7" height="7" rx="1"/><rect x="13" y="4" width="7" height="7" rx="1"/><rect x="4" y="13" width="7" height="7" rx="1"/><rect x="13" y="13" width="7" height="7" rx="1"/>',
    list: '<path d="M9 6h11M9 12h11M9 18h11"/><path d="M4.5 6h.01M4.5 12h.01M4.5 18h.01"/>',
    play: '<path d="M8 5.5v13l10.5-6.5z"/>',
    check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
    alert: '<path d="M12 4 2.8 19.5h18.4z"/><path d="M12 10v4.5M12 17.2v.1"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5.5M12 7.8v.1"/>',
    shield: '<path d="M12 3 5 6v5c0 4.5 3 8.3 7 10 4-1.7 7-5.5 7-10V6z"/><path d="m9 12 2 2 4-4"/>',
    compat: '<path d="M12 3 5 6v5c0 4.5 3 8.3 7 10 4-1.7 7-5.5 7-10V6z"/><path d="m9 12 2 2 4-4"/>',
    refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 5v6h-6"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    folder: '<path d="M3.5 6.5a1 1 0 0 1 1-1h5l2 2.5h8a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-15a1 1 0 0 1-1-1z"/>',
    scan: '<path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3"/><path d="M8 12h8"/>',
    game: '<rect x="2.5" y="7" width="19" height="11" rx="5"/><path d="M7.5 10.5v4M5.5 12.5h4"/><path d="M15.5 11.5h.01M18 13.5h.01"/>',
    reports: '<rect x="5" y="4.5" width="14" height="16.5" rx="2"/><path d="M9 4.5V3h6v1.5"/><path d="M8.5 10h7M8.5 13.5h7M8.5 17h4"/>',
    sidemin: '<rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M9 4.5v15"/><path d="m15.5 9.5-2.5 2.5 2.5 2.5"/>',
    sidemax: '<rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M9 4.5v15"/><path d="m13 9.5 2.5 2.5-2.5 2.5"/>',
    map: '<path d="M9 4 3.5 6v14L9 18l6 2 5.5-2V4L15 6z"/><path d="M9 4v14M15 6v14"/>',
    file: '<path d="M6 3.5h8l4 4v13H6z"/><path d="M14 3.5v4h4"/>',
    box: '<path d="m12 3 8 4.5v9L12 21l-8-4.5v-9z"/><path d="m4 7.5 8 4.5 8-4.5M12 12v9"/>',
    code: '<path d="m8 8-4 4 4 4M16 8l4 4-4 4M13.5 5l-3 14"/>',
    plug: '<path d="M9 3v5M15 3v5M6.5 8h11v3a5.5 5.5 0 0 1-11 0z"/><path d="M12 16.5V21"/>',
    db: '<ellipse cx="12" cy="6" rx="7" ry="2.5"/><path d="M5 6v12c0 1.4 3.1 2.5 7 2.5s7-1.1 7-2.5V6"/><path d="M5 12c0 1.4 3.1 2.5 7 2.5s7-1.1 7-2.5"/>',
    key: '<rect x="2.5" y="6.5" width="19" height="11" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7.5 14h9"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1"/>',
    term: '<rect x="3" y="4.5" width="18" height="15" rx="2"/><path d="m7 9.5 3 2.5-3 2.5M12.5 15h4.5"/>',
    eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="2.8"/>',
    bug: '<path d="M8 9a4 4 0 0 1 8 0v4.5a4 4 0 0 1-8 0z"/><path d="M12 13v7M4 12h4M16 12h4M5.5 6.5 8.2 8.6M18.5 6.5l-2.7 2.1M5.5 18.5l2.8-2M18.5 18.5l-2.8-2"/>',
    history: '<path d="M3.5 12a8.5 8.5 0 1 0 2.5-6"/><path d="M3.5 4.5V9H8"/><path d="M12 7.5V12l3 2"/>',
    stop: '<rect x="6.5" y="6.5" width="11" height="11" rx="2"/>',
    key2: '<circle cx="8" cy="15" r="4"/><path d="m11 12 8-8M16 7l2.5 2.5M14 9l2 2"/>',
    gauge: '<path d="M4.2 17a8.5 8.5 0 1 1 15.6 0"/><path d="m12 14 4-5"/><circle cx="12" cy="14.2" r="1.3"/>',
    palette: '<path d="M12 3.5a8.5 8.5 0 1 0 0 17c1.2 0 1.9-.8 1.9-1.8 0-1.3-1.2-1.6-1.2-2.9 0-1 .8-1.6 1.7-1.6h2.4a3.7 3.7 0 0 0 3.7-3.7c0-3.9-3.8-7-8.5-7z"/><circle cx="8" cy="11" r="1"/><circle cx="11" cy="7.4" r="1"/><circle cx="15.4" cy="8.6" r="1"/>',
    share: '<circle cx="6" cy="12" r="2.4"/><circle cx="17.5" cy="6" r="2.4"/><circle cx="17.5" cy="18" r="2.4"/><path d="m8.2 10.8 7.1-3.6M8.2 13.2l7.1 3.6"/>',
    save: '<path d="M5 4h11.5L20 7.5V20H5z"/><path d="M8.5 4v4.5h6.5V4M8.5 20v-6h7v6"/>',
    undo: '<path d="M9 6 4 11l5 5"/><path d="M4 11h9.5a5.5 5.5 0 0 1 0 11H11"/>',
    pin: '<path d="M7 3.5h10v17l-5-4-5 4z"/>',
  };
  const FILLED = new Set(['more', 'play', 'stop']);
  const ic = n => `<svg class="i" viewBox="0 0 24 24" fill="${FILLED.has(n) ? 'currentColor' : 'none'}" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[n] || ''}</svg>`;
  // friendly names for the processes the kill button closes
  const PROC_LABEL = { Cyberpunk2077: 'Cyberpunk 2077', REDEngineErrorReporter: 'the crash reporter', REDprelauncher: 'the CD Projekt launcher' };

  // ---------- state ----------
  let prefsMoved = false;
  const prefs = loadPrefs();
  const S = {
    st: null, offline: false, booted: false, sig: '', page: prefs.page || 'discover',
    pane: null, paneMin: false, paneMinScroll: 0, lb: null, cats: null, jobsSeen: null,
    b: Object.assign({ q: '', sort: 'endorsements', cat: '', tag: '', compat: 'likely', hideTr: true, hideAdult: true, hideCheats: true, hideCosmetic: false, view: 'grid' }, prefs.b || {},
      { items: [], offset: 0, total: 0, hidden: 0, loading: false, loaded: false, end: false, err: null, seq: 0, rendered: 0, renderSeq: -1 }),
    c: Object.assign({ q: '', sort: 'endorsements', cat: '', only: false, adult: false }, prefs.c || {}, { all: null, loading: false, err: null }),
    lib: Object.assign({ filter: 'all', q: '', sort: 'name', kind: '', src: '', view: 'list' }, prefs.lib || {}, { updates: null, fw: null, updSel: {}, checking: false, compat: null, compatLoading: false, files: null, filesSig: '', filesLoading: false, mapOpen: new Set() }),
    dl: Object.assign({ arch: 'all', sort: 'new', jobs: 'all' }, prefs.dl || {}, { variant: null, q: '', showDone: false }),
    launch: { data: null, loading: false, err: null, key: '' },
    rep: { mods: 'problems', tab: '', showHidden: false },
    disk: null,
    wasRunning: null, killedAt: 0, stSig: '',
  };
  // writes HTML only when it changed (polling re-renders the shell every few seconds)
  const shown = new WeakMap();
  function setHtml(el, html) { if (el && shown.get(el) !== html) { el.innerHTML = html; shown.set(el, html); } }

  // ---------- utils ----------
  function loadPrefs() {
    if (window.CP_PREFS && typeof window.CP_PREFS === 'object') return window.CP_PREFS;
    // first start since preferences moved to the app folder: take the old browser copy once
    try { const o = JSON.parse(localStorage.getItem('cpmods.beta') || 'null'); if (o && typeof o === 'object') { prefsMoved = true; return o; } } catch (e) { /* storage blocked */ }
    return {};
  }
  // preferences go to state\ui.json through the server (debounced, flushed when the window closes)
  let prefsTimer = 0, prefsBody = null;
  function savePrefs() {
    const pick = (o, ks) => ks.reduce((a, k) => { a[k] = o[k]; return a; }, {});
    prefsBody = JSON.stringify({
      page: S.page, paneW: prefs.paneW || undefined, reqMissingOnly: prefs.reqMissingOnly || undefined, sideMin: prefs.sideMin || undefined, explain: prefs.explain === true ? true : undefined, flowHelp: prefs.flowHelp || undefined,
      b: pick(S.b, ['sort', 'cat', 'tag', 'compat', 'hideTr', 'hideAdult', 'hideCheats', 'hideCosmetic', 'view']), c: pick(S.c, ['sort', 'cat', 'only', 'adult']),
      lib: pick(S.lib, ['sort', 'kind', 'src', 'view']), dl: pick(S.dl, ['arch', 'sort', 'jobs']),
      theme: prefs.theme && prefs.theme !== 'yellow' ? prefs.theme : undefined, custom: prefs.custom || undefined, themeVars: prefs.themeVars || undefined,
      bg: prefs.bg && prefs.bg !== 'match' ? prefs.bg : undefined, customBg: prefs.customBg || undefined,
      perf: prefs.perf || undefined, hideIssues: prefs.hideIssues && prefs.hideIssues.length ? prefs.hideIssues : undefined,
    });
    clearTimeout(prefsTimer);
    prefsTimer = setTimeout(flushPrefs, 400);
  }
  function flushPrefs(keep) {
    clearTimeout(prefsTimer);
    if (!prefsBody) return;
    const body = prefsBody;
    prefsBody = null;
    fetch('/api/prefs', { method: 'POST', keepalive: keep === true, headers: { 'X-Cp-Token': TOKEN, 'Content-Type': 'application/json' }, body })
      .then(r => { if (r.ok && prefsMoved) { prefsMoved = false; try { localStorage.removeItem('cpmods.beta'); } catch (e) { /* blocked */ } } })
      .catch(() => { /* server gone */ });
  }

  // ---------- performance: picture limits and light mode while the game runs ----------
  const PERF_DEF = { pics: 'large', maxPics: 48, galMax: 12, vidMax: 4, descPics: true, fx: true, lean: true, window: 'app', gpu: true, mouse: 0 };
  const perf = () => Object.assign({}, PERF_DEF, prefs.perf || {});
  // decoded size in MB (width x height x 4 bytes), measured on Nexus and YouTube files
  const PIC_MB = { large: 622 * 349 * 4 / 1048576, small: 385 * 216 * 4 / 1048576, full: 1600 * 900 * 4 / 1048576, yt: 480 * 360 * 4 / 1048576, ytSmall: 320 * 180 * 4 / 1048576 };
  const BLANK = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
  const unh = s => String(s).replace(/&(amp|lt|gt|quot|#39);/g, (m, k) => ({ amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'" })[k]);
  // pictures load when near the view; above the limit, far ones are unloaded; all paused while the game runs
  const IMG = (() => {
    const live = new Set(), watched = new Set(), near = new WeakSet(), obs = new Map(), warm = new Set();
    let paused = false;
    const isOn = i => i.getAttribute('src') === i.dataset.src;
    function observer(img) {
      const root = img.closest('#pane') || img.closest('#page') || null, k = root || document;
      let o = obs.get(k);
      if (!o) { o = new IntersectionObserver(onIx, { root, rootMargin: '500px 0px' }); obs.set(k, o); }
      return o;
    }
    function onIx(es) { for (const e of es) { if (e.isIntersecting) { near.add(e.target); load(e.target); } else near.delete(e.target); } trim(); }
    function load(i) { if (paused || isOn(i)) return; i.src = i.dataset.src; live.add(i); warm.add(i.dataset.src); }
    function unload(i) {
      // descriptions flow around their pictures: keep the box so the text does not jump
      if (i.classList.contains('bbimg') && !i.style.height && i.offsetHeight > 1) { i.style.width = i.offsetWidth + 'px'; i.style.height = i.offsetHeight + 'px'; }
      i.src = BLANK; live.delete(i);
    }
    function sweep() {
      for (const i of watched) if (!i.isConnected) { watched.delete(i); live.delete(i); if (i._io) i._io.unobserve(i); }
      warm.clear();
      for (const i of live) warm.add(i.dataset.src);
    }
    function trim() {
      sweep();
      const max = +perf().maxPics || 0;
      if (!max || live.size <= max) return;
      for (const i of live) { if (live.size <= max) break; if (!near.has(i)) unload(i); }
    }
    function add(i) { if (watched.has(i)) return; watched.add(i); if (isOn(i)) live.add(i); i._io = observer(i); i._io.observe(i); }
    function scan(n) { if (n.nodeType !== 1) return; if (n.tagName === 'IMG') { if (n.dataset.src) add(n); } else n.querySelectorAll('img[data-src]').forEach(add); }
    new MutationObserver(ms => { for (const m of ms) m.addedNodes.forEach(scan); if (watched.size > 400) sweep(); }).observe(document.body, { childList: true, subtree: true });
    return {
      // src as well when the picture is already shown somewhere, so re-renders do not flash
      attr: u => `data-src="${h(u)}" src="${!paused && warm.has(u) ? h(u) : BLANK}"`,
      pause(on) { paused = on; if (on) { for (const i of [...live]) unload(i); warm.clear(); } else for (const i of watched) if (i.isConnected && near.has(i)) load(i); },
      free() { for (const i of [...live]) if (!near.has(i)) unload(i); sweep(); },
      get paused() { return paused; },
      trim,
      stats() { sweep(); let n = 0, b = 0; for (const i of live) if (i.complete && i.naturalWidth > 1) { n++; b += i.naturalWidth * i.naturalHeight * 4; } return { n, mb: b / 1048576 }; },
    };
  })();
  function applyPerfClasses() { const P = perf(), r = document.documentElement; r.classList.toggle('nofx', !P.fx); r.classList.toggle('pics-off', P.pics === 'off'); }
  function applyPerf(key) {
    applyPerfClasses(); applyLean(); IMG.trim();
    if (S.pane) renderPane();
    if (S.page === 'settings') renderPage();
    const later = key === 'window' || key === 'gpu';
    toast('Saved', later ? 'Applies the next time cpmods opens.' : '', 'ok', later ? 4000 : 1500);
  }
  // light mode while the game runs: Reports page, every picture unloaded, slower refresh (the server lowers itself too)
  function applyLean() {
    const on = !!(perf().lean && S.st && S.st.game && S.st.game.running);
    document.documentElement.classList.toggle('lean', on);
    if (on === !!S.lean) return;
    S.lean = on;
    IMG.pause(on);
    if (on) { closeLightbox(); if (S.page !== 'reports' && !typing()) go('reports'); else if (S.pane) renderPane(); }
    else if (S.pane) renderPane();
  }

  // ---------- themes: CSS [data-theme] blocks, Custom = palette derived from one color ----------
  const THEMES = [
    { id: 'yellow', name: 'Yellow', sub: 'Base game', bg: '#12161c', fill: 'linear-gradient(180deg, #f6e761, #e8d53b)', bar: '#f0df4a' },
    { id: 'red', name: 'Red', sub: 'Phantom Liberty', bg: '#171213', fill: 'linear-gradient(180deg, #ff5064, #e8233a)', bar: '#ff3349' },
    { id: 'dual', name: 'Yellow + Red', sub: 'Both together', bg: '#171213', fill: 'linear-gradient(105deg, #f6e45a, #ff9a3c 52%, #ff3d50)', bar: 'linear-gradient(180deg, #f3df4b, #ff3349)' },
    { id: 'custom', name: 'Custom', sub: 'Your color' },
  ];
  const CUSTOM_DEFAULT = '#2fd4ff';
  const PRESETS = [['#ff3349', 'Phantom Liberty red'], ['#f0df4a', 'Base game yellow'], ['#2fd4ff', 'Neon cyan'], ['#ff2d8a', 'Glitch pink'], ['#a46bff', 'Violet'], ['#3ddc84', 'Green'], ['#ff8a2b', 'Orange'], ['#e9ebee', 'White']];
  const hexRgb = x => { const n = parseInt(x.slice(1), 16); return [n >> 16 & 255, n >> 8 & 255, n & 255]; };
  const rgbHex = (r, g, b) => '#' + [r, g, b].map(v => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, '0')).join('');
  function rgbHsl(r, g, b) {
    r /= 255; g /= 255; b /= 255;
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2;
    let hu = 0, s = 0;
    if (mx !== mn) { const d = mx - mn; s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn); hu = (mx === r ? (g - b) / d + (g < b ? 6 : 0) : mx === g ? (b - r) / d + 2 : (r - g) / d + 4) * 60; }
    return [hu, s * 100, l * 100];
  }
  function hslHex(hu, s, l) {
    s /= 100; l /= 100;
    const k = n => (n + hu / 30) % 12, a = s * Math.min(l, 1 - l), f = n => l - a * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1));
    return rgbHex(f(0) * 255, f(8) * 255, f(4) * 255);
  }
  const relLum = x => { const [r, g, b] = hexRgb(x).map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
  const contrast = (a, b) => { const x = relLum(a), y = relLum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const validHex = v => /^#?[0-9a-f]{6}$/i.test(String(v || '').trim());
  const normHex = v => '#' + String(v).trim().replace(/^#/, '').toLowerCase();
  // full palette from one color: fills, readable text/ink, and backgrounds tinted toward its hue
  function customVars(hex) {
    const [r, g, b] = hexRgb(hex), [hu, s, l] = rgbHsl(r, g, b);
    const n = (lt, sat) => hslHex(hu, Math.min(s, sat), lt);
    const bg = n(4.5, 12);
    const darkInk = hslHex(hu, Math.min(s, 60), 6), ink = contrast('#ffffff', hex) > contrast(darkInk, hex) ? '#ffffff' : darkInk;
    let tl = l, text = hex;
    while (contrast(text, bg) < 4.6 && tl < 92) { tl += 3; text = hslHex(hu, s, tl); }
    return {
      '--accent': hex, '--accent-rgb': `${r}, ${g}, ${b}`, '--accent-text': text, '--accent-ink': ink,
      '--accent-fill': `linear-gradient(180deg, ${hslHex(hu, s, Math.min(92, l + 7))}, ${hslHex(hu, s, Math.max(8, l - 5))})`, '--accent-edge': hslHex(hu, s, Math.min(90, l + 3)),
      '--accent-line': hslHex(hu, Math.min(s, 45), 25), '--accent-soft': hslHex(hu, Math.min(s, 40), 9),
      '--bg': bg, '--side': n(5.6, 12), '--surface': n(8.2, 11), '--raised': n(10.6, 11), '--hover': n(13.6, 10),
      '--line': n(13.4, 10), '--line2': n(19.5, 9), '--line3': n(26, 8), '--bg-rgb': hexRgb(bg).join(', '),
      '--btn-top': n(11.5, 10), '--btn-bot': n(9.5, 10), '--img-bg': n(3.6, 10), '--scroll': n(20, 8), '--scroll-hover': n(26, 8),
    };
  }
  // backgrounds: Matching keeps the color's own (its CSS block, or the Custom tint); the others replace every surface color
  const BGS = [
    { id: 'match', name: 'Matching', sub: 'Follows the color' },
    { id: 'grey', name: 'Grey', sub: 'Soft dark grey' },
    { id: 'black', name: 'Black', sub: 'Neutral black' },
    { id: 'oled', name: 'OLED black', sub: 'Pure black' },
    { id: 'white', name: 'White', sub: 'Light mode' },
    { id: 'custom', name: 'Custom', sub: 'Your color' },
  ];
  const BG_DEFAULT = '#17223a';
  const BG_PRESETS = [['#17223a', 'Navy'], ['#221a35', 'Violet'], ['#10292c', 'Teal'], ['#15281c', 'Forest'], ['#2c1720', 'Wine'], ['#2b2219', 'Brown'], ['#1d1d20', 'Graphite']];
  // dark surfaces from one hue and a base lightness, in the same steps as the built-in dark themes; text stays light
  function darkBg(hu, s, L) {
    const n = (d, sat) => hslHex(hu, Math.min(s, sat), Math.max(0, L + d));
    const bg = n(0, 40);
    return {
      '--bg': bg, '--side': n(1.5, 40), '--surface': n(4, 38), '--raised': n(7, 36), '--hover': n(10.5, 34), '--line': n(10.4, 34), '--line2': n(16, 30), '--line3': n(22, 28),
      '--bg-rgb': hexRgb(bg).join(', '), '--btn-top': n(9, 34), '--btn-bot': n(6.4, 36), '--img-bg': n(-0.5, 40), '--scroll': n(14.8, 30), '--scroll-hover': n(20.5, 28),
      '--text': hslHex(hu, Math.min(s, 8), 92.5), '--text2': hslHex(hu, Math.min(s, 10), 68.5), '--text3': hslHex(hu, Math.min(s, 10), 49),
    };
  }
  // light mode: dark text, darker status colors so they stay readable on white (CSS [data-bg="white"] handles the rest)
  const WHITE = {
    '--bg': '#eef0f3', '--side': '#e7eaee', '--surface': '#ffffff', '--raised': '#f7f8fa', '--hover': '#eceff3', '--line': '#e1e5ea', '--line2': '#d0d6dd', '--line3': '#b7bfc9',
    '--text': '#15191f', '--text2': '#47505c', '--text3': '#646d79', '--bg-rgb': '238, 240, 243', '--btn-top': '#ffffff', '--btn-bot': '#f2f4f7', '--img-bg': '#e2e6eb', '--scroll': '#c3cad3', '--scroll-hover': '#a9b2bd',
    '--ok': '#167a4d', '--warn': '#9a5d00', '--bad': '#c4352d', '--info': '#0a6f94',
    '--card-bg': 'var(--surface)', '--card-shadow': '0 1px 2px rgba(16, 24, 40, .06), 0 8px 24px -18px rgba(16, 24, 40, .25)',
  };
  function bgVars(id) {
    if (id === 'grey') return darkBg(220, 5, 11);
    if (id === 'black') return darkBg(220, 0, 3.5);
    if (id === 'oled') return Object.assign(darkBg(0, 0, 0), { '--side': '#000000', '--img-bg': '#000000' });
    if (id === 'white') return Object.assign({}, WHITE);
    if (id === 'custom') { const [hu, s, l] = rgbHsl(...hexRgb(prefs.customBg || BG_DEFAULT)); return darkBg(hu, s, Math.min(16, l)); }
    return {};
  }
  // on White the accent needs a darker text color and pale tints
  function lightAccentVars(hex) {
    const [r, g, b] = hexRgb(hex), [hu, s, l0] = rgbHsl(r, g, b);
    let l = l0, t = hex;
    while (contrast(t, '#ffffff') < 4.6 && l > 4) { l -= 2; t = hslHex(hu, s, l); }
    return { '--accent-text': t, '--accent-line': hslHex(hu, Math.min(s, 60), 78), '--accent-soft': hslHex(hu, Math.min(s, 75), 94), '--accent-glow': `rgba(${r}, ${g}, ${b}, .35)` };
  }
  const ACCENT_OF = { yellow: '#f0df4a', red: '#ff3349', dual: '#f3df4b' };
  const THEME_KEYS = [...new Set([...Object.keys(customVars('#808080')), ...Object.keys(WHITE), ...Object.keys(darkBg(0, 0, 5)), ...Object.keys(lightAccentVars('#808080'))])];
  const themeId = () => THEMES.some(t => t.id === prefs.theme) ? prefs.theme : 'yellow';
  const bgId = () => BGS.some(b => b.id === prefs.bg) ? prefs.bg : 'match';
  function themeVars() {
    const id = themeId(), bg = bgId(), v = id === 'custom' ? customVars(prefs.custom || CUSTOM_DEFAULT) : {};
    if (bg !== 'match') Object.assign(v, bgVars(bg));
    if (bg === 'white') Object.assign(v, lightAccentVars(id === 'custom' ? prefs.custom || CUSTOM_DEFAULT : ACCENT_OF[id]));
    return v;
  }
  function applyTheme() {
    const root = document.documentElement, id = themeId(), bg = bgId(), v = themeVars();
    for (const k of THEME_KEYS) root.style.removeProperty(k);
    for (const k in v) root.style.setProperty(k, v[k]);
    // saved with the preferences: index.html applies them before the first paint
    prefs.themeVars = Object.keys(v).length ? v : undefined;
    if (id === 'yellow') root.removeAttribute('data-theme'); else root.setAttribute('data-theme', id);
    if (bg === 'match') root.removeAttribute('data-bg'); else root.setAttribute('data-bg', bg);
    sendWinTheme();
  }
  // two pickers (accent, background) share the wheel, brightness, code and dots
  const PICKERS = {
    cw: { title: 'Custom color', help: 'Drag on the wheel or pick a dot. With the Matching background the panels take a tint of it too.', cur: () => prefs.custom || CUSTOM_DEFAULT, lmin: 35, lmax: 80, dots: PRESETS, on: () => themeId() === 'custom', set: (x, save) => setCustom(x, save), prev: x => customVars(x)['--accent-fill'] },
    bw: { title: 'Custom background', help: 'The wheel tints every panel; brightness sets how dark they are. Text stays light.', cur: () => prefs.customBg || BG_DEFAULT, lmin: 0, lmax: 16, dots: BG_PRESETS, on: () => bgId() === 'custom', set: (x, save) => setCustomBg(x, save), prev: x => x },
  };
  const cwOf = (x, k = 'cw') => { const P = PICKERS[k], [hu, s, l] = rgbHsl(...hexRgb(x)); return { h: Math.round(hu), s: Math.round(s), l: Math.round(Math.max(P.lmin, Math.min(P.lmax, l))) }; };
  const knobCss = cw => `left:${(50 + Math.cos(cw.h * Math.PI / 180) * cw.s / 2).toFixed(2)}%;top:${(50 + Math.sin(cw.h * Math.PI / 180) * cw.s / 2).toFixed(2)}%`;
  // a color card shows its color on the chosen background
  function swatchOf(t) {
    const bgv = bgId() === 'match' ? null : bgVars(bgId());
    if (t.id !== 'custom') return bgv ? Object.assign({}, t, { bg: bgv['--surface'] }) : t;
    const hex = prefs.custom || CUSTOM_DEFAULT, v = customVars(hex);
    return { bg: bgv ? bgv['--surface'] : v['--surface'], fill: v['--accent-fill'], bar: hex };
  }
  // a background card shows the current color on that background
  function bgSwatch(b) {
    const t = THEMES.find(x => x.id === themeId()), hex = prefs.custom || CUSTOM_DEFAULT, own = t.id === 'custom' ? customVars(hex) : null;
    return { bg: b.id === 'match' ? (own ? own['--surface'] : t.bg) : bgVars(b.id)['--surface'], fill: own ? own['--accent-fill'] : t.fill, bar: own ? hex : t.bar, ln: b.id === 'white' ? 'rgba(16, 24, 40, .16)' : '' };
  }
  const swHtml = sw => `<span class="theme-sw" style="--sw-bg:${sw.bg};--sw-fill:${sw.fill};--sw-bar:${sw.bar}${sw.ln ? ';--sw-ln:' + sw.ln : ''}"><i></i><i></i><b></b><em></em></span>`;
  function appearanceHtml() {
    const cur = themeId(), bg = bgId();
    const tcard = t => `<label class="theme-opt${cur === t.id ? ' on' : ''}" data-theme-opt="${t.id}"><input type="radio" name="theme" value="${t.id}"${cur === t.id ? ' checked' : ''}>${swHtml(swatchOf(t))}<span class="theme-name">${h(t.name)}</span><span class="theme-sub">${h(t.sub)}</span></label>`;
    const bcard = b => `<label class="theme-opt${bg === b.id ? ' on' : ''}" data-bg-opt="${b.id}"><input type="radio" name="bg" value="${b.id}"${bg === b.id ? ' checked' : ''}>${swHtml(bgSwatch(b))}<span class="theme-name">${h(b.name)}</span><span class="theme-sub">${h(b.sub)}</span></label>`;
    return `<div class="sub-label">Color</div><div class="themes" role="radiogroup" aria-label="Color">${THEMES.map(tcard).join('')}</div>${pickerHtml('cw')}
      <div class="sub-label">Background</div><div class="themes" role="radiogroup" aria-label="Background">${BGS.map(bcard).join('')}</div>${bg === 'custom' ? pickerHtml('bw') : ''}`;
  }
  function pickerHtml(k) {
    const P = PICKERS[k], hex = P.cur(), cw = S[k] || cwOf(hex, k);
    // the background wheel is drawn mid-bright so its hues stay visible; the slider sets the real (dark) brightness
    return `<div class="cpick${P.on() ? '' : ' idle'}${k === 'bw' ? ' bgpick' : ''}" id="${k}-box" style="--wl:${k === 'bw' ? 45 : cw.l}%;--wh:${cw.h};--ws:${cw.s}%">
        <div class="wheel" id="${k}" tabindex="0" role="slider" aria-label="${h(P.title)}: drag around the wheel for the color, toward the edge for stronger color; arrow keys work too" aria-valuetext="${hex}"><span class="wheel-knob" id="${k}-knob" style="${knobCss(cw)};--knob:${hex}"></span></div>
        <div class="cpick-side">
          <div class="cpick-head"><b>${h(P.title)}</b><span>${h(P.help)}</span></div>
          <div class="cpick-row"><label for="${k}-l">Brightness</label><input type="range" class="light-range" id="${k}-l" min="${P.lmin}" max="${P.lmax}" step="1" value="${cw.l}"></div>
          <div class="cpick-row"><label for="${k}-hex">Color code</label><input type="text" class="hex-in" id="${k}-hex" value="${hex}" maxlength="7" spellcheck="false" autocomplete="off"><span class="cpick-prev" id="${k}-prev" style="background:${P.prev(hex)}"></span></div>
          <div class="cc-dots">${P.dots.map(([c, nm]) => `<button class="cc-dot" data-act="pick-preset" data-k="${k}" data-v="${c}" style="background:${c}" title="${nm}" aria-label="${nm}"></button>`).join('')}</div>
        </div>
      </div>`;
  }
  // updates pickers and cards in place (no re-render, so a drag keeps going)
  function syncPicker() {
    for (const k of Object.keys(PICKERS)) {
      const box = $(`#${k}-box`);
      if (!box) continue;
      const P = PICKERS[k], hex = P.cur(), cw = S[k] || cwOf(hex, k);
      box.classList.toggle('idle', !P.on());
      if (k === 'cw') box.style.setProperty('--wl', cw.l + '%');
      box.style.setProperty('--wh', cw.h); box.style.setProperty('--ws', cw.s + '%');
      const kn = $(`#${k}-knob`); if (kn) kn.setAttribute('style', `${knobCss(cw)};--knob:${hex}`);
      const w = $('#' + k); if (w) w.setAttribute('aria-valuetext', hex);
      const hx = $(`#${k}-hex`); if (hx && document.activeElement !== hx) hx.value = hex;
      const lr = $(`#${k}-l`); if (lr && document.activeElement !== lr) lr.value = cw.l;
      const pv = $(`#${k}-prev`); if (pv) pv.style.background = P.prev(hex);
    }
    const cur = themeId(), bg = bgId();
    const mark = (o, on, sw) => { o.classList.toggle('on', on); const i = o.querySelector('input'); if (i) i.checked = on; const e = o.querySelector('.theme-sw'); if (!e) return; e.style.setProperty('--sw-bg', sw.bg); e.style.setProperty('--sw-fill', sw.fill); e.style.setProperty('--sw-bar', sw.bar); if (sw.ln) e.style.setProperty('--sw-ln', sw.ln); else e.style.removeProperty('--sw-ln'); };
    document.querySelectorAll('[data-theme-opt]').forEach(o => mark(o, o.dataset.themeOpt === cur, swatchOf(THEMES.find(t => t.id === o.dataset.themeOpt))));
    document.querySelectorAll('[data-bg-opt]').forEach(o => mark(o, o.dataset.bgOpt === bg, bgSwatch(BGS.find(b => b.id === o.dataset.bgOpt))));
    const sum = $('#sx-look .sx-t span');
    if (sum) sum.textContent = sectionSummary('look');
  }
  function setTheme(id) {
    prefs.theme = id;
    if (id === 'custom' && !prefs.custom) prefs.custom = CUSTOM_DEFAULT;
    S.cw = null;
    applyTheme(); syncPicker(); savePrefs();
  }
  function setCustom(hex, save) {
    prefs.custom = hex; prefs.theme = 'custom';
    applyTheme(); syncPicker();
    if (save) savePrefs();
  }
  function setBg(id) {
    prefs.bg = id;
    if (id === 'custom' && !prefs.customBg) prefs.customBg = BG_DEFAULT;
    S.bw = null;
    applyTheme();
    // the background picker only shows for Custom
    const b = $('#sxb-look');
    if (b) b.innerHTML = appearanceHtml(); else syncPicker();
    savePrefs();
  }
  function setCustomBg(hex, save) {
    prefs.customBg = hex; prefs.bg = 'custom';
    applyTheme(); syncPicker();
    if (save) savePrefs();
  }
  const $ = (s, r) => (r || document).querySelector(s);
  const h = v => String(v == null ? '' : v).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const decoder = document.createElement('textarea');
  const decode = s => { decoder.innerHTML = String(s == null ? '' : s); return decoder.value; };
  const stripBB = s => decode(String(s || '').replace(/<br\s*\/?>/gi, ' ')).replace(/\[[^\]]{1,80}\]/g, '').replace(/\s+/g, ' ').trim();
  const norm = s => String(s || '').toLowerCase().replace(/\bv?\d+(\.\d+)+[a-z]?\b/g, ' ').replace(/[^a-z0-9]+/g, ' ').trim();
  const timers = {};
  const debounce = (k, fn, ms) => { clearTimeout(timers[k]); timers[k] = setTimeout(fn, ms); };
  function fmtNum(n) { n = +n || 0; if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1) + 'M'; if (n >= 1e3) return (n / 1e3).toFixed(n >= 1e4 ? 0 : 1) + 'k'; return String(n); }
  function toDate(v) { if (v == null || v === '') return null; const d = typeof v === 'number' ? new Date(v * 1000) : new Date(v); return isNaN(d) ? null : d; }
  function fmtDate(v) { const d = toDate(v); return d ? d.toLocaleDateString('en-GB', { year: 'numeric', month: 'short', day: 'numeric' }) : '?'; }
  function fmtSize(b) { b = +b || 0; if (b >= 1099511627776) return (b / 1099511627776).toFixed(2) + ' TB'; if (b >= 1073741824) return (b / 1073741824).toFixed(2) + ' GB'; if (b >= 1048576) return (b / 1048576).toFixed(1) + ' MB'; if (b >= 1024) return Math.round(b / 1024) + ' KB'; return b + ' B'; }
  const opt = (list, cur) => list.map(([v, l]) => `<option value="${h(v)}"${v === cur ? ' selected' : ''}>${h(l)}</option>`).join('');
  const plural = (n, w, pl) => `${n} ${n === 1 ? w : pl || w + 's'}`;
  const typing = () => { const a = document.activeElement; return !!a && /INPUT|SELECT|TEXTAREA/.test(a.tagName) && a.type !== 'checkbox' && a.type !== 'radio' && a.type !== 'file'; };
  const callout = (kind, html) => `<div class="callout ${kind}">${ic(kind === 'ok' ? 'check' : kind === 'info' || kind === 'neutral' ? 'info' : 'alert')}<div>${html}</div></div>`;
  function fmtTime(v) { const d = toDate(v); return d ? d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }) : '?'; }
  function fmtWhen(v) {
    const d = toDate(v);
    if (!d) return '?';
    const days = Math.round((new Date().setHours(0, 0, 0, 0) - new Date(d).setHours(0, 0, 0, 0)) / 864e5);
    return (days === 0 ? 'today' : days === 1 ? 'yesterday' : fmtDate(d)) + ' ' + fmtTime(d);
  }
  function fmtDur(s) { s = Math.max(0, Math.round(+s || 0)); if (s < 90) return s + ' s'; if (s < 5400) return Math.round(s / 60) + ' min'; return (s / 3600).toFixed(1) + ' h'; }
  // PowerShell's JSON writer turns one-item lists into plain values
  const arr = v => Array.isArray(v) ? v : v == null || v === '' ? [] : [v];
  const kindInfo = k => KIND[k] || KIND.other;
  const kindChip = (k, full) => { const x = kindInfo(k); return `<span class="kchip ${x.c}" title="${h(x.t)}">${ic(x.i)}${full === false ? '' : h(x.l)}</span>`; };
  const kindChips = (kinds, max) => { const ks = arr(kinds).filter(k => k !== 'plugindata' && k !== 'framework'); return ks.slice(0, max || 4).map(k => kindChip(k)).join('') + (ks.length > (max || 4) ? `<span class="kchip k-docs">+${ks.length - (max || 4)}</span>` : ''); };
  function locOf(path) {
    const p = String(path || '').toLowerCase();
    let best = LOCS[LOCS.length - 1];
    for (const L of LOCS) { const lp = L.p.toLowerCase(); if (lp && (p === lp || p.startsWith(lp + '\\')) && (!best.p || lp.length > best.p.length)) best = L; }
    return best;
  }
  const riskPill = r => { const x = RISK[r] || RISK.low; return `<span class="pill ${x[0]}">${x[1]}</span>`; };
  const launchSt = () => (S.st && S.st.launch) || null;
  // installed after the last launch started: not tested in game yet
  function isNewSinceLaunch(m) { const l = launchSt(), s = l && toDate(l.start), i = toDate(m.installed); return !!(s && i && m.on !== false && i > s); }

  function bbToHtml(src) {
    let s = h(decode(String(src || '').replace(/<br\s*\/?>/gi, '\n')));
    const okUrl = u => /^https?:\/\//i.test(u);
    const clean = u => String(u).trim().replace(/^(&quot;|&#39;)|(&quot;|&#39;)$/g, '');
    for (let i = 0; i < 4; i++) {
      s = s.replace(/\[b\]([\s\S]*?)\[\/b\]/gi, '<b>$1</b>').replace(/\[i\]([\s\S]*?)\[\/i\]/gi, '<i>$1</i>').replace(/\[u\]([\s\S]*?)\[\/u\]/gi, '<u>$1</u>')
        .replace(/\[s\]([\s\S]*?)\[\/s\]/gi, '<s>$1</s>').replace(/\[center\]([\s\S]*?)\[\/center\]/gi, '<div class="bb-center">$1</div>')
        .replace(/\[quote(?:=[^\]]*)?\]([\s\S]*?)\[\/quote\]/gi, '<blockquote>$1</blockquote>')
        .replace(/\[spoiler(?:=[^\]]*)?\]([\s\S]*?)\[\/spoiler\]/gi, '<details><summary>Spoiler</summary>$1</details>')
        .replace(/\[heading\]([\s\S]*?)\[\/heading\]/gi, '<h4>$1</h4>');
    }
    s = s.replace(/\[url=([^\]]+)\]([\s\S]*?)\[\/url\]/gi, (m, u, t) => { u = clean(u); return okUrl(u) ? `<a href="${u}" target="_blank" rel="noopener noreferrer">${t}</a>` : t; })
      .replace(/\[url\]([\s\S]*?)\[\/url\]/gi, (m, u) => { u = clean(u); return okUrl(u) ? `<a href="${u}" target="_blank" rel="noopener noreferrer">${u}</a>` : u; })
      .replace(/\[img(?:=[^\]]*)?\]([\s\S]*?)\[\/img\]/gi, (m, u) => { u = clean(u); return !okUrl(u) ? '' : perf().descPics ? `<img class="bbimg" ${IMG.attr(unh(u))} data-u="${u}" data-act="bb-img" referrerpolicy="no-referrer" alt="">` : `<button class="link-btn bb-pic" data-act="bb-img" data-u="${u}">Show picture</button>`; })
      .replace(/\[youtube\]([\w-]{6,20})\[\/youtube\]/gi, (m, id) => `<a href="https://www.youtube.com/watch?v=${id}" target="_blank" rel="noopener noreferrer">YouTube video</a>`)
      .replace(/\[line\]/gi, '<hr>')
      .replace(/\[list(?:=[^\]]*)?\]([\s\S]*?)\[\/list\]/gi, (m, b) => '<ul>' + b.split(/\[\*\]/).map(x => x.trim()).filter(Boolean).map(x => `<li>${x}</li>`).join('') + '</ul>')
      .replace(/\[\/?(size|color|font|style|left|right|justify|align|b|i|u|s|center|quote|spoiler|heading|url|img|list|\*)(=[^\]]*)?\]/gi, '');
    return s.replace(/\n{3,}/g, '\n\n').replace(/\n/g, '<br>');
  }

  // ---------- server ----------
  async function api(path, body) {
    const o = { headers: { 'X-Cp-Token': TOKEN } };
    if (body !== undefined) { o.method = 'POST'; o.headers['Content-Type'] = 'application/json'; o.body = JSON.stringify(body); }
    let r;
    try { r = await fetch(path, o); } catch (e) { throw new Error('cpmods is not running'); }
    let j = null;
    try { j = await r.json(); } catch (e) { /* non-JSON */ }
    if (!r.ok || (j && j.error)) throw new Error((j && j.error) || ('HTTP ' + r.status));
    return j;
  }
  async function gql(query, variables) {
    const r = await api('/api/gql', variables ? { query, variables } : { query });
    if (r && r.errors && r.errors.length) throw new Error('Nexus: ' + r.errors[0].message);
    if (!r || !r.data) throw new Error('Nexus returned no data');
    return r.data;
  }

  // ---------- compatibility + lookups ----------
  function patch() { const s = S.st && S.st.settings; return { epoch: (s && s.patchEpoch) || 1792627200, label: (s && s.patchLabel) || '2.5' }; }
  const reqIds = m => ((m.modRequirements && m.modRequirements.nexusRequirements && m.modRequirements.nexusRequirements.nodes) || []).map(n => +n.modId);
  function compatOf(m) {
    const p = patch();
    if (FW[m.modId]) return { k: 'ok', label: 'Framework', tip: 'Installed and updated by cpmods' };
    const t = (toDate(m.updatedAt) || new Date(0)).getTime() / 1000;
    if (t >= p.epoch) return { k: 'ok', label: 'Updated for ' + p.label, tip: 'Updated on or after the ' + p.label + ' release' };
    const tags = (m.tags || []).map(x => x.name || '');
    const script = reqIds(m).some(id => SCRIPT_REQ.has(id)) || tags.some(x => /cyber engine tweaks|redscript|red4ext|codeware/i.test(x)) || /^scripts$/i.test((m.modCategory && m.modCategory.name) || '');
    return script ? { k: 'warn', label: 'Unverified', tip: 'Script mod not updated since ' + p.label + '. Often still works, can break.' }
      : { k: 'asset', label: 'Asset mod', tip: 'No script requirements. Asset-only mods usually survive patches.' };
  }
  const compatPill = c => `<span class="pill ${c.k === 'ok' ? 'ok' : c.k === 'warn' ? 'warn' : 'muted'}" title="${h(c.tip)}">${h(c.label)}</span>`;
  const gvList = c => ((c.latestPublishedRevision && c.latestPublishedRevision.gameVersions) || []).map(g => g.reference || '');
  const gvOk = c => { const l = patch().label; return gvList(c).some(r => r === l || r.startsWith(l + '.')); };
  const stMods = () => (S.st && S.st.mods) || [];
  const stDis = () => (S.st && S.st.disabled) || [];
  const stQueue = () => (S.st && S.st.queue) || [];
  // downloads waiting because another mod already installed some of their files
  // with the question turned off in Settings they are ordinary waiting installs (the last one installed wins)
  const askOn = () => !(S.st && S.st.settings && S.st.settings.askOverwrite === false);
  const needChoice = () => askOn() ? ((S.st && S.st.pending) || []).filter(p => arr(p.conflict).length) : [];
  const short = (s, n = 26) => { s = String(s || ''); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
  function modStatus(id) {
    id = +id;
    if (stMods().some(m => +m.modId === id)) return 'inst';
    if (stDis().some(m => +m.modId === id)) return 'dis';
    if (stQueue().some(q => +q.modId === id && !q.done)) return 'q';
    return null;
  }
  const statusPill = s => s === 'inst' ? '<span class="pill accent">Installed</span>' : s === 'dis' ? '<span class="pill">Disabled</span>' : s === 'q' ? '<span class="pill info">Queued</span>' : '';
  const browserName = () => { const b = S.st && S.st.settings && S.st.settings.browser; const m = b && (S.st.browsers || []).find(x => x.path === b); return m ? m.name : 'your browser'; };
  const selKey = () => {
    const p = S.pane;
    if (!p) return '';
    if (p.kind === 'mod') return 'mod:' + p.id;
    if (p.kind === 'col') return 'col:' + p.slug;
    if (p.kind === 'files') return 'files:' + p.name;
    if (p.kind === 'crash') return 'crash:' + p.id;
    if (p.kind === 'preview') return 'preview:' + p.file;
    return '';
  };

  // ---------- shell ----------
  function renderNav() {
    const st = S.st;
    const counts = {};
    if (st) {
      counts.library = [st.mods.length, false];
      const run = st.jobs.filter(j => j.status === 'running').length, att = st.failed.length, qn = st.queue.filter(q => !q.done).length;
      if (run || att || qn) counts.downloads = [run || att || qn, !!(run || att)];
      const lt = st.launch, bs = st.bisect;
      if (bs && bs.active) counts.reports = [bs.phase === 'done' ? 'done' : 'R' + bs.round, true];
      else if (lt && lt.result === 'crash' && !lt.running) counts.reports = ['!', true];
      const cr = allCrashIssues().length;
      if (cr) counts.compat = [cr, true];
    }
    setHtml($('#nav'), PAGES.map(([k, l]) => `<button class="nav-item${S.page === k ? ' active' : ''}" data-act="go" data-page="${k}"${S.page === k ? ' aria-current="page"' : ''} title="${l}">${ic(k)}<span>${l}</span>${counts[k] ? `<span class="nav-count${counts[k][1] ? ' hot' : ''}">${counts[k][0]}</span>` : ''}</button>`).join(''));
  }
  const resultWord = r => ({ clean: 'closed normally', crash: 'crashed', running: 'running now', ended: 'stopped without closing' }[r] || 'unknown');
  const resultDot = r => ({ crash: 'bad', ended: 'warn', running: 'run' }[r] || '');
  const gameProcs = () => { const g = S.st && S.st.game; return (g && arr(g.procs)) || []; };
  // small square button next to Play while the game (or its crash reporter/launcher) is still open
  const killBtn = wide => { const p = gameProcs(); return p.length ? `<button class="btn kill${wide ? '' : ' icon-only'}" data-act="kill" title="Force close ${h(p.map(x => PROC_LABEL[x] || x).join(', '))}" aria-label="Force close the game">${ic('stop')}${wide ? '<span>Force close</span>' : ''}</button>` : ''; };
  function renderSideFoot() {
    const st = S.st, g = st && st.game, lt = launchSt();
    const last = lt && lt.start ? `<button class="gc-last" data-act="go" data-page="reports" title="Open the launch report"><span class="dot ${resultDot(lt.result)}"></span><span>Last launch ${h(fmtWhen(lt.start))}: ${h(resultWord(lt.result))}</span></button>` : '';
    const mode = st && st.settings && st.settings.launchMode === 'direct' ? 'directly (Cyberpunk2077.exe)' : 'through Steam';
    const left = !g ? [] : gameProcs().filter(x => x !== 'Cyberpunk2077');
    const sub = !g ? '' : g.missing ? 'not found' : g.running ? 'running' : left.length ? 'closing' : g.updatePending ? 'update pending' : 'ready';
    const html = !g ? '' : `<div class="gamecard${g.running ? ' live' : ''}"><div class="gc-top"><div class="gc-title">Cyberpunk 2077</div><div class="gc-sub"><span class="dot ${g.missing ? 'bad' : g.running ? 'run' : left.length || g.updatePending ? 'warn' : ''}"></span>${h(g.version || '?')} &middot; ${sub}</div>${last}</div>
      <div class="play-row"><button class="btn primary" data-act="play"${g.running || g.missing ? ' disabled' : ''} title="Launch ${h(mode)}">${ic('play')}<span>${g.running ? 'Running' : 'Play'}</span></button>${killBtn()}<button class="btn icon-only" data-act="play-menu" title="Launch options and game folders" aria-label="Launch options and game folders">${ic('down')}</button></div></div>
      <div class="side-links"><button data-act="go" data-page="settings">Nexus key: ${st.key ? 'set' : 'missing'}</button></div>
      <button class="side-toggle" data-act="side-toggle" title="${prefs.sideMin ? 'Expand' : 'Collapse'} the sidebar (Ctrl+B)" aria-label="${prefs.sideMin ? 'Expand' : 'Collapse'} the sidebar">${ic(prefs.sideMin ? 'sidemax' : 'sidemin')}<span>Collapse</span></button>`;
    setHtml($('#sidefoot'), html);
  }
  function applySide() { $('.app').classList.toggle('side-min', !!prefs.sideMin); }
  function toggleSide() { prefs.sideMin = !prefs.sideMin; savePrefs(); applySide(); renderSideFoot(); layoutPane(); syncTitlebar(); }
  function renderBanner() {
    const st = S.st, g = st && st.game, bn = [];
    if (S.offline) bn.push('<div class="banner bad">cpmods is not running. Reopen it from the "Cyberpunk Mods" shortcut.</div>');
    const vn = st && st.vanilla;
    if (vn) bn.push(`<div class="banner info">${ic('info')}<span><b>Playing without mods.</b> ${vn.seen ? 'Your mods come back as soon as the game closes.' : 'Your mods are set aside inside the game folder and come back when the game closes.'}</span><button class="btn sm" data-act="vanilla-back"${g && g.running ? ' disabled title="Close the game first"' : ''}>Bring mods back now</button></div>`);
    const bs = st && st.bisect;
    if (bs && bs.active) {
      if (bs.phase === 'done') bn.push(`<div class="banner info">${ic('bug')}<span><b>Troubleshooting finished.</b> ${bs.outcome === 'found' ? `The problem points to ${h(bs.culprit)}.` : 'See the result on the Reports page.'}</span><button class="btn sm" data-act="go" data-page="reports">Open</button></div>`);
      else bn.push(`<div class="banner info">${ic('bug')}<span><b>Troubleshooting, round ${+bs.round}:</b> ${plural((bs.suspects || []).length, 'mod')} still suspected. Launch the game, then tell cpmods whether the problem happened.</span><button class="btn sm primary" data-act="go" data-page="reports">Answer</button></div>`);
    }
    if (g && g.missing) bn.push(`<div class="banner bad">Cyberpunk 2077 is not in ${h(st.paths.game)} any more. If you moved it, run Install.cmd again so cpmods finds it.</div>`);
    if (g && g.updatePending) bn.push(`<div class="banner">Steam has a Cyberpunk update pending. Downloads wait and installs are blocked until the game is updated.</div>`);
    if (g && g.running) bn.push('<div class="banner">The game is running. Installs and removals wait until you close it.</div>');
    if (st && !st.key) bn.push('<div class="banner">Downloads need your free Nexus API key.<button class="btn sm" data-act="go" data-page="settings">Add it</button></div>');
    if (st && !st.handler) bn.push('<div class="banner">Nexus download links do not open cpmods yet.<button class="btn sm" data-act="sys" data-op="register">Fix it</button></div>');
    setHtml($('#banner'), bn.join(''));
  }
  function renderActivity() {
    const st = S.st, el = $('#activity');
    if (!st) { el.hidden = true; return; }
    const run = st.jobs.filter(j => j.status === 'running'), qn = st.queue.filter(q => !q.done).length, att = st.failed.length, pick = needChoice().length;
    if (!run.length && !qn && !att && !pick) { el.hidden = true; setHtml(el, ''); return; }
    const jobs = run.slice(0, 2).map(j => {
      const pct = j.total ? Math.min(100, Math.round(100 * (j.done || 0) / j.total)) : null;
      const ph = j.phase === 'downloading' && j.total ? `${fmtSize(j.done)} of ${fmtSize(j.total)}` : (j.phase || 'working');
      return `<div class="act-job"><span class="spin"></span><div class="act-txt"><b>${h(j.title)}</b><span>${h(ph)}</span></div>${pct != null ? `<div class="mini"><div style="width:${pct}%"></div></div>` : ''}</div>`;
    }).join('') + (run.length > 2 ? `<span class="dim small">+${run.length - 2} more</span>` : '');
    el.hidden = false;
    setHtml(el, `<div class="act-left">${jobs}${pick ? `<button class="pill warn" data-act="conflict-open" style="cursor:pointer" title="Another mod already has some of its files">${plural(pick, 'install')} ${pick === 1 ? 'needs' : 'need'} your choice</button>` : ''}${att ? `<button class="pill bad" data-act="go" data-page="downloads" style="cursor:pointer">${plural(att, 'download')} need attention</button>` : ''}${!jobs && !att && !pick ? '<span class="dim small">Nothing downloading</span>' : ''}</div>
      <div class="act-right">${qn ? `<span class="dim small">${qn} in queue</span><button class="btn sm primary" data-act="queue-next" title="Opens the next queued file on Nexus; click Slow download there">Open next download page</button>` : ''}<button class="btn sm ghost" data-act="go" data-page="downloads">Details</button></div>`);
  }

  // ---------- history: every page and pane is a browser history entry ----------
  const SESSION = Math.random().toString(36).slice(2);
  const H = { idx: 0, max: 0, entries: [] };
  const PANE_MIN_W = 360, LIST_MIN_W = 380;
  function routeOf(page, p) {
    const r = '#/' + page;
    if (!p) return r;
    if (p.kind === 'mod') return r + '/mod/' + p.id;
    if (p.kind === 'col') return r + '/col/' + encodeURIComponent(p.slug);
    if (p.kind === 'files') return r + '/files/' + encodeURIComponent(p.name);
    if (p.kind === 'crash') return r + '/crash/' + encodeURIComponent(p.id);
    if (p.kind === 'preview') return r + '/preview/' + encodeURIComponent(p.file);
    return r + '/tool/' + p.kind;
  }
  function parseRoute(hash) {
    const m = String(hash || '').match(/^#\/(discover|collections|library|compat|downloads|game|reports|settings)(?:\/(mod|col|tool|files|crash|preview)\/(.+))?$/);
    if (!m) return null;
    let arg = m[3] || '';
    try { arg = decodeURIComponent(arg); } catch (e) { /* keep raw */ }
    return { page: m[1], kind: m[2] || '', arg };
  }
  // remember where the list and the pane were scrolled before leaving an entry
  function saveScroll() {
    const e = H.entries[H.idx];
    if (!e) return;
    e.pageScroll = $('#page').scrollTop;
    e.paneScroll = S.paneMin ? S.paneMinScroll : $('#pane').scrollTop;
  }
  function setEntry(push) {
    if (push) { H.idx++; H.entries.length = H.idx; H.max = H.idx; }
    H.entries[H.idx] = { page: S.page, pane: S.pane, pageScroll: 0, paneScroll: 0 };
    const st = { cp: H.idx, s: SESSION }, url = routeOf(S.page, S.pane);
    try { if (push) history.pushState(st, '', url); else history.replaceState(st, '', url); } catch (e) { /* history blocked */ }
    renderHist();
  }
  function renderHist() {
    const el = $('#hist');
    if (!el.firstChild) el.innerHTML = `<button class="icon-btn" id="h-back" data-act="hist-back" title="Back (Alt+Left or mouse back button)" aria-label="Back">${ic('back')}</button><button class="icon-btn" id="h-fwd" data-act="hist-fwd" title="Forward (Alt+Right)" aria-label="Forward">${ic('fwd')}</button>`;
    $('#h-back').disabled = H.idx <= 0;
    $('#h-fwd').disabled = H.idx >= H.max;
    syncTitlebar();
  }

  // ---------- title bar: the built-in window has no Windows frame, so the page draws it ----------
  const FRAME = /\bcpmods-frame\b/.test(navigator.userAgent) && !!(window.chrome && window.chrome.webview);
  const WIN_IC = {
    min: '<path d="M0 5.5h10"/>',
    max: '<rect x=".5" y=".5" width="9" height="9" rx="1.5"/>',
    restore: '<rect x=".5" y="2.5" width="7" height="7" rx="1.5"/><path d="M2.5 2.5V2A1.5 1.5 0 0 1 4 .5h4A1.5 1.5 0 0 1 9.5 2v4A1.5 1.5 0 0 1 8 7.5h-.5"/>',
    close: '<path d="m.5.5 9 9m0-9-9 9"/>',
  };
  const winIc = n => `<svg viewBox="0 0 10 10" aria-hidden="true">${WIN_IC[n]}</svg>`;
  let winMax = false;
  function renderTitlebar() {
    if (!FRAME) return;
    $('#tb').innerHTML = `<div class="tb-nav">
        <button class="tb-btn" id="tb-side" data-act="side-toggle" title="Sidebar (Ctrl+B)" aria-label="Toggle the sidebar">${ic(prefs.sideMin ? 'sidemax' : 'sidemin')}</button>
        <button class="tb-btn" id="tb-back" data-act="hist-back" title="Back (Alt+Left)" aria-label="Back">${ic('back')}</button>
        <button class="tb-btn" id="tb-fwd" data-act="hist-fwd" title="Forward (Alt+Right)" aria-label="Forward">${ic('fwd')}</button>
        <button class="tb-btn" data-act="tb-reload" title="Reload (F5)" aria-label="Reload">${ic('refresh')}</button>
      </div><div class="tb-fill"></div>
      <div class="tb-wins"><button class="tb-wb" data-act="win" data-v="min" title="Minimize" aria-label="Minimize">${winIc('min')}</button><button class="tb-wb" id="tb-max" data-act="win" data-v="max" title="Maximize" aria-label="Maximize">${winIc('max')}</button><button class="tb-wb close" data-act="win" data-v="close" title="Close" aria-label="Close">${winIc('close')}</button></div>`;
    syncTitlebar();
    // fallback when the window does not take app-region drags itself: hand the drag to Windows
    let down = null;
    $('#tb').addEventListener('mousedown', e => { down = e.button === 0 && !e.target.closest('button') ? { x: e.screenX, y: e.screenY } : null; });
    $('#tb').addEventListener('mousemove', e => { if (down && (e.buttons & 1) && Math.abs(e.screenX - down.x) + Math.abs(e.screenY - down.y) > 3) { down = null; window.chrome.webview.postMessage('drag'); } });
    $('#tb').addEventListener('dblclick', e => { if (!e.target.closest('button')) window.chrome.webview.postMessage('max'); });
    window.chrome.webview.addEventListener('message', e => {
      const m = String(e.data);
      if (m === 'max' || m === 'normal') { winMax = m === 'max'; syncTitlebar(); }
      else if (m === 'active' || m === 'inactive') $('#tb').classList.toggle('inactive', m === 'inactive');
    });
    window.chrome.webview.postMessage('hello');
  }
  function syncTitlebar() {
    if (!FRAME) return;
    const b = $('#tb-back'), f = $('#tb-fwd'), s = $('#tb-side'), m = $('#tb-max');
    if (b) { b.disabled = H.idx <= 0; f.disabled = H.idx >= H.max; }
    if (s) s.innerHTML = ic(prefs.sideMin ? 'sidemax' : 'sidemin');
    if (m) { m.innerHTML = winIc(winMax ? 'restore' : 'max'); m.title = winMax ? 'Restore' : 'Maximize'; m.setAttribute('aria-label', m.title); }
  }
  // colours for the strip above the page (top resize edge) and the Windows 11 window border
  function sendWinTheme() {
    if (!FRAME) return;
    const rgb = v => { const d = document.createElement('i'); d.style.color = `var(${v})`; document.body.appendChild(d); const c = (getComputedStyle(d).color.match(/\d+/g) || [0, 0, 0]).slice(0, 3).join(','); d.remove(); return c; };
    window.chrome.webview.postMessage('theme:' + rgb('--side') + '|' + rgb('--line2'));
  }
  // images re-render with no height until decoded, so keep re-applying the position briefly (stops on user input)
  const scrollFixes = new Map();
  function restoreScroll(el, top) {
    const prev = scrollFixes.get(el);
    if (prev) prev();
    el.scrollTop = top || 0;
    if (!top || el.scrollTop >= top - 1) return;
    const until = Date.now() + 2500;
    const again = () => { el.scrollTop = top; if (el.scrollTop >= top - 1 || Date.now() > until) stop(); };
    const stop = () => {
      el.removeEventListener('load', again, true);
      ['wheel', 'pointerdown', 'keydown'].forEach(n => window.removeEventListener(n, stop, true));
      clearTimeout(tm); scrollFixes.delete(el);
    };
    const tm = setTimeout(stop, 2600);
    el.addEventListener('load', again, true);
    ['wheel', 'pointerdown', 'keydown'].forEach(n => window.addEventListener(n, stop, true));
    scrollFixes.set(el, stop);
  }
  function restoreEntry(en) {
    closeMenu(); closeLightbox();
    const pageChanged = en.page !== S.page;
    S.page = en.page; savePrefs(); renderNav();
    if (pageChanged) renderPage();
    if (en.pane !== S.pane) S.paneMin = false;
    S.pane = en.pane;
    renderPane(true); markSelection();
    if (pageChanged) restoreScroll($('#page'), en.pageScroll || 0);
    if (S.pane && !S.paneMin) restoreScroll($('#pane'), en.paneScroll || 0);
  }
  function openRoute(r, mode) {
    if (r.kind === 'mod') return openMod(r.arg, mode);
    if (r.kind === 'col') return openCollection(r.arg, mode);
    if (r.kind === 'tool') return openTool(r.arg, mode);
    if (r.kind === 'files') return openFiles(r.arg, mode);
    if (r.kind === 'crash') return openCrash(r.arg, mode);
    if (r.kind === 'preview') return openPreview(r.arg, mode);
  }
  window.addEventListener('popstate', e => {
    const st = e.state;
    saveScroll();
    if (st && st.s === SESSION && H.entries[st.cp]) { H.idx = st.cp; restoreEntry(H.entries[st.cp]); }
    else {
      // entry from before a reload: rebuild it from the address
      const r = parseRoute(location.hash);
      if (r) { restoreEntry({ page: r.page, pane: null }); if (r.kind) openRoute(r, 'restore'); }
    }
    renderHist();
  });

  function go(page) {
    if (!PAGES.some(p => p[0] === page)) return;
    closeMenu();
    if (page === S.page && !S.pane) { $('#page').scrollTo({ top: 0, behavior: 'smooth' }); return; }
    saveScroll();
    S.page = page; S.pane = null; savePrefs();
    renderNav(); renderPage(); renderPane(); markSelection();
    $('#page').scrollTop = 0;
    setEntry(true);
  }
  function renderPage() {
    const el = $('#page');
    if (S.page === 'discover') return pageDiscover(el);
    if (S.page === 'collections') return pageCollections(el);
    if (!S.st) { el.innerHTML = `<div class="page-body"><div class="sk sk-line" style="width:40%"></div><div class="sk sk-line"></div><div class="sk sk-line" style="width:70%"></div></div>`; return; }
    if (S.page === 'library') return pageLibrary(el);
    if (S.page === 'compat') return pageCompat(el);
    if (S.page === 'downloads') return pageDownloads(el);
    if (S.page === 'game') return pageGame(el);
    if (S.page === 'reports') return pageReports(el);
    return pageSettings(el);
  }

  // ---------- discover ----------
  const segBtn = (act, cur, v, label, tip) => `<button data-act="${act}" data-v="${v}" class="${cur === v ? 'on' : ''}" title="${h(tip || label)}">${label}</button>`;
  const chip = (id, label, on, attr) => `<label class="chip${on ? ' on' : ''}"><input type="checkbox" ${attr || 'data-chip'}="${id}"${on ? ' checked' : ''}>${h(label)}</label>`;
  function pageDiscover(el) {
    const b = S.b, p = patch();
    const cats = [['', 'All categories']].concat((S.cats || []).map(c => [c, c]));
    el.innerHTML = `
      <header class="page-head">
        <div class="ph-top" style="align-items:center">
          <h1>Discover</h1>
          <div class="searchbar" style="flex:1;max-width:620px">${ic('search')}<input id="b-q" type="search" placeholder="Search mods on Nexus   ( / )" value="${h(b.q)}" autocomplete="off" spellcheck="false" aria-label="Search mods"></div>
          <div class="seg icons" role="group" aria-label="Layout">${['grid', 'list'].map(v => `<button data-act="b-view" data-v="${v}" class="${b.view === v ? 'on' : ''}" title="${v === 'grid' ? 'Grid' : 'Compact list'}">${ic(v)}</button>`).join('')}</div>
        </div>
        <div class="toolbar">
          <select id="b-sort" aria-label="Sort">${opt(SORTS, b.sort)}</select>
          <select id="b-cat" aria-label="Category">${opt(cats, b.cat)}</select>
          <select id="b-tag" aria-label="Tag">${opt([['', 'Any tag']].concat(TAGS.map(t => [t, t])), b.tag)}</select>
          <div class="seg" role="group" aria-label="Compatibility">${segBtn('b-compat', b.compat, 'all', 'All', 'Show every mod')}${segBtn('b-compat', b.compat, 'likely', 'Likely working', 'Hide script mods that were not updated since ' + p.label)}${segBtn('b-compat', b.compat, 'updated', 'Updated for ' + p.label, 'Only mods updated since ' + p.label + ' came out')}</div>
          <span class="spacer"></span>
          <div class="chips"><span class="chips-label">Hide</span>${chip('hideTr', 'Translations', b.hideTr)}${chip('hideAdult', 'Adult', b.hideAdult)}${chip('hideCheats', 'Cheats', b.hideCheats)}${chip('hideCosmetic', 'Cosmetic', b.hideCosmetic)}</div>
        </div>
      </header>
      <div class="page-body">
        <div class="legend" style="margin:0 0 16px"><span>${compatPill({ k: 'ok', label: 'Updated for ' + p.label, tip: '' })} updated after the patch</span><span>${compatPill({ k: 'asset', label: 'Asset mod', tip: '' })} no scripts, usually works</span><span>${compatPill({ k: 'warn', label: 'Unverified', tip: '' })} scripts older than the patch</span></div>
        <div id="results"></div><div id="foot" class="foot"></div>
      </div>`;
    renderResults(true);
    if (!b.loaded && !b.loading) loadBrowse(true);
    if (!S.cats) loadCats();
  }

  function modFilter(b) {
    const f = { gameDomainName: [{ value: GAME, op: 'EQUALS' }] }, q = b.q.replace(/[*%?]/g, ' ').trim();
    // whole words in any form ("unlocking" finds "Unlocked") or part of a word ("misce" finds "Miscellaneous")
    if (q) f.filter = [{ op: 'OR', nameStemmed: [{ value: q, op: 'MATCHES' }], name: [{ value: q, op: 'WILDCARD' }] }];
    if (b.cat) f.categoryName = [{ value: b.cat, op: 'EQUALS' }];
    else if (b.hideCosmetic) f.categoryName = COSMETIC.map(c => ({ value: c, op: 'NOT_EQUALS' }));
    const tags = [];
    if (b.tag) tags.push({ value: b.tag, op: 'EQUALS' });
    if (b.hideTr) tags.push({ value: 'Translation', op: 'NOT_EQUALS' });
    if (b.hideCheats) tags.push({ value: 'Cheating', op: 'NOT_EQUALS' });
    if (tags.length) f.tag = tags;
    if (b.hideAdult) f.adultContent = { value: false, op: 'EQUALS' };
    if (b.compat === 'updated') f.updatedAt = [{ value: String(patch().epoch), op: 'GTE' }];
    return f;
  }
  const modSort = b => [{ [b.sort === 'relevance' && !b.q.trim() ? 'endorsements' : b.sort]: { direction: 'DESC' } }];

  async function loadBrowse(reset) {
    const b = S.b;
    if (reset) { b.items = []; b.offset = 0; b.total = 0; b.hidden = 0; b.end = false; b.err = null; b.seq++; }
    else if (b.loading || b.end) return;
    const seq = b.seq;
    b.loading = true;
    renderResults(reset);
    try {
      const d = await gql(`query($f: ModsFilter, $s: [ModsSort!], $o: Int, $c: Int) { mods(filter: $f, sort: $s, offset: $o, count: $c) { totalCount nodes { ${MOD_FIELDS} ${REQ_FIELDS} } } }`, { f: modFilter(b), s: modSort(b), o: b.offset, c: PAGE });
      if (seq !== b.seq) return;
      const nodes = (d.mods && d.mods.nodes) || [];
      b.total = (d.mods && d.mods.totalCount) || 0;
      b.offset += nodes.length;
      b.end = nodes.length < PAGE || b.offset >= b.total;
      const keep = b.compat === 'likely' ? nodes.filter(m => compatOf(m).k !== 'warn') : nodes;
      b.hidden += nodes.length - keep.length;
      const seen = new Set(b.items.map(m => m.modId));
      b.items.push(...keep.filter(m => !seen.has(m.modId)));
      b.loaded = true;
    } catch (e) { if (seq !== b.seq) return; b.err = e.message; }
    b.loading = false;
    renderResults(false);
  }

  function renderResults(full) {
    const box = $('#results'), foot = $('#foot');
    if (!box || !foot) return;
    const b = S.b, wrapCls = b.view === 'list' ? 'rows' : 'tiles', card = b.view === 'list' ? modRow : modTile;
    const wrap = box.querySelector('.' + wrapCls);
    if (b.err && !b.items.length) box.innerHTML = `<div class="err">${h(b.err)}</div>`;
    else if (!b.items.length && b.loading) box.innerHTML = b.view === 'list' ? `<div class="rows">${'<div class="sk" style="height:76px"></div>'.repeat(8)}</div>` : `<div class="tiles">${'<div class="sk sk-tile"></div>'.repeat(8)}</div>`;
    else if (!b.items.length) box.innerHTML = b.loaded ? `<div class="empty"><h3>No mods match</h3>Try another search, or loosen the filters above.</div>` : '';
    else if (wrap && !full && b.renderSeq === b.seq && b.rendered <= b.items.length) wrap.insertAdjacentHTML('beforeend', b.items.slice(b.rendered).map(card).join(''));
    else box.innerHTML = `<div class="${wrapCls}">${b.items.map(card).join('')}</div>`;
    b.rendered = b.items.length; b.renderSeq = b.items.length ? b.seq : -1;
    const parts = [];
    if (b.loading && b.items.length) parts.push('<span class="spin"></span><span>Loading more</span>');
    else if (b.err && b.items.length) parts.push(`<span class="err">${h(b.err)}</span><button class="btn sm" data-act="b-more">Retry</button>`);
    else if (!b.end && b.loaded) parts.push('<button class="btn" data-act="b-more">Load more</button>');
    if (b.loaded) parts.push(`<span class="dim">${fmtNum(b.total)} mods${b.hidden ? ` &middot; ${b.hidden} unverified hidden (<button class="link-btn" data-act="b-compat" data-v="all">show</button>)` : ''}</span>`);
    foot.innerHTML = parts.join('');
    observeFoot();
  }

  let io = null;
  function observeFoot() {
    const foot = $('#foot');
    if (!foot || !('IntersectionObserver' in window)) return;
    if (!io) io = new IntersectionObserver(es => {
      const b = S.b;
      if (es.some(e => e.isIntersecting) && S.page === 'discover' && b.loaded && !b.loading && !b.end && !b.err) loadBrowse(false);
    }, { root: $('#page'), rootMargin: '700px' });
    io.disconnect(); io.observe(foot);
  }

  const stats = m => `<span class="stat" title="Endorsements">${ic('thumb')}${fmtNum(m.endorsements)}</span><span class="stat" title="Downloads">${ic('dl')}${fmtNum(m.downloads)}</span><span class="stat" title="Last updated">${ic('clock')}${fmtDate(m.updatedAt)}</span>`;
  // tile picture by the Performance setting: large, small or none
  function tilePic(m) { const p = perf().pics; return p === 'off' ? '' : p === 'small' ? (m.thumbnailUrl || m.thumbnailLargeUrl) : (m.thumbnailLargeUrl || m.thumbnailUrl); }
  function modTile(m) {
    const img = tilePic(m), key = 'mod:' + (+m.modId);
    return `<article class="tile${selKey() === key ? ' selected' : ''}" data-act="open-mod" data-id="${+m.modId}" data-sel="${key}" tabindex="0">
      <div class="tile-img">${img ? `<img ${IMG.attr(img)} alt="">` : `<div class="noimg">${perf().pics === 'off' ? '' : 'No image'}</div>`}<div class="tile-flags">${compatPill(compatOf(m))}${statusPill(modStatus(m.modId))}</div></div>
      <div class="tile-body"><div class="tile-title">${h(decode(m.name))}</div><div class="tile-meta">${h(m.author || (m.uploader && m.uploader.name) || '')}${m.modCategory ? ' &middot; ' + h(m.modCategory.name) : ''}</div>
      <p class="tile-sum">${h(stripBB(m.summary))}</p><div class="tile-foot">${stats(m)}</div></div></article>`;
  }
  function modRow(m) {
    const img = perf().pics === 'off' ? '' : m.thumbnailUrl || m.thumbnailLargeUrl, key = 'mod:' + (+m.modId);
    return `<div class="row${selKey() === key ? ' selected' : ''}" data-act="open-mod" data-id="${+m.modId}" data-sel="${key}" tabindex="0">
      ${img ? `<img class="row-thumb" ${IMG.attr(img)} alt="">` : '<div class="row-thumb"></div>'}
      <div class="row-main"><div class="row-title"><span class="t">${h(decode(m.name))}</span>${compatPill(compatOf(m))}${statusPill(modStatus(m.modId))}</div><div class="row-sub">${h(stripBB(m.summary))}</div></div>
      <div class="row-stats">${stats(m)}</div></div>`;
  }

  async function loadCats() {
    S.cats = [];
    try { S.cats = (await api('/api/modcats')).categories || []; if (!S.cats.length) throw new Error('empty'); }
    catch (e) { S.cats = ['Animations', 'Appearance', 'Armour and Clothing', 'Audio', 'Characters', 'Crafting', 'Gameplay', 'Miscellaneous', 'Modders Resources', 'Scripts', 'User Interface', 'Utilities', 'Vehicles', 'Visuals and Graphics', 'Weapons']; }
    const sel = $('#b-cat');
    if (sel) sel.innerHTML = opt([['', 'All categories']].concat(S.cats.map(c => [c, c])), S.b.cat);
  }

  // ---------- collections ----------
  function pageCollections(el) {
    const c = S.c, p = patch();
    const cats = [['', 'All categories']].concat([...new Set((c.all || []).map(x => x.category && x.category.name).filter(Boolean))].sort().map(x => [x, x]));
    el.innerHTML = `
      <header class="page-head">
        <div class="ph-top" style="align-items:center">
          <h1>Collections</h1>
          <div class="searchbar" style="flex:1;max-width:620px">${ic('search')}<input id="c-q" type="search" placeholder="Search collections   ( / )" value="${h(c.q)}" autocomplete="off" spellcheck="false" aria-label="Search collections"></div>
          <span></span>
        </div>
        <div class="toolbar">
          <select id="c-sort" aria-label="Sort">${opt(CSORTS, c.sort)}</select>
          <select id="c-cat" aria-label="Category">${opt(cats, c.cat)}</select>
          <span class="spacer"></span>
          <div class="chips">${chip('only', 'Built for ' + p.label, c.only, 'data-cchip')}${chip('adult', 'Show adult', c.adult, 'data-cchip')}</div>
        </div>
      </header>
      <div class="page-body"><p class="dim small" style="margin:0 0 16px">Mod lists put together by other players. Open one to see what is in it and download only what you want.</p><div id="c-results"></div></div>`;
    renderColResults();
    if (!c.all && !c.loading) loadCollections();
  }
  async function loadCollections() {
    const c = S.c;
    c.loading = true; c.err = null;
    try {
      const all = [];
      for (let off = 0; off < 3000; off += 100) {
        const d = await gql(`query($f: CollectionsSearchFilter, $o: Int) { collectionsV2(filter: $f, offset: $o, count: 100, sort: [{endorsements: {direction: DESC}}]) { totalCount nodes { slug name summary endorsements totalDownloads user { name } tileImage { thumbnailUrl(size: med) } category { name } latestPublishedRevision { revisionNumber modCount totalSize updatedAt adultContent gameVersions { reference } } } } }`, { f: { gameDomain: [{ value: GAME, op: 'EQUALS' }] }, o: off });
        const pg = d.collectionsV2 || { nodes: [] };
        all.push(...(pg.nodes || []));
        if (!pg.nodes || pg.nodes.length < 100 || all.length >= pg.totalCount) break;
      }
      c.all = all;
    } catch (e) { c.err = e.message; }
    c.loading = false;
    if (S.page === 'collections') pageCollections($('#page'));
  }
  function colList() {
    const c = S.c, q = c.q.trim().toLowerCase();
    let a = (c.all || []).filter(x => x.latestPublishedRevision);
    if (!c.adult) a = a.filter(x => !x.latestPublishedRevision.adultContent);
    if (c.only) a = a.filter(gvOk);
    if (c.cat) a = a.filter(x => x.category && x.category.name === c.cat);
    if (q) a = a.filter(x => [x.name, x.summary, x.user && x.user.name].join(' ').toLowerCase().includes(q));
    const key = { endorsements: x => -(x.endorsements || 0), downloads: x => -(x.totalDownloads || 0), updated: x => -((toDate(x.latestPublishedRevision.updatedAt) || new Date(0)).getTime()), small: x => +x.latestPublishedRevision.modCount || 0 }[c.sort] || (() => 0);
    return a.sort((x, y) => key(x) - key(y));
  }
  function renderColResults() {
    const box = $('#c-results');
    if (!box) return;
    const c = S.c;
    if (c.err) { box.innerHTML = `<div class="err">${h(c.err)}</div>`; return; }
    if (!c.all) { box.innerHTML = `<div class="tiles">${'<div class="sk sk-tile"></div>'.repeat(8)}</div>`; return; }
    const list = colList();
    box.innerHTML = list.length ? `<div class="tiles">${list.map(colTile).join('')}</div><div class="foot dim">${list.length} of ${c.all.length} collections</div>` : '<div class="empty"><h3>No collections match</h3>Try another search or turn off a filter.</div>';
  }
  function colTile(x) {
    const r = x.latestPublishedRevision, img = perf().pics !== 'off' && x.tileImage && x.tileImage.thumbnailUrl, key = 'col:' + x.slug;
    return `<article class="tile${selKey() === key ? ' selected' : ''}" data-act="open-col" data-slug="${h(x.slug)}" data-sel="${h(key)}" tabindex="0">
      <div class="tile-img">${img ? `<img ${IMG.attr(img)} alt="">` : `<div class="noimg">${perf().pics === 'off' ? '' : 'No image'}</div>`}<div class="tile-flags"><span class="pill ${gvOk(x) ? 'ok' : 'warn'}" title="Game version it was built for">Game ${h(gvList(x)[0] || '?')}</span>${r.adultContent ? '<span class="pill bad">Adult</span>' : ''}</div></div>
      <div class="tile-body"><div class="tile-title">${h(decode(x.name))}</div><div class="tile-meta">by ${h(x.user ? x.user.name : '?')}${x.category ? ' &middot; ' + h(x.category.name) : ''}</div>
      <p class="tile-sum">${h(stripBB(x.summary))}</p>
      <div class="tile-foot"><span class="stat">${+r.modCount || 0} mods</span><span class="stat">${fmtSize(r.totalSize)}</span><span class="stat" title="Endorsements">${ic('thumb')}${fmtNum(x.endorsements)}</span><span class="stat" title="Updated">${ic('clock')}${fmtDate(r.updatedAt)}</span></div></div></article>`;
  }

  // ---------- library ----------
  function libItems() {
    const st = S.st, fwNames = new Set(st.frameworks.map(f => f.name));
    const on = st.mods.map(m => Object.assign({}, m, { on: true, fw: fwNames.has(m.name) || /^github:/.test(m.source || ''), kinds: arr(m.kinds) }));
    const off = st.disabled.map(d => Object.assign({}, d, { on: false, fw: false, kinds: arr(d.kinds) }));
    return on.concat(off).sort((a, b) => a.name.localeCompare(b.name));
  }
  // the newer file the last check found, until the mod is on it; frameworks compare versions
  const upOf = m => { const u = S.lib.updates && S.lib.updates[m.name]; return u && +u.fileId !== +m.fileId ? u : null; };
  const fwOf = m => m.fw ? (S.lib.fw || []).find(x => x.name === m.name && x.update && x.latest !== m.version) || null : null;
  const inQueue = fid => S.st.queue.some(q => !q.done && +q.fileId === +fid);
  const hasUpdate = m => !!(upOf(m) || fwOf(m));
  // updates that can go in a batch (not queued already)
  const batchable = () => libItems().filter(m => (upOf(m) && !inQueue(upOf(m).fileId)) || fwOf(m));
  const srcOf = m => { const s = String(m.source || ''); return /^adopted/.test(s) || m.adopted ? 'adopted' : /^nexus:/.test(s) ? 'nexus' : /^github:/.test(s) ? 'github' : 'manual'; };
  const SRC_LABEL = { nexus: 'Nexus', github: 'GitHub', adopted: 'Found in game folder', manual: 'Manual' };
  // conflicts that involve a mod (skips ones marked fine and intended overlaps)
  function modIssues(name) {
    const c = S.lib.compat;
    if (!c || !c.issues) return [];
    return c.issues.filter(i => !i.ignored && i.risk !== 'ok' && (i.mods || []).includes(name));
  }
  // the only conflicts shown outside the Compatibility page: ones that can crash the game or stop mods from loading
  // (a missing requirement, an outdated plugin, a .dll or .asi two mods share)
  const crashy = i => !i.ignored && i.risk === 'high' && ['requirement', 'outdated', 'files'].includes(i.kind);
  const crashIssues = name => modIssues(name).filter(crashy);
  const allCrashIssues = () => ((S.lib.compat && S.lib.compat.issues) || []).filter(crashy);
  function libFiltered() {
    const L = S.lib, q = L.q.trim().toLowerCase();
    let items = libItems();
    if (L.filter === 'mods') items = items.filter(m => !m.fw);
    else if (L.filter === 'fw') items = items.filter(m => m.fw);
    else if (L.filter === 'off') items = items.filter(m => !m.on);
    else if (L.filter === 'upd') items = items.filter(hasUpdate);
    else if (L.filter === 'new') items = items.filter(isNewSinceLaunch);
    if (L.kind) items = items.filter(m => { const k = m.kinds || []; return k.includes(L.kind) || (L.kind === 'native' && k.includes('loader')) || (L.kind === 'config' && k.includes('plugindata')); });
    if (L.src) items = items.filter(m => srcOf(m) === L.src);
    if (q) items = items.filter(m => m.name.toLowerCase().includes(q));
    const t = m => (toDate(m.on ? m.installed : m.disabledAt) || new Date(0)).getTime();
    const TORDER = ['native', 'redscript', 'cet', 'tweak', 'xl', 'archive', 'input', 'config'];
    const typeKey = m => { const k = m.kinds || []; const i = TORDER.findIndex(x => k.includes(x)); return i < 0 ? 99 : i; };
    const byName = (a, b) => a.name.localeCompare(b.name);
    const cmp = { name: byName, '-name': (a, b) => b.name.localeCompare(a.name), new: (a, b) => t(b) - t(a) || byName(a, b), old: (a, b) => t(a) - t(b) || byName(a, b), size: (a, b) => (b.size || 0) - (a.size || 0) || byName(a, b), files: (a, b) => (b.fileCount || 0) - (a.fileCount || 0) || byName(a, b), type: (a, b) => typeKey(a) - typeKey(b) || byName(a, b) }[L.sort] || byName;
    return items.sort(cmp);
  }
  function pageLibrary(el) {
    el.innerHTML = `
      <header class="page-head"><div class="ph-top">
        <div><h1>Library</h1><p class="sub">Everything cpmods manages in your game folder. Click a mod for its files; switches turn mods off without deleting them.</p></div>
        <div class="ph-actions">
          <button class="btn" data-act="lib-updates"${S.lib.checking ? ' disabled' : ''}>${S.lib.checking ? '<span class="spin"></span>Checking' : ic('refresh') + 'Check for updates'}</button>
          <button class="btn" data-act="tool" data-tool="profiles" title="Named sets of mods to switch between">${ic('collections')}${S.st.profile ? `Profile: ${h(S.st.profile)}` : 'Profiles'}</button>
          <button class="btn" data-act="tool" data-tool="backups" title="Restore points, save copies and mod settings">${ic('history')}Backups</button>
          <button class="icon-btn" data-act="lib-more" title="More tools" aria-label="More tools">${ic('more')}</button>
        </div></div></header>
      <div class="page-body" id="lib-body"></div>`;
    renderLibBody();
    ensureCompat(false);
    autoCheckUpdates();
  }
  function renderLibBody() {
    const body = $('#lib-body');
    if (!body) return;
    // the header button names the profile in use (the header itself is not redrawn by state changes)
    const pb = $('#page [data-tool="profiles"]');
    if (pb) setHtml(pb, ic('collections') + (S.st.profile ? `Profile: ${h(S.st.profile)}` : 'Profiles'));
    const all = libItems(), L = S.lib;
    const n = { all: all.length, mods: all.filter(m => !m.fw).length, fw: all.filter(m => m.fw).length, off: all.filter(m => !m.on).length, upd: all.filter(hasUpdate).length, nw: all.filter(isNewSinceLaunch).length };
    const segs = [['all', 'All', n.all], ['mods', 'Mods', n.mods], ['fw', 'Frameworks', n.fw], ['off', 'Disabled', n.off], ['upd', 'Updates', L.updates ? n.upd : '?'], ['new', 'New', n.nw]];
    body.innerHTML = `
      <div class="statusline" id="lib-sum"></div>
      <div class="lib-tools">
        <div class="toolbar"><div class="seg" role="group" aria-label="Show">${segs.map(([v, l, c]) => `<button data-act="lib-filter" data-v="${v}" class="${L.filter === v ? 'on' : ''}" title="${{ new: 'Installed after your last launch: not tested in game yet' }[v] || l}">${l} <span class="n">${c}</span></button>`).join('')}</div>
          <span class="spacer"></span><div class="seg icons" role="group" aria-label="View">${[['list', 'List'], ['map', 'Folder map: where each mod sits in the game folder']].map(([v, tip]) => `<button data-act="lib-view" data-v="${v}" class="${L.view === v ? 'on' : ''}" title="${tip}">${ic(v)}<span>${v === 'list' ? 'List' : 'Map'}</span></button>`).join('')}</div></div>
        <div class="toolbar">
          <div class="searchbar sm">${ic('search')}<input type="search" id="lib-q" placeholder="Filter by name   ( / )" value="${h(L.q)}" aria-label="Filter by name"></div>
          <select id="lib-kind" aria-label="Type of mod">${opt(KIND_FILTER, L.kind)}</select>
          <select id="lib-src" aria-label="Source">${opt([['', 'Any source'], ['nexus', 'Nexus'], ['github', 'GitHub (frameworks)'], ['adopted', 'Found in game folder'], ['manual', 'Manual']], L.src)}</select>
          ${L.view === 'map' ? '' : `<select id="lib-sort" aria-label="Sort">${opt(LSORTS, L.sort)}</select>`}
          <span class="dim small" id="lib-count"></span>
        </div>
      </div>
      <div id="lib-list"></div>`;
    renderLibSum();
    renderLibList();
  }
  // one compact line instead of tiles: the filter counts already show new/disabled; conflicts only when they can crash the game
  function renderLibSum() {
    const box = $('#lib-sum');
    if (!box) return;
    const all = libItems(), L = S.lib;
    const n = { mods: all.filter(m => !m.fw).length, fw: all.filter(m => m.fw).length, upd: all.filter(hasUpdate).length };
    const cr = allCrashIssues().length;
    const size = all.filter(m => m.on).reduce((s, m) => s + (+m.size || 0), 0);
    box.innerHTML = `<span class="st-item"><b>${n.mods}</b>&nbsp;mods and ${n.fw} frameworks &middot; ${fmtSize(size)} on disk</span>
      <button class="st-item link${n.upd ? ' warn' : ''}" data-act="${L.updates ? 'lib-filter' : 'lib-updates'}" data-v="upd">${L.checking && !L.updates ? '<span class="spin"></span>Checking for updates' : ic('refresh') + (L.updates ? (n.upd ? `${plural(n.upd, 'update')} available` : 'Everything up to date') : 'Updates not checked')}</button>
      ${cr ? `<button class="st-item link bad" data-act="go" data-page="compat" title="See them on the Compatibility page">${ic('alert')}${plural(cr, 'problem')} that can crash the game</button>` : ''}`;
  }
  function renderLibList() {
    const box = $('#lib-list');
    if (!box) return;
    const L = S.lib, items = libFiltered(), cnt = $('#lib-count');
    if (cnt) cnt.textContent = `${items.length} shown`;
    if (L.view === 'map') return renderLibMap(box, items);
    if (!items.length) {
      const empty = !S.st.mods.length && !S.st.disabled.length;
      box.innerHTML = `<div class="card"><div class="empty">${empty ? `<h3>No mods yet</h3>Find mods in Discover, or let cpmods take over mods you installed before.<br><button class="btn primary" data-act="go" data-page="discover">Browse mods</button> <button class="btn" data-act="tool" data-tool="discover">Find existing mods</button>` : L.filter === 'upd' && !L.updates ? (L.checking ? '<h3><span class="spin"></span> Checking for updates</h3>This runs in the background; keep using the app.' : `<h3>Updates not checked yet</h3><button class="btn primary" data-act="lib-updates">Check for updates</button>`) : '<h3>Nothing here</h3>No mods match these filters.'}</div></div>`;
      return;
    }
    // Updates view: tick the ones to update, then one button for all of them
    const bat = L.filter === 'upd' ? batchable() : [], sel = bat.filter(m => L.updSel[m.name] !== false);
    const bar = bat.length ? `<div class="action-card" style="margin-bottom:12px"><div class="action-row"><label class="check-row" style="flex:none" title="Select all"><input type="checkbox" class="check" id="upd-all"${sel.length === bat.length ? ' checked' : ''} aria-label="Select all updates"></label>
      <div class="action-file"><b>${sel.length} of ${plural(bat.length, 'update')} selected</b><span>A restore point is made first.${bat.some(m => !fwOf(m)) ? ' Each Nexus file needs one "Slow download" click; the next page opens by itself.' : ''}</span></div>
      <button class="btn primary" data-act="upd-batch"${sel.length ? '' : ' disabled'}>${ic('refresh')}${sel.length === bat.length ? 'Update all' : `Update ${sel.length} selected`}</button></div></div>` : '';
    box.innerHTML = bar + `<div class="card"><div class="list">${items.map(libRow).join('')}</div></div>`;
  }
  function libRow(m) {
    const src = srcOf(m), nx = String(m.source || '').match(/nexus:(\d+)/);
    const up = upOf(m), fwu = fwOf(m), queued = up && inQueue(up.fileId);
    const cr = crashIssues(m.name), isNew = isNewSinceLaunch(m);
    const pills = [m.fw ? '<span class="pill">Framework</span>' : '', src === 'adopted' ? '<span class="pill muted" title="Installed before cpmods; removing sends its files to the Recycle Bin">Existing files</span>' : '',
      isNew ? '<span class="pill info" title="Installed after your last launch: not tested in game yet">New</span>' : '',
      cr.length ? `<span class="pill bad" title="${h(cr.map(i => i.title).join('\n'))}&#10;Details on the Compatibility page.">May crash</span>` : '',
      up ? (queued ? `<span class="pill info" title="Waiting in the download queue">v${h(up.version)} queued</span>` : `<span class="pill warn">v${h(up.version)} available</span>`) : '', fwu ? `<span class="pill warn">${h(fwu.latest)} available</span>` : '', m.broken ? '<span class="pill bad">Incomplete install</span>' : ''].join('');
    const sub = [(m.kinds || []).length ? `<span class="kchips">${kindChips(m.kinds)}</span>` : '', SRC_LABEL[src], m.on ? (m.installed ? 'added ' + fmtDate(m.installed) : '') : 'off since ' + fmtDate(m.disabledAt),
      m.fileCount != null ? plural(m.fileCount, 'file') + (m.size ? ' &middot; ' + fmtSize(m.size) : '') : ''].filter(Boolean).map(x => `<span>${x}</span>`).join('');
    const sw = m.fw ? '<span class="switch" title="Frameworks stay on; other mods need them"><input type="checkbox" checked disabled><span></span></span>'
      : `<label class="switch" title="${m.on ? 'On: click to disable (files are set aside, not deleted)' : 'Off: click to enable'}"><input type="checkbox" data-toggle="${h(m.name)}"${m.on ? ' checked' : ''} aria-label="${m.on ? 'Disable' : 'Enable'} ${h(m.name)}"><span></span></label>`;
    const pick = S.lib.filter === 'upd' && ((up && !queued) || fwu) ? `<label class="check-row" style="flex:none" title="Include in the batch update"><input type="checkbox" class="check" data-usel="${h(m.name)}"${S.lib.updSel[m.name] === false ? '' : ' checked'} aria-label="Update ${h(m.name)}"></label>` : '';
    const acts = (up && nx && !queued ? `<button class="btn sm primary" data-act="get" data-mod="${nx[1]}" data-file="${+up.fileId}" data-name="${h(m.name)}" title="Opens the new file on Nexus; click Slow download there">Update</button>` : '')
      + (fwu ? '<button class="btn sm primary" data-act="fw-sync">Update</button>' : '')
      + `<button class="icon-btn" data-act="row-menu" data-name="${h(m.name)}" title="More actions" aria-label="More actions for ${h(m.name)}">${ic('more')}</button>`;
    const sel = m.modId ? 'mod:' + (+m.modId) : 'files:' + m.name;
    return `<div class="li lib-row click${m.on ? '' : ' off'}${selKey() === sel ? ' selected' : ''}" data-act="lib-open" data-name="${h(m.name)}" data-sel="${h(sel)}" tabindex="0" title="Show details and files">${pick}${sw}<div class="li-main"><div class="li-title"><span class="t">${h(m.name)}</span>${m.version ? `<span class="ver">${h(m.version)}</span>` : ''}${pills}</div><div class="li-sub">${sub}</div></div><div class="li-acts">${acts}</div></div>`;
  }
  async function ensureCompat(force) {
    if (S.lib.compatStale) force = true;
    if (S.lib.compatLoading || (S.lib.compat && !S.lib.compat.error && !force)) return;
    S.lib.compatLoading = true; S.lib.compatStale = false;
    if (S.page === 'compat') renderPage();
    try { S.lib.compat = await api('/api/compat'); } catch (e) { S.lib.compat = { error: e.message }; }
    S.lib.compatLoading = false;
    if (S.page === 'library') { renderLibSum(); if (!typing()) renderLibBody(); else renderLibList(); }
    if (S.page === 'compat') renderPage();
    renderNav();
    if (S.pane && (S.pane.kind === 'mod' || S.pane.kind === 'files')) renderPane();
  }
  async function ensureLibFiles() {
    if (S.lib.filesLoading || (S.lib.files && S.lib.filesSig === S.sig)) return;
    S.lib.filesLoading = true;
    try { S.lib.files = (await api('/api/libfiles')).mods || []; S.lib.filesSig = S.sig; S.lib.filesErr = null; } catch (e) { S.lib.filesErr = e.message; }
    S.lib.filesLoading = false;
    if (S.page === 'library' && S.lib.view === 'map') renderLibList();
  }
  function locHead(L, right) {
    return `<div class="loc-head"><span class="loc-ic ${L.c}">${ic(L.i)}</span><div class="loc-txt"><b>${h(L.t)}</b><span class="mono-path">${h(L.p ? L.p + '\\' : 'other places')}</span></div>${right ? `<span class="loc-by">${right}</span>` : ''}</div>`;
  }
  // folder map: one box per mod folder with the mods that put files there
  function renderLibMap(box, items) {
    if (!S.lib.files || S.lib.filesSig !== S.sig) {
      ensureLibFiles();
      if (!S.lib.files) { box.innerHTML = S.lib.filesErr ? `<div class="err">${h(S.lib.filesErr)}</div>` : '<div class="card"><div class="card-body"><span class="spin"></span> Reading where your mods are installed</div></div>'; return; }
    }
    const want = new Set(items.filter(m => m.on).map(m => m.name)), byLoc = new Map();
    for (const m of S.lib.files) {
      if (!want.has(m.name)) continue;
      for (const f of m.files || []) {
        const L = locOf(f);
        if (!byLoc.has(L.k)) byLoc.set(L.k, new Map());
        const mm = byLoc.get(L.k);
        mm.set(m.name, (mm.get(m.name) || 0) + 1);
      }
    }
    const offN = items.filter(m => !m.on).length, explain = prefs.explain === true, open = S.lib.mapOpen;
    const keys = LOCS.filter(L => byLoc.has(L.k)).map(L => L.k), allOpen = keys.length && keys.every(k => open.has(k));
    const nodes = LOCS.filter(L => byLoc.has(L.k)).map(L => {
      const mods = [...byLoc.get(L.k).entries()].sort((a, b) => a[0].localeCompare(b[0])), files = mods.reduce((s, x) => s + x[1], 0), on = open.has(L.k);
      return `<div class="loc map-loc${on ? ' open' : ''}"><button class="loc-row" data-act="map-loc" data-k="${L.k}" aria-expanded="${on}" title="${on ? 'Hide' : 'Show'} the mods in this folder"><span class="loc-ic ${L.c}">${ic(L.i)}</span><span class="loc-txt"><b>${h(L.t)}</b><span><span class="mono-path">${h(L.p ? L.p + '\\' : 'other places')}</span>${L.by ? ` &middot; ${h(L.by)}` : ''}</span></span><span class="loc-n"><b>${mods.length}</b> ${mods.length === 1 ? 'mod' : 'mods'}<em>${plural(files, 'file')}</em></span><span class="chev">${ic(on ? 'down' : 'fwd')}</span></button>
        ${on ? `<div class="loc-open">${explain ? `<p class="loc-d">${h(L.d)}</p>` : ''}<div class="mchips">${mods.map(([n, c]) => `<button class="mchip" data-act="lib-open" data-name="${h(n)}" title="${h(n)}: ${plural(c, 'file')} here">${h(n)}<span>${c}</span></button>`).join('')}</div></div>` : ''}</div>`;
    }).join('');
    box.innerHTML = `<div class="schema map"><div class="schema-root">${ic('folder')}<b>Cyberpunk 2077</b><span class="mono-path">${h(S.st.paths.game)}</span><span class="spacer"></span>${keys.length ? `<button class="link-btn small" data-act="map-all">${allOpen ? 'Collapse all' : 'Expand all'}</button>` : ''}<button class="link-btn small" data-act="toggle-explain">${explain ? 'Hide explanations' : 'Explain folders'}</button></div>
      <div class="schema-branches">${nodes || '<div class="empty">No enabled mods match these filters.</div>'}</div></div>
      <p class="dim small map-foot">Each row is a folder that the game or a framework reads when it starts. Open one to see which mods put files there; click a mod for its exact files.${offN ? ` ${plural(offN, 'disabled mod')} not shown.` : ''}</p>`;
  }

  // quiet: the background check the Library starts by itself (no toast, the view and filter stay as they are)
  async function checkUpdates(quiet) {
    if (S.lib.checking) return;
    S.lib.checking = true;
    if (quiet) { if (S.page === 'library') { renderLibSum(); libUpdBtn(); } }
    else if (S.page === 'library' && !typing()) pageLibrary($('#page'));
    else if (S.page === 'reports') renderReportsBody();
    try {
      const nexus = stMods().filter(m => /^nexus:/.test(m.source || '') && m.modId);
      const ids = [...new Set(nexus.map(m => +m.modId))], files = {};
      for (let i = 0; i < ids.length; i += 20) {
        const chunk = ids.slice(i, i + 20);
        const d = await gql('{ ' + chunk.map(id => `m${id}: modFiles(modId: ${id}, gameId: 3333) { fileId name version category date }`).join(' ') + ' }');
        chunk.forEach(id => { files[id] = d['m' + id] || []; });
      }
      const ups = {};
      for (const m of nexus) {
        const list = files[+m.modId] || [], cur = list.find(f => +f.fileId === +m.fileId);
        const live = list.filter(f => LIVE.includes(f.category) && +f.fileId !== +m.fileId && (!cur || f.date > cur.date));
        const curName = norm((cur && cur.name) || m.fileName || '');
        let best = live.filter(f => curName && norm(f.name) === curName).sort((a, b) => b.date - a.date)[0];
        if (!best && cur && !LIVE.includes(cur.category)) { const mains = live.filter(f => f.category === 'MAIN'); if (mains.length === 1) best = mains[0]; }
        if (best) ups[m.name] = best;
      }
      S.lib.updates = ups; S.lib.updSel = {};
      try { S.lib.fw = (await api('/api/fwupdates')).items || []; } catch (e) { S.lib.fw = []; }
      S.lib.updatesAt = Date.now();
      const n = Object.keys(ups).length + S.lib.fw.filter(x => x.update).length;
      if (!quiet) {
        toast(n ? `${plural(n, 'update')} available` : 'Everything is up to date', n ? 'Update them all with one button, or untick the ones to skip.' : '', n ? 'warn' : 'ok', 5000);
        if (n) S.lib.filter = 'upd';
      }
    } catch (e) { if (!quiet) toast('Update check failed', e.message, 'bad'); }
    S.lib.checking = false;
    if (quiet) { if (S.page === 'library') { libUpdBtn(); if (!typing()) renderLibBody(); else { renderLibSum(); renderLibList(); } } }
    else if (S.page === 'library') pageLibrary($('#page'));
    else if (S.page === 'reports') renderReportsBody();
  }
  // the Library checks by itself in the background: at most every 30 minutes, never while the game runs
  function autoCheckUpdates() {
    const g = S.st && S.st.game;
    if (S.lib.checking || (g && g.running) || Date.now() - (S.lib.updatesAt || 0) < 30 * 60e3) return;
    checkUpdates(true);
  }
  // the header is not redrawn by a background check: its button follows the check
  function libUpdBtn() {
    const b = $('#page [data-act="lib-updates"]');
    if (!b) return;
    b.disabled = !!S.lib.checking;
    setHtml(b, S.lib.checking ? '<span class="spin"></span>Checking' : ic('refresh') + 'Check for updates');
  }

  // the ticked updates: a restore point, then frameworks from GitHub and Nexus files through the queue,
  // queued under the mod's own name so each one replaces the installed version
  async function updateSelected() {
    const pick = batchable().filter(m => S.lib.updSel[m.name] !== false);
    if (!pick.length) return;
    const fws = pick.filter(fwOf), mods = pick.filter(m => !fwOf(m));
    const body = planGrp(`From Nexus (${mods.length})`, mods.map(m => `${m.name}: ${m.version || '?'} to ${upOf(m).version}`))
      + planGrp(`Frameworks from GitHub (${fws.length})`, fws.map(m => `${m.name}: ${m.version || '?'} to ${fwOf(m).latest}`))
      + `<p class="dim small">cpmods makes a restore point first and keeps the old downloads, so you can go back.${mods.length ? ' Each Nexus file needs one "Slow download" click; the next page opens by itself, and each update installs when it arrives.' : ''}</p>`;
    if (!await ask({ title: `Update ${plural(pick.length, 'mod')}?`, body, ok: 'Update' })) return;
    try { await api('/api/backups', { op: 'point', label: `Before updating ${plural(pick.length, 'mod')}` }); }
    catch (e) { toast('Nothing was updated', `The restore point failed: ${e.message}`, 'bad', 10000); return; }
    if (fws.length) await action({ op: 'frameworks', names: fws.map(m => m.name) }, 'Updating frameworks');
    if (mods.length) await queueAdd(mods.map(m => ({ modId: +m.modId, fileId: +upOf(m).fileId, name: m.name, why: `Update to ${upOf(m).version}` })), true);
    if (S.page === 'library') renderLibBody();
  }

  // ---------- downloads ----------
  function pageDownloads(el) {
    const open = S.st.queue.filter(q => !q.done).length;
    el.innerHTML = `
      <header class="page-head"><div class="ph-top">
        <div><h1>Downloads</h1><p class="sub">What is downloading, what is queued, and the archives cpmods keeps so mods can be turned back on. Click a row to open the mod.</p></div>
        <div class="ph-actions"><button class="btn" data-act="tool" data-tool="packs" title="Get a friend's mods from a code, or share yours">${ic('collections')}Modpacks</button>
          <button class="btn primary" data-act="queue-next"${open ? '' : ' disabled'} title="Opens the next queued file on Nexus; click Slow download there">${ic('ext')}Open next download page${open ? ` (${open})` : ''}</button></div>
      </div>
      <div class="toolbar"><div class="searchbar sm" style="flex:1;max-width:460px">${ic('search')}<input type="search" id="dl-q" placeholder="Filter this page by name   ( / )" value="${h(S.dl.q)}" aria-label="Filter downloads"></div><span class="spacer"></span><button class="btn sm ghost" data-act="sys" data-op="downloads">${ic('folder')}Open downloads folder</button></div></header>
      <div class="page-body" id="dl-body"></div>`;
    renderDlBody();
  }
  const dlMatch = (...vals) => { const q = S.dl.q.trim().toLowerCase(); return !q || vals.some(v => String(v || '').toLowerCase().includes(q)); };
  function dlArchives() {
    const D = S.dl;
    let arch = S.st.downloads.filter(d => dlMatch(d.name, d.file));
    if (D.arch === 'installed') arch = arch.filter(d => d.status === 'installed');
    else if (D.arch === 'disabled') arch = arch.filter(d => d.status === 'disabled');
    else if (D.arch === 'unused') arch = arch.filter(d => d.status === 'unused');
    else if (D.arch === 'problem') arch = arch.filter(d => d.status === 'failed' || d.status === 'pending');
    const t = d => (toDate(d.date) || new Date(0)).getTime(), nm = d => String(d.name || d.file);
    const cmp = { new: (a, b) => t(b) - t(a), old: (a, b) => t(a) - t(b), size: (a, b) => (b.size || 0) - (a.size || 0), small: (a, b) => (a.size || 0) - (b.size || 0), name: (a, b) => nm(a).localeCompare(nm(b)) }[D.sort] || ((a, b) => t(b) - t(a));
    return arch.sort(cmp);
  }
  function renderDlBody() {
    const body = $('#dl-body');
    if (!body) return;
    const st = S.st, D = S.dl, q = st.queue;
    const open = q.filter(x => !x.done && dlMatch(x.name)), doneAll = q.filter(x => x.done), done = doneAll.filter(x => dlMatch(x.name));
    const jobs = st.jobs.filter(j => dlMatch(j.title));
    const jc = { all: jobs.length, running: jobs.filter(j => j.status === 'running').length, done: jobs.filter(j => j.status === 'done').length, error: jobs.filter(j => j.status === 'error').length };
    const base = st.downloads.filter(d => dlMatch(d.name, d.file));
    const ac = { all: base.length, installed: base.filter(d => d.status === 'installed').length, disabled: base.filter(d => d.status === 'disabled').length, unused: base.filter(d => d.status === 'unused').length, problem: base.filter(d => d.status === 'failed' || d.status === 'pending').length };
    const arch = dlArchives();
    const total = st.downloads.reduce((s, d) => s + (+d.size || 0), 0), unusedSize = st.downloads.filter(d => d.status === 'unused').reduce((s, d) => s + (+d.size || 0), 0);
    const failed = st.failed.filter(f => dlMatch(f.name, f.archive)), pending = st.pending.filter(p => dlMatch(p.name, p.archive) && (!arr(p.conflict).length || !askOn()));
    const picks = needChoice().filter(p => dlMatch(p.name, p.archive));
    const seg = (act, cur, list) => `<div class="seg">${list.filter(x => x[2] || x[0] === 'all' || x[0] === cur).map(([v, l, n]) => `<button data-act="${act}" data-v="${v}" class="${cur === v ? 'on' : ''}">${l} <span class="n">${n}</span></button>`).join('')}</div>`;
    body.innerHTML = `<div class="dl-cols">
      <div class="dl-main">
        <div class="card"><div class="card-head"><h3>Downloaded files <span class="pill">${st.downloads.length}</span></h3><span class="dim small">${fmtSize(total)} kept${unusedSize ? ` &middot; ${fmtSize(unusedSize)} not installed` : ''}</span></div>
          <div class="card-tools">${seg('dl-arch', D.arch, [['all', 'All', ac.all], ['installed', 'Installed', ac.installed], ['disabled', 'Disabled', ac.disabled], ['unused', 'Not installed', ac.unused], ['problem', 'Problems', ac.problem]])}<span class="spacer"></span><select id="dl-sort" aria-label="Sort">${opt(DSORTS, D.sort)}</select></div>
          <div class="card-body flush">${arch.length ? `<div class="list">${arch.map(dlRow).join('')}</div>` : '<div class="empty">Nothing here.</div>'}</div></div>
      </div>
      <div class="dl-side">
        <div class="card"><div class="card-head"><h3>Activity</h3>${st.jobs.some(j => j.status !== 'running') ? '<button class="btn sm ghost" data-act="jobs-clear">Clear finished</button>' : ''}</div>
          ${jobs.length ? `<div class="card-tools">${seg('dl-jobs', D.jobs, [['all', 'All', jc.all], ['running', 'Running', jc.running], ['done', 'Finished', jc.done], ['error', 'Failed', jc.error]])}</div>` : ''}
          <div class="card-body flush" id="jobs">${jobsHtml()}</div></div>
        ${picks.length ? `<div class="card"><div class="card-head"><h3>${ic('alert')} Needs your choice <span class="pill warn">${picks.length}</span></h3></div><div class="card-body flush"><div class="list">${picks.map(p => { const own = [...new Set(arr(p.conflict).flatMap(c => arr(c.owners)))]; return `<div class="li"><div class="li-main"><div class="li-title"><span class="t">${h(p.name)}</span></div><div class="li-sub"><span>${plural(arr(p.conflict).length, 'file')} already installed by ${h(own.join(', '))}</span></div></div><div class="li-acts"><button class="btn sm primary" data-act="conflict-open" data-archive="${h(p.archive)}">Choose</button></div></div>`; }).join('')}</div></div></div>` : ''}
        ${failed.length ? `<div class="card"><div class="card-head"><h3>${ic('alert')} Needs attention <span class="pill bad">${failed.length}</span></h3></div><div class="card-body flush"><div class="list">${failed.map(failRow).join('')}</div></div></div>` : ''}
        ${pending.length ? `<div class="card"><div class="card-head"><h3>Waiting to install <span class="pill info">${pending.length}</span></h3><button class="btn sm primary" data-act="fw-sync">Install now</button></div><div class="card-body flush"><div class="list">${pending.map(p => `<div class="li${p.modId ? ' click' : ''}"${p.modId ? ` data-act="open-mod" data-id="${+p.modId}" tabindex="0"` : ''}><div class="li-main"><div class="li-title"><span class="t">${h(p.name)}</span></div><div class="li-sub"><span>${h(p.archive)}</span></div></div><div class="li-acts"><button class="btn sm ghost" data-act="preview" data-file="${h(p.archive)}">See files</button></div></div>`).join('')}</div></div></div>` : ''}
        <div class="card"><div class="card-head"><h3>Queue <span class="pill">${q.filter(x => !x.done).length} left</span></h3>${doneAll.length ? '<button class="btn sm ghost" data-act="queue-clear">Clear finished</button>' : ''}</div>
          <div class="card-body flush">${!q.length ? '<div class="empty"><h3>Queue is empty</h3>Use "Queue" on a mod, or queue a whole collection. Each queued file needs one "Slow download" click on Nexus; the next page opens by itself.</div>'
            : `${open.length ? `<div class="list">${open.map(queueRow).join('')}</div>` : `<div class="empty" style="padding:22px 16px">${S.dl.q ? 'Nothing in the queue matches.' : 'Everything in the queue is downloaded.'}</div>`}
               ${done.length ? `<div style="border-top:1px solid var(--line);padding:8px 12px"><button class="btn sm ghost" data-act="dl-done">${S.dl.showDone ? 'Hide' : 'Show'} ${plural(done.length, 'finished item')}</button></div>${S.dl.showDone ? `<div class="list" style="border-top:1px solid var(--line)">${done.map(queueRow).join('')}</div>` : ''}` : ''}`}</div></div>
      </div></div>`;
  }
  function jobsHtml() {
    const f = S.dl.jobs;
    let jobs = (S.st.jobs || []).filter(j => dlMatch(j.title));
    if (f && f !== 'all') jobs = jobs.filter(j => j.status === f);
    jobs = jobs.sort((a, b) => ((a.status === 'running' ? 0 : 1) - (b.status === 'running' ? 0 : 1)) || String(b.started).localeCompare(String(a.started)));
    if (!jobs.length) return `<div class="empty" style="padding:28px 16px">${(S.st.jobs || []).length ? 'Nothing matches this filter.' : 'Nothing running. Downloads appear here with progress when you click "Slow download" on Nexus.'}</div>`;
    return '<div class="list">' + jobs.slice(0, 40).map(j => {
      const pct = j.total ? Math.min(100, Math.round(100 * (j.done || 0) / j.total)) : null;
      const ph = j.status === 'running' ? (j.phase === 'downloading' && j.total ? `${fmtSize(j.done)} of ${fmtSize(j.total)} (${pct}%)` : (j.phase || 'working')) : j.status === 'done' ? 'Finished' : 'Failed';
      const lead = j.status === 'running' ? '<span class="spin"></span>' : j.status === 'done' ? `<span style="color:var(--ok)">${ic('check')}</span>` : `<span style="color:var(--bad)">${ic('alert')}</span>`;
      const click = j.modId ? ` click" data-act="open-mod" data-id="${+j.modId}" data-sel="mod:${+j.modId}" tabindex="0" title="Open the mod` : '';
      return `<div class="li${click}">${lead}<div class="li-main"><div class="li-title"><span class="t">${h(j.title)}</span>${j.finished ? `<span class="ver">${h(fmtTime(j.finished))}</span>` : ''}</div><div class="li-sub"><span>${h(ph)}</span>${j.detail ? `<span>${h(j.detail)}</span>` : ''}${j.error ? `<span style="color:var(--bad)">${h(j.error)}</span>` : ''}${j.next ? `<span>next page opened: ${h(j.next)}</span>` : ''}</div>${j.status === 'running' ? `<div class="progress${pct == null ? ' ind' : ''}"><div style="width:${pct || 0}%"></div></div>` : ''}</div>${j.status === 'running' && j.phase === 'downloading' ? `<button class="btn sm ghost" data-act="job-cancel" data-id="${h(j.id)}">${j.cancel ? 'Cancelling...' : 'Cancel'}</button>` : ''}${j.modId ? `<span class="li-go">${ic('fwd')}</span>` : ''}</div>`;
    }).join('') + '</div>';
  }
  function failRow(f) {
    const v = S.dl.variant && S.dl.variant.archive === f.archive ? S.dl.variant : null;
    let chooser = '';
    if (v) {
      if (v.loading) chooser = '<div class="inspect"><span class="spin"></span> Reading archive</div>';
      else if (v.error) chooser = `<div class="inspect err">${h(v.error)}</div>`;
      else {
        const cands = (v.candidates || []).filter(c => c !== '.');
        chooser = `<div class="inspect"><div class="dim">${v.fomod ? 'This archive has an installer with options. Pick the folder of the option you want:' : 'Pick which version to install:'}</div>
          ${cands.length ? cands.map(c => `<label style="display:flex;gap:8px;align-items:center;padding:4px 0;cursor:pointer"><input type="radio" class="check" name="variant" value="${h(c)}"${v.sub === c ? ' checked' : ''}> ${h(c)}</label>`).join('') : '<div class="err">No installable folders found.</div>'}
          <div class="toolbar" style="margin-top:8px"><input type="text" id="v-name" value="${h(v.name)}" placeholder="Name in cpmods" style="flex:1"><button class="btn sm primary" data-act="variant-install"${cands.length ? '' : ' disabled'}>Install selected</button><button class="btn sm ghost" data-act="variant-cancel">Cancel</button></div></div>`;
      }
    }
    return `<div class="li" style="flex-wrap:wrap"><div class="li-main"><div class="li-title"><span class="t">${h(f.name)}</span></div><div class="li-sub"><span style="color:var(--warn)">${h(f.error)}</span></div></div>
      <div class="li-acts"><button class="btn sm" data-act="variant" data-archive="${h(f.archive)}" data-name="${h(f.name)}">Choose option</button><button class="btn sm ghost" data-act="preview" data-file="${h(f.archive)}" title="See what is inside the archive">See files</button><button class="btn sm ghost" data-act="dl-install" data-archive="${h(f.archive)}">Retry</button><button class="btn sm ghost" data-act="dismiss" data-name="${h(f.name)}">Dismiss</button></div>
      ${chooser ? `<div style="flex-basis:100%">${chooser}</div>` : ''}</div>`;
  }
  function queueRow(x) {
    return `<div class="li click${x.done ? ' off' : ''}${selKey() === 'mod:' + (+x.modId) ? ' selected' : ''}" data-act="open-mod" data-id="${+x.modId}" data-sel="mod:${+x.modId}" tabindex="0" title="Show this mod">${x.done ? `<span style="color:var(--ok)">${ic('check')}</span>` : '<span class="dot" style="background:var(--line2)"></span>'}<div class="li-main"><div class="li-title"><span class="t">${h(x.name)}</span></div><div class="li-sub">${x.why ? `<span>${h(x.why)}</span>` : ''}</div></div>
      <div class="li-acts">${x.done ? '' : `<button class="btn sm" data-act="get" data-mod="${+x.modId}" data-file="${+x.fileId}" data-name="${h(x.name)}" title="Opens the download page for this file on Nexus">Open page</button><button class="btn sm ghost" data-act="queue-skip" data-file="${+x.fileId}">Skip</button>`}<button class="icon-btn" data-act="queue-remove" data-file="${+x.fileId}" title="Remove from queue">${ic('x')}</button></div></div>`;
  }
  function dlRow(d) {
    const label = { installed: 'Installed', disabled: 'Disabled', pending: 'Waiting', failed: 'Needs attention', unused: 'Not installed' }[d.status] || d.status;
    const sel = d.modId ? 'mod:' + (+d.modId) : 'preview:' + d.file;
    const click = d.modId ? `data-act="open-mod" data-id="${+d.modId}" title="Open the mod"` : `data-act="preview" data-file="${h(d.file)}" title="See what is inside"`;
    return `<div class="li click${selKey() === sel ? ' selected' : ''}" ${click} data-sel="${h(sel)}" tabindex="0"><div class="li-main"><div class="li-title"><span class="t">${h(d.name || d.file)}</span>${d.version ? `<span class="ver">v${h(String(d.version).replace(/^v/i, ''))}</span>` : ''}<span class="stag s-${h(d.status)}">${h(label)}</span></div><div class="li-sub"><span>${fmtSize(d.size)}</span><span>${fmtDate(d.date)}</span>${d.name ? `<span class="fname" title="${h(d.file)}">${h(d.file)}</span>` : ''}</div></div>
      <div class="li-acts">${d.status === 'unused' ? `<button class="btn sm" data-act="dl-install" data-archive="${h(d.file)}">Install</button>` : ''}<button class="icon-btn" data-act="dl-menu" data-file="${h(d.file)}" data-status="${h(d.status)}" data-mod="${+d.modId || ''}" title="More actions" aria-label="More actions">${ic('more')}</button></div></div>`;
  }

  // ---------- reports: last launch report, what to fix, crashes, past launches, troubleshooting ----------
  const launchKey = () => { const l = launchSt(); return l ? [l.log, l.end, l.lastCrash, l.result].join('|') : ''; };
  async function loadLaunch(fresh) {
    const L = S.launch;
    if (L.loading) return;
    L.loading = true;
    if (S.page === 'reports' && !L.data) renderReportsBody();
    try { L.data = await api('/api/launch' + (fresh ? '?fresh=1' : '')); L.err = null; L.key = launchKey(); }
    catch (e) { L.err = e.message; }
    L.loading = false;
    if (S.page === 'reports') renderReportsBody();
    // the Game page shows the Steam launch options read with the report
    else if (S.page === 'game' && !typing()) renderPage();
    if (S.pane && ['mod', 'files', 'crash', 'bisect'].includes(S.pane.kind)) renderPane();
  }
  function pageReports(el) {
    el.innerHTML = `
      <header class="page-head"><div class="ph-top">
        <div><h1>Reports</h1><p class="sub">How the last launch went, what to fix, crash reports and past launches.</p></div>
        <div class="ph-actions" id="rep-acts"></div>
      </div></header>
      <div class="page-body" id="rep-body"></div>`;
    renderReportsActs();
    renderReportsBody();
    if (!S.launch.data || S.launch.key !== launchKey()) loadLaunch(false);
  }
  function renderReportsActs() {
    const g = S.st.game;
    setHtml($('#rep-acts'), `<button class="icon-btn" data-act="launch-refresh" title="Read the logs again" aria-label="Read the logs again">${ic('refresh')}</button>${killBtn(true)}<button class="btn primary" data-act="play"${g.running || g.missing ? ' disabled' : ''}>${ic('play')}${g.running ? 'Running' : 'Play'}</button>`);
  }
  function renderReportsBody() {
    const body = $('#rep-body');
    if (!body) return;
    const L = S.launch, d = L.data;
    if (!d) { body.innerHTML = bisectCard() + (L.err ? `<div class="err">${h(L.err)}</div>` : '<div class="card"><div class="card-body"><span class="spin"></span> Reading the game and mod logs</div></div>'); return; }
    const tabs = [['mods', 'Mods on last launch', (d.mods || []).length], ['crashes', 'Crash reports', (d.crashes || []).length], ['history', 'Recent launches', (d.history || []).length]];
    const tab = tabs.some(x => x[0] === S.rep.tab) ? S.rep.tab : d.session && d.session.result === 'crash' ? 'crashes' : 'mods';
    const panel = { mods: launchModsCard, crashes: crashesCard, history: historyCard }[tab];
    body.innerHTML = `${bisectCard()}${d.none ? '<div class="card"><div class="empty"><h3>No launch recorded yet</h3>Launch the game once with mods installed; cpmods then explains what loaded and what did not.</div></div>' : lastLaunchCard(d)}
      <div class="tabbar" role="tablist">${tabs.map(([v, l, n]) => `<button class="tabbar-btn${tab === v ? ' on' : ''}" data-act="rep-tab" data-v="${v}" role="tab" aria-selected="${tab === v}">${l}${n != null ? `<span class="n${v === 'crashes' && n ? ' hot' : ''}">${n}</span>` : ''}</button>`).join('')}</div>
      ${panel(d)}`;
  }
  const STAGE_SHORT = { start: 'Game', red4ext: 'RED4ext', cet: 'CET', scripts: 'redscript', tweaks: 'TweakXL', archives: 'Archives', end: 'Exit' };
  function lastLaunchCard(d) {
    const s = d.session, c = s.crash, help = prefs.flowHelp === true;
    const hd = { clean: ['ok', 'check', 'Closed normally'], crash: ['bad', 'alert', 'Crashed' + (c ? ' ' + c.when : '')], running: ['run', 'play', 'Running now'], ended: ['warn', 'alert', 'Stopped without closing normally'] }[s.result] || ['', 'info', 'Unknown'];
    return `<div class="card launch-card"><div class="launch-hero ${hd[0]}"><span class="lh-ic">${ic(hd[1])}</span><div class="lh-txt"><b>Last launch: ${h(hd[2])}</b><span>Started ${h(fmtWhen(s.start))}${s.result !== 'running' ? ` &middot; ran ${h(fmtDur(s.seconds))}` : ''} &middot; game ${h(s.product || '?')}${s.red4ext ? ` &middot; RED4ext ${h(s.red4ext)}` : ''}</span></div>${c ? `<button class="btn sm" data-act="open-crash" data-id="${h(c.id)}">Crash details</button>` : ''}</div>
      <div class="card-body"><div class="row-head"><span class="sub-label">What loaded</span><button class="link-btn small" data-act="toggle-flowhelp">${help ? 'Hide the explanations' : 'Explain each step'}</button></div>
        ${help ? flowList(d) : pipeline(d)}
        <div class="row-head" style="margin-top:18px"><span class="sub-label">What to do</span>${!S.lib.updates && (d.issues || []).some(i => i.kind === 'mod') ? `<button class="link-btn small" data-act="lib-updates"${S.lib.checking ? ' disabled' : ''}>${S.lib.checking ? 'Checking for updates...' : 'Check these mods for updates'}</button>` : ''}</div>${issuesHtml(d.issues || [])}</div></div>`;
  }
  // launch stages as one compact row; the full list with explanations is one click away
  function pipeline(d) {
    const icon = { ok: 'check', warn: 'alert', bad: 'alert', run: 'play' };
    return `<ol class="pipe">${(d.stages || []).map((s, i) => `<li class="pipe-step ${h(s.status)}" title="${h(s.title)}&#10;${h(s.detail)}"><span class="ps-dot">${s.status === 'skip' ? i + 1 : ic(icon[s.status] || 'info')}</span><span class="ps-txt"><b>${h(STAGE_SHORT[s.key] || s.title)}</b><span>${h(String(s.detail || '').split(/ \(|, /)[0])}</span></span></li>`).join('')}</ol>`;
  }
  // a problem the user marked as known: mod + message without its numbers; a changed message shows again
  const issueKey = (mod, text) => (String(mod || '') + '|' + String(text || '').toLowerCase().replace(/\d+/g, '#').replace(/\s+/g, ' ').trim()).slice(0, 300);
  const hiddenIssues = () => new Set(Array.isArray(prefs.hideIssues) ? prefs.hideIssues : []);
  function setIssueHidden(key, on) {
    const s = hiddenIssues();
    if (on) s.add(key); else s.delete(key);
    prefs.hideIssues = [...s].slice(-200); savePrefs();
    renderReportsBody();
    toast(on ? 'Hidden' : 'Shown again', on ? 'It comes back if the message changes. "Show them" at the end of the list brings it back now.' : '', 'ok', 4000);
  }
  function issuesHtml(list) {
    if (!list.length) return '<p class="dim small" style="margin:0">Nothing to fix.</p>';
    const hid = hiddenIssues(), all = S.rep.showHidden;
    const isHid = i => i.kind === 'mod' && hid.has(issueKey((i.mods || [])[0], i.msg || i.detail)), nHid = list.filter(isHid).length;
    // problems get a box with what can be done about them; notes (harmless warnings, all good) stay one quiet line
    const out = list.filter(i => all || !isHid(i)).map(i => {
      const k = { bad: 'bad', warn: 'warn', ok: 'ok', info: 'info' }[i.level] || 'neutral';
      if (k !== 'bad' && k !== 'warn') return `<div class="note-line ${k}">${ic(k === 'ok' ? 'check' : 'info')}<span><b>${h(i.title)}</b>${i.detail ? ` &middot; ${h(i.detail)}` : ''}</span></div>`;
      const links = (i.links || []).filter(l => l && l.mod).map(l => `<div class="issue-link"><button class="mchip sm" data-act="lib-open" data-name="${h(l.mod)}" title="Details and files">${h(l.mod)}</button><span>${h(l.why)}</span></div>`).join('');
      return callout(k, `<b>${h(i.title)}</b>${i.detail ? `<br>${h(i.detail)}` : ''}${links}<div class="issue-acts">${issueActs(i, isHid(i))}</div>`);
    }).join('');
    return out + (nHid ? `<div class="note-line">${ic('eye')}<span>${plural(nHid, 'hidden problem')} &middot; <button class="link-btn small" data-act="rep-hidden">${all ? 'Hide them again' : 'Show them'}</button></span></div>` : '');
  }
  // what can be done about one problem: update, turn off, read the log, see the file, read Nexus, or hide it
  function issueActs(i, hidden) {
    const acts = [], name = i.kind === 'mod' ? (i.mods || [])[0] : '', m = name ? findItem(name) : null;
    if (i.crash) acts.push(`<button class="btn sm" data-act="open-crash" data-id="${h(i.crash)}">Crash details</button>`);
    if (i.level === 'bad' && i.crash) acts.push(`<button class="btn sm ghost" data-act="bisect-open">${ic('bug')}Find the problem mod</button>`);
    if (m) {
      const nx = String(m.source || '').match(/nexus:(\d+)/), up = upOf(m);
      if (up && nx) acts.push(`<button class="btn sm primary" data-act="get" data-mod="${nx[1]}" data-file="${+up.fileId}" data-name="${h(m.name)}" title="Opens the new file on Nexus; click Slow download there">${ic('dl')}Update to v${h(String(up.version).replace(/^v/i, ''))}</button>`);
      // the other mods a message involves can be the one to turn off, so each gets the same choice
      const others = (i.links || []).map(l => l && l.mod && findItem(l.mod)).filter((o, k, a) => o && o.on && !o.fw && o.name !== m.name && a.findIndex(x => x && x.name === o.name) === k);
      const off = o => `<button class="btn sm" data-act="issue-off" data-name="${h(o.name)}" title="Its files are set aside, not deleted. Turn it back on in the Library at any time.">Turn off${others.length ? ' ' + h(short(o.name, 24)) : ''}</button>`;
      if (m.on && !m.fw) acts.push(off(m));
      else if (!m.on) acts.push('<span class="pill muted">Off now</span>');
      acts.push(...others.map(off));
    }
    if (i.log) acts.push(`<button class="btn sm ghost" data-act="open-log" data-path="${h(i.log)}" title="Open ${h(i.log)}">${ic('file')}Open log</button>`);
    if (i.file) acts.push(`<button class="btn sm ghost" data-act="reveal" data-path="${h(i.file)}" title="Show ${h(i.file)} in its folder">${ic('folder')}Show file</button>`);
    if (m && m.modId) acts.push(`<button class="btn sm ghost" data-act="open-url" data-url="${NEXUS}/mods/${+m.modId}?tab=posts" title="What other players report about it">${ic('ext')}Nexus posts</button>`);
    if (m) acts.push(`<button class="btn sm ghost" data-act="lib-open" data-name="${h(m.name)}">${ic('info')}Details</button>`);
    else acts.push(...(i.mods || []).slice(0, 6).map(n => `<button class="mchip sm" data-act="lib-open" data-name="${h(n)}">${h(n)}</button>`));
    if (i.kind === 'mod') acts.push(`<span class="spacer"></span><button class="link-btn small" data-act="issue-hide" data-key="${h(issueKey(name, i.msg || i.detail))}" data-on="${hidden ? '0' : '1'}" title="${hidden ? 'Count it as a problem again' : 'You know about it: hide it until the message changes'}">${hidden ? 'Show again' : 'Hide'}</button>`);
    return acts.join('');
  }
  const FLOW_HELP = {
    start: 'Steam starts Cyberpunk2077.exe. Loader files in bin\\x64 (winmm.dll, version.dll) make Windows load the frameworks with it.',
    red4ext: 'RED4ext loads each .dll in red4ext\\plugins. Plugins hook into the game\'s code, so they must match the game version.',
    cet: 'Cyber Engine Tweaks runs the init.lua of each folder in its mods folder.',
    scripts: 'redscript compiles every .reds file in r6\\scripts into one script blob. A single broken file stops all script mods.',
    tweaks: 'TweakXL applies .yaml edits to the game database (items, stats, vehicles).',
    archives: 'The game reads .archive files from archive\\pc\\mod in alphabetical order; ArchiveXL adds the rules from .xl files.',
    end: 'How the session ended.',
  };
  function flowList(d) {
    const icon = { ok: 'check', warn: 'alert', bad: 'alert', run: 'play' };
    return `<ol class="flow">${(d.stages || []).map((s, i) => `<li class="flow-step ${h(s.status)}"><span class="fs-dot">${s.status === 'skip' ? i + 1 : ic(icon[s.status] || 'info')}</span><div class="fs-txt"><b>${h(s.title)}</b><span>${h(s.detail)}</span>${FLOW_HELP[s.key] ? `<em>${h(FLOW_HELP[s.key])}</em>` : ''}</div></li>`).join('')}</ol>`;
  }
  function launchModsCard(d) {
    const mods = d.mods || [], f = S.rep.mods, hid = hiddenIssues();
    // a mod whose every problem was hidden on this page counts as known, not as one to check
    const stOf = m => (m.status === 'error' || m.status === 'warn') && !(m.notes || []).some(nt => (nt.level === 'error' || nt.level === 'warn') && !hid.has(issueKey(m.name, nt.text))) ? 'known' : m.status;
    const bad = m => ['error', 'warn'].includes(stOf(m));
    const n = { problems: mods.filter(bad).length, new: mods.filter(m => m.status === 'new').length, all: mods.length };
    const list = f === 'all' ? mods : f === 'new' ? mods.filter(m => m.status === 'new') : mods.filter(bad);
    const st = { error: ['bad', 'alert', 'Problem'], warn: ['warn', 'alert', 'Worth a check'], known: ['muted', 'eye', 'You hid its problem on this page'], new: ['info', 'info', 'Not tested yet'], ok: ['ok', 'check', 'Loaded'], assets: ['muted', 'box', 'Assets (the game loads them without logging)'] };
    return `<div class="card"><div class="card-head"><span class="dim small">How each mod did when the game last started</span><div class="seg">${[['problems', 'To check', n.problems], ['new', 'Not tested', n.new], ['all', 'All', n.all]].map(([v, l, c]) => `<button data-act="rep-mods" data-v="${v}" class="${f === v ? 'on' : ''}">${l} <span class="n">${c}</span></button>`).join('')}</div></div>
      <div class="card-body flush">${list.length ? `<div class="list">${list.map(m => {
      const x = st[stOf(m)] || st.assets, notes = m.notes || [], first = notes.find(nt => nt.level === 'error' || nt.level === 'warn') || notes[0];
      return `<div class="li click" data-act="lib-open" data-name="${h(m.name)}" tabindex="0" title="Show this mod"><span class="st-ic ${x[0]}" title="${h(x[2])}">${ic(x[1])}</span><div class="li-main"><div class="li-title"><span class="t">${h(m.name)}</span><span class="kchips">${kindChips(m.kinds, 3)}</span></div>${first ? `<div class="li-sub"><span>${h(first.text)}${first.note ? ' ' + h(first.note) : ''}</span></div>` : ''}</div><span class="li-go">${ic('fwd')}</span></div>`;
    }).join('')}</div>` : `<div class="empty" style="padding:24px 16px">${f === 'problems' ? 'No mod had a problem on the last launch.' : f === 'new' ? 'Every mod was part of the last launch.' : 'No mods.'}</div>`}</div></div>`;
  }
  function crashesCard(d) {
    const list = d.crashes || [], bs = S.st.bisect;
    const trouble = bs && bs.active ? '' : `<div class="trouble-row">${ic('bug')}<span><b>Crashing every time?</b> cpmods can find the mod behind it: it switches suspects off, you launch and answer, and each answer halves the list (30 mods take about 6 launches).</span><button class="btn sm" data-act="bisect-open">Find the problem mod</button></div>`;
    return `<div class="card"><div class="card-head"><span class="dim small">Saved by the game each time it crashes</span><button class="btn sm ghost" data-act="open-loc" data-loc="crashes">${ic('folder')}Open folder</button></div>${trouble}
      <div class="card-body flush">${list.length ? `<div class="list">${list.slice(0, 12).map(c => `<div class="li click${selKey() === 'crash:' + c.id ? ' selected' : ''}" data-act="open-crash" data-id="${h(c.id)}" data-sel="crash:${h(c.id)}" tabindex="0"><span class="st-ic bad">${ic('alert')}</span><div class="li-main"><div class="li-title"><span class="t">${h(fmtWhen(c.time))}</span>${c.same ? `<span class="pill warn" title="Same crash spot as other reports">seen ${c.same + 1} times</span>` : ''}</div><div class="li-sub"><span>${h(c.when)}${c.uptime != null ? ` after ${h(fmtDur(c.uptime))}` : ''}</span>${c.moduleMod ? `<span>inside ${h(c.moduleMod)}</span>` : c.module ? `<span>${h(c.module)}</span>` : ''}</div></div><span class="li-go">${ic('fwd')}</span></div>`).join('')}</div>` : '<div class="empty" style="padding:24px 16px">No crash reports. The game saves one here when it crashes.</div>'}</div></div>`;
  }
  function historyCard(d) {
    const list = d.history || [];
    const st = { clean: ['ok', 'Closed normally'], crash: ['bad', 'Crashed'], running: ['info', 'Running'], ended: ['warn', 'Stopped abruptly'] };
    return `<div class="card"><div class="card-head"><span class="dim small">The last launches, read from the RED4ext logs</span></div><div class="card-body flush">${list.length ? `<div class="list">${list.map(x => {
      const s = st[x.result] || ['muted', x.result];
      return `<div class="li slim${x.crash ? ' click' : ''}"${x.crash ? ` data-act="open-crash" data-id="${h(x.crash)}" tabindex="0"` : ''}><span class="dot ${resultDot(x.result)}"></span><span class="t">${h(fmtWhen(x.start))}</span><span class="dim small">${h(fmtDur(x.seconds))} &middot; ${plural(x.plugins || 0, 'plugin')}</span><span class="spacer"></span><span class="stag s-${s[0]}">${h(s[1])}</span></div>`;
    }).join('')}</div>` : '<div class="empty" style="padding:24px 16px">No launches recorded yet.</div>'}</div></div>`;
  }
  // ---------- game: play, launch options, saves and backups, game folders ----------
  function pageGame(el) {
    const st = S.st, g = st.game, s = st.settings, lt = launchSt(), L = S.launch, left = gameProcs().filter(x => x !== 'Cyberpunk2077');
    const state = g.missing ? ['bad', 'Not found in its folder'] : g.running ? ['run', 'Running'] : left.length ? ['warn', 'Closing'] : g.updatePending ? ['warn', 'Steam has an update pending'] : ['ok', 'Ready to play'];
    const last = lt && lt.start ? `<button class="gm-last" data-act="go" data-page="reports" title="Open the report of that launch"><span class="dot ${resultDot(lt.result)}"></span><span>Last launch ${h(fmtWhen(lt.start))}: ${h(resultWord(lt.result))}</span>${ic('fwd')}</button>` : '<span class="dim small">No launch recorded yet.</span>';
    el.innerHTML = `
      <header class="page-head"><div class="ph-top">
        <div><h1>Game</h1><p class="sub">Play, launch options, saves and backups, and the game folders.</p></div>
        <div class="ph-actions">${killBtn(true)}<button class="btn primary" data-act="play"${g.running || g.missing ? ' disabled' : ''}>${ic('play')}${g.running ? 'Running' : 'Play'}</button><button class="btn icon-only" data-act="play-menu" title="Other ways to launch" aria-label="Other ways to launch">${ic('down')}</button></div>
      </div></header>
      <div class="page-body gm">
        <div class="card gm-hero"><div class="gm-top"><span class="gm-ic ${state[0]}">${ic('game')}</span>
          <div class="gm-txt"><b>Cyberpunk 2077${g.version ? ' ' + h(g.version) : ''}</b><span><span class="dot ${state[0] === 'ok' ? 'ok' : state[0]}"></span>${h(state[1])}${g.build ? ` &middot; build ${h(g.build)}` : ''}</span><span class="mono-path">${h(st.paths.game)}</span></div>
          <div class="gm-acts"><button class="btn sm" data-act="vanilla-start"${g.running || st.vanilla ? ' disabled' : ''} title="Starts the game once with every mod set aside; they come back when it closes">${ic('play')}Play without mods</button><button class="btn sm ghost" data-act="steam" data-what="validate" title="Steam checks the game's own files and repairs damaged ones">${ic('shield')}Verify game files</button><button class="btn sm ghost" data-act="steam" data-what="page">${ic('ext')}Open in Steam</button></div></div>
          <div class="gm-foot">${last}</div></div>
        <div class="gm-grid">
          <section class="card" id="g-launch"><div class="card-head"><h3>${ic('play')} Launch</h3></div><div class="card-body">${launchSettingsHtml(s, L.data && L.data.steam)}</div></section>
          <section class="card" id="g-backups"><div class="card-head"><h3>${ic('history')} Saves and backups</h3></div><div class="card-body">${backupSettingsHtml(s)}</div></section>
        </div>
        <section class="card" id="g-folders"><div class="card-head"><h3>${ic('folder')} Folders</h3><span class="dim small">Each one opens in your file manager</span></div><div class="card-body"><div class="folder-grid">${FOLDERS.map(([k, l, d]) => `<button class="folder-btn" data-act="open-loc" data-loc="${k}" title="Open ${h(l)}">${ic('folder')}<span><b>${h(l)}</b><em>${h(d)}</em></span></button>`).join('')}</div></div></section>
      </div>`;
    if (!L.data && !L.loading && !L.err) loadLaunch(false);
  }
  function backupSettingsHtml(s) {
    return srow('Automatic restore points', 'Before installs, removals and switches (one per batch), and after a launch that closes normally. Going back switches mods off or on and reinstalls older versions from Downloads.', ssw('autoRestore', s.autoRestore !== false, 'Automatic restore points'))
      + srow('Copy saves before changed launches', 'When the mods changed since the last copy, cpmods copies your newest saves before the game starts. Copies only: saves are never moved.', ssw('saveBackup', s.saveBackup !== false, 'Copy saves before changed launches'))
      + srow('Save copies to keep', 'Older copies are deleted from cpmods\' backup folder.', `<select data-setsel="saveKeep" aria-label="Save copies to keep">${opt([3, 5, 10, 20].map(n => [String(n), String(n)]), String(s.saveKeep || 5))}</select>`)
      + `<div class="toolbar sx-foot"><button class="btn sm" data-act="tool" data-tool="backups">${ic('history')}Open backups</button><button class="btn sm ghost" data-act="bk-point">${ic('plus')}Make a restore point now</button><button class="btn sm ghost" data-act="bk-saves-now">${ic('save')}Copy my saves now</button></div>`;
  }
  // the Game page opened at one of its cards (from the play menu, Settings...)
  function openGameAt(k) {
    go('game');
    const el = $('#g-' + k);
    if (el) el.scrollIntoView({ block: 'start' });
  }
  function launchSettingsHtml(s, so) {
    return `<div class="setting"><div class="setting-text"><b>Launch the game</b><span>Through Steam is recommended. Directly starts Cyberpunk2077.exe (Steam still opens in the background).</span></div><select data-setsel="launchMode" aria-label="Launch mode">${opt([['steam', 'Through Steam'], ['direct', 'Directly']], s.launchMode || 'steam')}</select></div>
      <div class="setting"><div class="setting-text"><b>Report when the game closes</b><span>Show a short summary of the launch with a link to the details.</span></div><label class="switch"><input type="checkbox" data-setting="reportOnExit"${s.reportOnExit !== false ? ' checked' : ''}><span></span></label></div>
      <div class="setting"><div class="setting-text"><b>Warn before launching</b><span>Ask first when the compatibility check found a problem that can crash the game.</span></div><label class="switch"><input type="checkbox" data-setting="warnRisk"${s.warnRisk !== false ? ' checked' : ''}><span></span></label></div>
      ${so ? `<div class="setting"><div class="setting-text"><b>Steam launch options</b><span>${so.found && so.value ? `<code>${h(so.value)}</code> is set in Steam (game Properties, General). cpmods only reads it.` : 'None set in Steam. Adding --launcher-skip there skips the CD Projekt launcher.'}</span></div></div>` : ''}`;
  }
  function bisectCard() {
    const bs = S.st.bisect;
    if (!bs || !bs.active) return '';
    const busy = S.st.jobs.some(j => j.kind === 'bisect' && j.status === 'running'), run = S.st.game.running;
    const lt = launchSt(), since = lt && lt.start && toDate(lt.start) > toDate(bs.stepAt);
    const guess = since && !run ? (lt.result === 'crash' || lt.result === 'ended' ? 'problem' : lt.result === 'clean' ? 'ok' : null) : null;
    if (bs.phase === 'done') {
      const msg = bs.outcome === 'found' ? `<b>Found it: ${h(bs.culprit)}.</b> It is off and everything else is back on. Keep it off and look for an update, or tell its author what happens.`
        : bs.outcome === 'notInScope' ? '<b>It is not one of these mods.</b> The problem happened even with all of them off. It may come from a framework, another mod, or the game itself.'
          : '<b>The answers do not point to a single mod.</b> The problem may need two mods together, or it does not happen every time.';
      return `<div class="card bisect"><div class="card-head"><h3>${ic('bug')} Troubleshooting finished</h3></div><div class="card-body">${callout(bs.outcome === 'found' ? 'ok' : 'warn', msg)}
        <div class="toolbar" style="margin-top:12px">${bs.outcome === 'found' ? `<button class="btn primary" data-act="bisect-stop" data-keep="1"${busy ? ' disabled' : ''}>Keep it off and finish</button>` : ''}<button class="btn" data-act="bisect-stop"${busy ? ' disabled' : ''}>Turn everything back on</button>${bs.outcome === 'found' ? `<button class="btn ghost" data-act="lib-open" data-name="${h(bs.culprit)}">Open ${h(bs.culprit)}</button>` : ''}</div>${bisectHistory(bs)}</div></div>`;
    }
    const left = (bs.suspects || []).length, more = Math.ceil(Math.log2(Math.max(1, left))) + (bs.phase === 'verify' ? 1 : 0), off = bs.off || [];
    return `<div class="card bisect"><div class="card-head"><h3>${ic('bug')} Troubleshooting, round ${+bs.round}</h3><span class="dim small">${plural(left, 'mod')} still suspected, about ${more} more launch${more === 1 ? '' : 'es'}</span></div><div class="card-body">
      <ol class="steps"><li><b>Launch the game</b> and do what made the problem happen (load the save, open the menu...).</li><li><b>Close the game</b> or let it crash, then answer below.</li></ol>
      ${bs.phase === 'verify' ? callout('info', `For this first launch all ${plural(left, 'suspected mod')} are off. If the problem still happens, it is not one of them.`) : callout('info', `Right now <b>${plural(off.length, 'suspected mod')}</b> ${off.length === 1 ? 'is' : 'are'} off and <b>${plural((bs.testing || []).length, 'mod')}</b> ${(bs.testing || []).length === 1 ? 'is' : 'are'} being tested.`)}
      ${guess ? callout(guess === 'ok' ? 'ok' : 'warn', `Your launch at ${h(fmtTime(lt.start))} ${guess === 'ok' ? 'closed normally' : lt.result === 'crash' ? 'crashed' : 'stopped without closing normally'}.`) : ''}
      ${(bs.errors || []).length ? callout('bad', 'Some mods could not be switched: ' + h(bs.errors.join('; '))) : ''}
      <div class="toolbar" style="margin-top:12px"><button class="btn" data-act="play"${run || busy ? ' disabled' : ''}>${ic('play')}Play</button><span class="spacer"></span>
        <button class="btn${guess === 'ok' ? ' primary' : ''}" data-act="bisect-result" data-ok="1"${busy || run ? ' disabled' : ''}>${ic('check')}It worked</button>
        <button class="btn${guess === 'problem' ? ' primary' : ' danger'}" data-act="bisect-result" data-ok="0"${busy || run ? ' disabled' : ''}>${ic('alert')}The problem happened</button></div>
      ${busy ? '<div class="helper"><span class="spin"></span> Switching mods; progress shows in the bar at the bottom.</div>' : ''}
      <details class="old" style="margin-top:12px"><summary>Mods off right now (${off.length})</summary><div class="mchips" style="margin-top:8px">${off.map(n => `<span class="mchip static">${h(n)}</span>`).join('')}</div></details>
      ${bisectHistory(bs)}
      <div class="toolbar" style="margin-top:10px"><button class="btn sm ghost" data-act="bisect-stop"${busy ? ' disabled' : ''}>Stop and turn everything back on</button></div></div></div>`;
  }
  function bisectHistory(bs) {
    const hist = bs.history || [];
    if (!hist.length) return '';
    return `<div class="sub-label" style="margin-top:16px">Answers so far</div><div class="card"><div class="list">${hist.map(x => `<div class="li"><span class="pill ${x.result === 'ok' ? 'ok' : 'bad'}">${x.result === 'ok' ? 'Worked' : 'Problem'}</span><div class="li-main"><div class="li-sub"><span>Round ${+x.round}: ${x.phase === 'verify' ? 'all suspects off' : `${plural((x.on || []).length, 'mod')} back on, ${plural((x.off || []).length, 'mod')} off`}</span><span>${h(fmtTime(x.at))}</span></div></div></div>`).join('')}</div></div>`;
  }

  // ---------- performance card: settings with memory estimates, live numbers from the server ----------
  const fmtMb = mb => mb >= 10 ? Math.round(mb) + ' MB' : (Math.round(mb * 10) / 10) + ' MB';
  function perfNowHtml() {
    const m = S.perfNow, st = IMG.stats(), mb = b => fmtMb(b / 1048576);
    if (!m) return '<span class="spin"></span><span>Measuring...</span>';
    if (m.error) return `<span class="err">${h(m.error)}</span>`;
    // "in use" = Task Manager's Memory column; "reserved" = committed memory Windows can page out
    const one = (name, x) => x ? `<span>${name} <b>${mb(x.ram || x.private)}</b> <span class="dim">in use, ${mb(x.private)} reserved</span></span>` : `<span>${name} <b>?</b> <span class="dim">(measured in the built-in window only)</span></span>`;
    return one('Window', m.window) + one('Server', m.server) + `<span>Pictures <b>${st.n}</b> <span class="dim">loaded</span></span>${m.lean ? '<span class="pill ok">Light mode on</span>' : ''}`;
  }
  async function loadPerfNow() {
    try { S.perfNow = await api('/api/perf'); } catch (e) { S.perfNow = { error: e.message }; }
    const el = $('#perf-now');
    if (el) el.innerHTML = perfNowHtml();
  }
  // Logitech onboard profile while playing: the server switches when the game starts and puts the previous one back after
  function mouseHtml() {
    const P = perf(), m = S.mouse, found = m && m.found ? m.profiles : null;
    const list = [[0, 'Off']].concat((found || [1, 2, 3, 4, 5].map(n => ({ n, on: true }))).map(p => [p.n, `Profile ${p.n}${p.hz ? ` · ${p.hz} Hz` : ''}${p.on ? '' : ' (off on the mouse)'}`]));
    if (P.mouse && !list.some(x => x[0] === P.mouse)) list.push([P.mouse, `Profile ${P.mouse} (not on this mouse)`]);
    const cur = found && found.find(p => p.n === m.current);
    const now = !m ? '<span class="spin"></span><span>Looking for the mouse...</span>'
      : m.error ? `<span class="dim">${h(m.error)}</span>`
        : !m.found ? '<span class="dim">No Logitech mouse with onboard profiles answered. Wired or wireless both work; a sleeping mouse wakes when moved.</span>'
          : `<span>${h(m.name || 'Logitech mouse')}: <b>profile ${m.current}</b> <span class="dim">active${cur && cur.hz ? `, ${cur.hz} Hz` : ''}</span></span>${m.onboard ? '' : '<span class="pill warn">Software mode: G HUB controls it</span>'}`;
    return `<div class="setting"><div class="setting-text"><b>Mouse profile while playing</b><span>Logitech mice with onboard profiles (Onboard Memory Manager or G HUB). Use one with a lower polling rate if 8000 Hz drops your fps. The profile that was active comes back when the game closes.</span></div><select data-perf="mouse" aria-label="Mouse profile while playing">${opt(list, P.mouse)}</select></div>
      <div class="perf-now">${now}<button class="link-btn small" data-act="mouse-refresh">Check again</button></div>`;
  }
  // a redraw while a lookup runs must not start another (a mouse that is off takes about 4 s to rule out)
  let mouseBusy = false;
  async function loadMouse() {
    mouseBusy = true;
    try { S.mouse = await api('/api/mouse'); } catch (e) { S.mouse = { error: e.message }; } finally { mouseBusy = false; }
    const el = $('#mouse-set');
    if (el) el.innerHTML = mouseHtml();
  }
  // compact rows; the measured memory numbers behind each choice show on request
  function perfHtml() {
    const P = perf(), info = prefs.perfInfo === true, gal = n => n ? PIC_MB.full + (n - 1) * PIC_MB.small : 0;
    const sel = (key, label, list) => `<select data-perf="${key}" aria-label="${h(label)}">${opt(list, P[key])}</select>`;
    const sw = (key, label) => `<label class="switch"><input type="checkbox" data-perf="${key}"${P[key] ? ' checked' : ''} aria-label="${h(label)}"><span></span></label>`;
    const row = (title, text, est, ctl) => `<div class="setting"><div class="setting-text"><b>${title}</b><span>${text}</span>${info && est ? `<em class="perf-est">${est}</em>` : ''}</div>${ctl}</div>`;
    return `<div class="sub-label">Memory</div><div class="perf-now" id="perf-now">${perfNowHtml()}</div>
      <div class="toolbar perf-tools"><button class="btn sm" data-act="perf-free">Free memory now</button><button class="btn sm ghost" data-act="perf-refresh">Measure again</button><span class="spacer"></span><button class="link-btn small" data-act="perf-info" aria-pressed="${info}">${info ? 'Hide memory numbers' : 'Show memory numbers'}</button></div>
      <div class="sub-label">Disk space</div><div id="disk-now">${diskHtml()}</div>
      <div class="sub-label">While the game runs</div>
      ${row('Lighter while the game runs', 'Reports page only, no pictures, slower refresh, lower priority.', 'Measured: window 167 to 43 MB, server 110 to 26 MB (Task Manager). Minimizing cpmods frees memory the same way.', sw('lean', 'Lighter while the game runs'))}
      <div id="mouse-set">${mouseHtml()}</div>
      <div class="sub-label">Pictures</div>
      <div class="set-grid">
      ${row('Tile pictures', 'On Discover and Collections.', `About 20 on screen: large ${fmtMb(20 * PIC_MB.large)}, small ${fmtMb(20 * PIC_MB.small)}.`, sel('pics', 'Tile pictures', [['large', 'Large'], ['small', 'Small'], ['off', 'Off']]))}
      ${row('Kept loaded', 'Far-off pictures unload above this.', 'Matters for big description pictures (2 to 8 MB each).', sel('maxPics', 'Pictures kept loaded', [[24, '24'], [48, '48'], [96, '96'], [160, '160'], [0, 'No limit']]))}
      ${row('Mod gallery', 'Pictures in a mod\'s details.', `One open mod: about ${fmtMb(gal(P.galMax))}.`, sel('galMax', 'Mod gallery pictures', [[0, 'Off'], [4, '4'], [8, '8'], [12, '12'], [20, '20'], [40, '40']]))}
      ${row('Video previews', 'YouTube pictures in the gallery.', `About ${fmtMb(PIC_MB.ytSmall)} each, ${fmtMb(PIC_MB.yt)} shown big.`, sel('vidMax', 'Video previews', [[0, 'Off'], [1, '1'], [2, '2'], [4, '4'], [8, '8']]))}
      ${row('In descriptions', 'Off shows a "Show picture" link.', 'Full size, usually 2 to 8 MB each.', sw('descPics', 'Pictures in descriptions'))}
      </div>
      <div class="sub-label">Window</div>
      <div class="set-grid">
      ${row('Effects', 'Blurred backdrops, loading animations.', 'Off saves a little graphics and CPU work.', sw('fx', 'Effects'))}
      ${row('App window', 'Built-in (part of Windows) or your browser. Next start.', '', sel('window', 'App window', [['app', 'Built-in'], ['browser', 'My browser']]))}
      ${row('Graphics card', 'Off draws the window with the CPU. Next start.', GPU_NOTE, sw('gpu', 'Use the graphics card for the window'))}
      </div>`;
  }
  const GPU_NOTE = 'Measured off: 28 MB less in use, 150 MB less reserved, no graphics memory; scrolling uses a bit more CPU.';
  // disk space: mods in the game folder, cpmods' own data, free space, and what a cleanup can delete safely
  function diskHtml() {
    const d = S.disk;
    if (!d) return '<div class="perf-now"><span class="spin"></span><span>Measuring...</span></div>';
    if (d.error) return `<div class="err">${h(d.error)}</div>`;
    const x = d.data, parts = [['Downloads', x.downloads, 'Archives kept so mods can be turned off and on, updated back or reinstalled'], ['Save copies', x.saves, `${plural(d.saveCopies, 'copy', 'copies')} of your saves`], ['App data', x.app, 'Window cache, settings, logs'],
      ['Replaced game files', x.backup, 'Originals of game files that mods replaced; they go back when you remove the mod'], ['Mod settings backups', x.settings, ''], ['Mods set aside', x.parked, 'Files of turned-off mods that were installed before cpmods'], ['Temporary files', x.tmp, 'Left by interrupted installs']].filter(p => p[1].bytes > 0);
    const total = parts.reduce((s, p) => s + p[1].bytes, 0), top = Math.max(1, ...parts.map(p => p[1].bytes));
    const bar = (b, max) => `<span class="du-bar"><i style="width:${Math.max(1.5, b / max * 100).toFixed(1)}%"></i></span>`;
    const sp = d.spare, free = sp.free.length + (x.tmp.bytes ? 1 : 0);
    const drives = (d.drives || []).map(v => `<span>${h(v.name)} <b>${fmtSize(v.free)}</b> <span class="dim">free of ${fmtSize(v.total)}${v.game && v.cpmods ? ' (game and cpmods)' : v.game ? ' (game)' : ' (cpmods)'}</span></span>`).join('');
    return `<div class="du">
        <div class="du-head"><span><b>${fmtSize(d.mods.bytes)}</b> in the game folder for ${plural(d.mods.count, 'mod')}</span><span class="dim small">Largest: ${d.mods.top.filter(m => m.bytes).map(m => `${h(m.name)} ${fmtSize(m.bytes)}`).join(', ') || 'none'}</span></div>
        <div class="du-head"><span><b>${fmtSize(total)}</b> used by cpmods itself</span></div>
        <div class="du-list">${parts.map(([l, u, t]) => `<div class="du-row"${t ? ` title="${h(t)}"` : ''}><span class="du-l">${h(l)}</span>${bar(u.bytes, top)}<span class="du-n">${fmtSize(u.bytes)}</span></div>`).join('')}</div>
        <div class="perf-now du-drives">${drives}</div>
        <div class="du-clean">${free || sp.old.length ? `<span>${sp.free.length ? `<b>${plural(sp.free.length, 'download')}</b> (${fmtSize(sp.freeBytes)}) no mod uses any more.` : 'Every download is used by a mod.'}${sp.old.length ? ` ${plural(sp.old.length, 'older version')} (${fmtSize(sp.oldBytes)}) kept for going back.` : ''}</span><button class="btn sm" data-act="disk-clean">Free space...</button>` : '<span class="dim small">Nothing to clean up: every download belongs to a mod.</span>'}<button class="btn sm ghost" data-act="disk-refresh">Measure again</button></div>
      </div>`;
  }
  let diskBusy = false;
  async function loadDisk() {
    diskBusy = true;
    try { S.disk = await api('/api/storage'); } catch (e) { S.disk = { error: e.message }; } finally { diskBusy = false; }
    const el = $('#disk-now');
    if (el) el.innerHTML = diskHtml();
  }
  async function diskClean() {
    const sp = S.disk && S.disk.spare;
    if (!sp) return;
    const list = sp.free.slice(0, 8).map(f => `<li>${h(f.file)} <span class="dim">${fmtSize(f.size)}</span></li>`).join('') + (sp.free.length > 8 ? `<li class="dim">and ${sp.free.length - 8} more</li>` : '');
    const body = `${sp.free.length ? `These downloads are not used by any mod (installed, off or waiting) or restore point:<ul class="ask-list">${list}</ul>` : 'No download is unused right now.'}
      ${sp.old.length ? `<label class="check-row"><input type="checkbox" class="check" data-pick="old"> <span>Also delete ${plural(sp.old.length, 'older version')} (${fmtSize(sp.oldBytes)}) kept for going back (by restore points, or as a mod's previous download). Going back can then not bring those versions back.</span></label>` : ''}
      <p class="dim small">Temporary files left by interrupted installs go too. Mods, saves and backups are not touched.</p>`;
    const r = await choose({ title: 'Free disk space?', body, options: [{ v: 'go', label: 'Delete', kind: 'danger' }] });
    if (!r) return;
    try { await api('/api/storage', { op: 'clean', old: r.picked.includes('old') }); toast('Freeing disk space', 'Progress shows in the bar at the bottom.', '', 3000); }
    catch (e) { toast('Could not clean up', e.message, 'bad', 8000); }
  }

  // ---------- settings: one collapsible section per topic; the closed header still shows the current values ----------
  const SECTIONS = [
    { k: 'downloads', t: 'Downloads and installs', i: 'downloads' },
    { k: 'look', t: 'Appearance', i: 'palette' },
    { k: 'perf', t: 'Performance and disk space', i: 'gauge' },
    { k: 'nexus', t: 'Nexus account', i: 'key2' },
    { k: 'patch', t: 'Patch compatibility', i: 'refresh' },
    { k: 'share', t: 'Share with friends', i: 'share' },
    { k: 'app', t: 'App', i: 'gear' },
  ];
  const setOpen = () => new Set(Array.isArray(prefs.setOpen) ? prefs.setOpen : ['downloads']);
  const srow = (title, text, ctl) => `<div class="setting"><div class="setting-text"><b>${title}</b><span>${text}</span></div>${ctl}</div>`;
  const ssw = (key, on, label) => `<label class="switch"><input type="checkbox" data-setting="${key}"${on ? ' checked' : ''} aria-label="${h(label)}"><span></span></label>`;
  function sectionSummary(k) {
    const st = S.st, s = st.settings, P = perf(), th = THEMES.find(x => x.id === themeId()), bg = BGS.find(x => x.id === bgId());
    const parts = {
      downloads: [s.autoInstall ? 'Installs when downloaded' : 'Installs when you choose', s.askOverwrite !== false ? 'asks when two mods share a file' : 'last installed mod wins shared files', s.browser ? 'links in ' + browserName() : 'links in your default browser'],
      look: [th.name, bg.id === 'match' ? 'matching background' : bg.name.toLowerCase() + ' background', P.fx ? 'effects on' : 'effects off'],
      perf: [P.lean ? 'Lighter while playing' : 'Same while playing', P.mouse ? `mouse profile ${P.mouse} in game` : '', `${P.pics} tile pictures`, P.window === 'browser' ? 'browser window' : 'built-in window', S.disk && S.disk.mods ? fmtSize(S.disk.mods.bytes) + ' of mods' : ''],
      nexus: [st.key ? 'API key set' : 'API key missing', st.handler ? 'download links work' : 'download links not set up'],
      patch: [`"Updated for ${s.patchLabel}" means updated since ${fmtDate(s.patchDate)}`],
      share: ['App zip, your mod list, your mod settings'],
      app: [prefs.sideMin ? 'compact sidebar' : '', prefs.explain === true ? 'folders explained' : ''],
    }[k] || [];
    return parts.filter(Boolean).join(' · ');
  }
  function sectionBody(k) {
    const st = S.st, s = st.settings;
    if (k === 'downloads') return srow('Install automatically', 'Install each file as soon as it finishes downloading.', ssw('autoInstall', s.autoInstall, 'Install automatically'))
      + srow('Ask when two mods have the same file', 'On: you choose (combine both, use the new copy, or keep the old one). Off: no question. Both mods install, the one installed last is used, and the other\'s copy is kept underneath: it comes back if you remove the newer mod.', ssw('askOverwrite', s.askOverwrite !== false, 'Ask when two mods have the same file'))
      + srow('Delete older downloads after updates', 'When a mod updates, its two previous downloads stay so you can go back; older ones are deleted. A restore point that needs a deleted version can no longer bring it back.', ssw('pruneOld', s.pruneOld !== false, 'Delete older downloads after updates'))
      + srow('Continue the queue', 'Open the next queued download page by itself.', ssw('autoNext', s.autoNext, 'Continue the queue'))
      + srow('Open links in', 'Pages open in this browser and come to the front.', `<select id="s-browser" aria-label="Open links in">${opt([['', 'Windows default']].concat((st.browsers || []).map(b => [b.path, b.name])), s.browser || '')}</select>`);
    if (k === 'look') return appearanceHtml();
    if (k === 'perf') return perfHtml();
    if (k === 'nexus') return srow('API key', st.key ? 'Stored encrypted for your Windows account.' : 'Downloads need it. A free Nexus account is enough.', `<span class="pill ${st.key ? 'ok' : 'warn'}">${st.key ? 'Set' : 'Missing'}</span>`)
      + `<div class="keyrow"><input type="password" id="s-key" autocomplete="off" spellcheck="false" placeholder="${st.key ? 'Paste a new key to replace it' : 'Paste your Personal API Key'}" aria-label="Nexus API key"><button class="btn sm primary" data-act="key-save">Save</button><button class="btn sm ghost" data-act="open-url" data-url="https://next.nexusmods.com/settings/api-keys" title="Opens the Nexus page with your key">${ic('ext')}Get my key</button></div>`
      + srow('Download links', '"Slow download" on Nexus hands the file to cpmods.', st.handler ? '<span class="pill ok">Working</span>' : '<button class="btn sm primary" data-act="sys" data-op="register">Fix</button>');
    if (k === 'patch') return `<p class="dim small" style="margin:0 0 12px">Mods updated on or after this date count as "Updated for ${h(s.patchLabel)}". When a new game patch comes out, enter its name and release date.</p>
      <div class="toolbar"><input type="text" id="s-label" value="${h(s.patchLabel)}" style="width:110px" aria-label="Patch"><input type="date" id="s-date" value="${h(s.patchDate)}" aria-label="Release date"><button class="btn primary" data-act="settings-save">Save</button></div>`;
    if (k === 'share') return `<p class="dim small" style="margin:0 0 12px">Creates a zip on your desktop with the app and an Install.cmd. No API key or downloads are included. Mods your friend already has are left alone.</p>
      <label class="check-row"><input type="checkbox" class="check" id="s-share-set"${S.shareSettings ? ' checked' : ''}> Include my mod settings (CET mods, Mod Settings, hotkeys). Your friend restores them in Backups, Mod settings.</label>
      <div class="toolbar" style="margin-top:12px"><button class="btn primary" data-act="package" data-apponly="1">App only</button><button class="btn" data-act="package">App + my mod list</button><button class="btn ghost" data-act="modlist-export">Save mod list file</button></div>`;
    return srow('Only show missing requirements', 'In a mod\'s details, hide requirements you already have. A "Show" link there brings them back.', `<label class="switch"><input type="checkbox" data-pref="reqMissingOnly"${prefs.reqMissingOnly ? ' checked' : ''} aria-label="Only show missing requirements"><span></span></label>`)
      + srow('Explain game folders', 'In file trees and the folder map, describe what each folder holds.', `<label class="switch"><input type="checkbox" data-pref="explain"${prefs.explain === true ? ' checked' : ''} aria-label="Explain game folders"><span></span></label>`)
      + srow('Compact sidebar', 'Show only icons on the left (Ctrl+B).', `<label class="switch"><input type="checkbox" data-pref="sideMin"${prefs.sideMin ? ' checked' : ''} aria-label="Compact sidebar"><span></span></label>`)
      + srow('Activity log', 'What cpmods did, newest last.', '<button class="btn sm" data-act="tool" data-tool="log">Show log</button>')
      + srow('Quit cpmods', 'Running downloads finish first.', '<button class="btn sm danger" data-act="sys" data-op="quit">Quit</button>');
  }
  function pageSettings(el) {
    const open = setOpen(), all = SECTIONS.every(x => open.has(x.k));
    el.innerHTML = `
      <header class="page-head"><div class="ph-top"><div><h1>Settings</h1><p class="sub">Changes save as soon as you make them. Click a section to open it.</p></div>
        <div class="ph-actions"><button class="btn sm ghost" data-act="sx-all">${all ? 'Collapse all' : 'Expand all'}</button></div></div></header>
      <div class="page-body"><div class="sx-list"><div class="sx-note">${ic('game')}<span>Launch options, saves and backups, and the game folders are on the <button class="link-btn" data-act="go" data-page="game">Game page</button>.</span></div>${SECTIONS.map(x => {
      const on = open.has(x.k);
      return `<section class="sx${on ? ' open' : ''}" id="sx-${x.k}"><button class="sx-head" data-act="sx" data-k="${x.k}" aria-expanded="${on}" aria-controls="sxb-${x.k}"><span class="sx-ic">${ic(x.i)}</span><span class="sx-t"><b>${h(x.t)}</b><span>${h(sectionSummary(x.k))}</span></span><span class="sx-chev">${ic('down')}</span></button>
        <div class="sx-body" id="sxb-${x.k}"${on ? '' : ' hidden'}>${on ? sectionBody(x.k) : ''}</div></section>`;
    }).join('')}</div></div>`;
    // live memory numbers only while their section is open (one WMI query each time); disk space once per opening
    if (open.has('perf')) { loadPerfNow(); if (!S.disk && !diskBusy) loadDisk(); if (!S.mouse && !mouseBusy) loadMouse(); }
  }
  function toggleSection(k, force) {
    const open = setOpen(), on = force != null ? force : !open.has(k);
    if (on) open.add(k); else open.delete(k);
    // disk space is measured again each time its section opens
    if (on && k === 'perf') { S.disk = null; S.mouse = null; }
    prefs.setOpen = [...open]; savePrefs();
    if (S.page === 'settings') pageSettings($('#page'));
  }
  // settings opened at one section (from Backups, the play menu...)
  function openSettings(k) {
    toggleSection(k, true);
    go('settings');
    const el = $('#sx-' + k);
    if (el) el.scrollIntoView({ block: 'start' });
  }

  // ---------- pane ----------
  // mode: 'push' (new history entry, default), 'replace' (rewrite the current one), 'restore' (no history change)
  function openPane(p, mode) {
    closeMenu(); closeLightbox();
    const same = S.pane && routeOf(S.page, S.pane) === routeOf(S.page, p);
    if (mode !== 'restore') saveScroll();
    S.pane = p; S.paneMin = false;
    renderPane(true); markSelection();
    if (mode === 'restore') return;
    setEntry(!(mode === 'replace' || same));
  }
  function closePane() {
    if (!S.pane) return;
    closeMenu(); closeLightbox();
    // closing right after opening from the list is the same as going back: keeps forward available
    const prev = H.entries[H.idx - 1];
    if (prev && prev.page === S.page && !prev.pane) { history.back(); return; }
    saveScroll();
    S.pane = null; S.paneMin = false;
    renderPane(); markSelection();
    setEntry(true);
  }
  const canPaneBack = () => { const prev = H.entries[H.idx - 1]; return !!(prev && prev.pane && prev.page === S.page && prev.pane !== S.pane); };
  function paneTitle(p) {
    if (p.kind === 'mod') return p.data ? decode(p.data.mod.name) : 'Mod';
    if (p.kind === 'col') return p.data ? decode(p.data.name) : 'Collection';
    return { profiles: 'Profiles', discover: 'Find existing mods', gamelog: 'Game logs', log: 'Activity log', files: p.name || 'Files', crash: 'Crash report', preview: p.file || 'Archive', bisect: 'Find the problem mod', backups: 'Backups', keys: 'Key bindings', packs: 'Modpacks' }[p.kind] || 'Details';
  }
  function renderPane(reset) {
    const box = $('#paneBox'), el = $('#pane'), strip = $('#paneStrip');
    if (!S.pane) { box.hidden = true; el.innerHTML = ''; strip.hidden = true; strip.innerHTML = ''; box.classList.remove('min', 'overlay'); $('#scrim').hidden = true; return; }
    box.hidden = false;
    const top = el.scrollTop;
    el.innerHTML = paneHtml(S.pane);
    if (!S.paneMin) el.scrollTop = reset ? 0 : top;
    strip.hidden = !S.paneMin;
    strip.innerHTML = S.paneMin ? `<button class="icon-btn" data-act="pane-expand" title="Show the panel" aria-label="Show the panel">${ic('expand')}</button><div class="vt" data-act="pane-expand" title="Show the panel">${h(paneTitle(S.pane))}</div><button class="icon-btn" data-act="pane-close" title="Close (Esc)" aria-label="Close">${ic('x')}</button>` : '';
    layoutPane();
  }
  // docked beside the list when both fit, otherwise floats over it
  function paneDefaultW() { return Math.round(Math.min(640, Math.max(400, window.innerWidth * 0.4))); }
  function layoutPane() {
    const box = $('#paneBox'), scrim = $('#scrim');
    if (!S.pane) { scrim.hidden = true; return; }
    const total = $('.workspace').clientWidth, w = Math.max(PANE_MIN_W, prefs.paneW || paneDefaultW());
    const overlay = !S.paneMin && total - w < LIST_MIN_W;
    box.classList.toggle('overlay', overlay);
    box.classList.toggle('min', !!S.paneMin);
    box.style.setProperty('--pane-w', (overlay ? Math.min(w, window.innerWidth - 40) : w) + 'px');
    scrim.hidden = !overlay;
  }
  function setPaneMin(min) {
    if (!S.pane || S.paneMin === min) return;
    if (min) { S.paneMinScroll = $('#pane').scrollTop; S.paneMin = true; renderPane(); }
    else { S.paneMin = false; renderPane(); restoreScroll($('#pane'), S.paneMinScroll || 0); }
  }
  function markSelection() {
    const k = selKey();
    document.querySelectorAll('[data-sel]').forEach(n => n.classList.toggle('selected', n.dataset.sel === k));
  }
  function paneHead(title, extra) {
    return `<div class="pane-head">${canPaneBack() ? `<button class="icon-btn" data-act="pane-back" title="Back (Alt+Left)" aria-label="Back">${ic('back')}</button>` : ''}<div class="pane-title">${h(title)}</div>${extra || ''}<button class="icon-btn" data-act="pane-min" title="Minimize the panel" aria-label="Minimize the panel">${ic('collapse')}</button><button class="icon-btn" data-act="pane-close" title="Close (Esc)" aria-label="Close">${ic('x')}</button></div>`;
  }
  const paneLoading = title => paneHead(title) + '<div class="sk" style="aspect-ratio:2/1;border-radius:0"></div><div class="pane-body"><div class="sk sk-line" style="width:70%;height:22px"></div><div class="sk sk-line" style="width:45%"></div><div class="sk" style="height:90px;margin-top:18px"></div><div class="sk" style="height:120px;margin-top:14px"></div></div>';
  function paneHtml(p) {
    if (p.kind === 'mod') return p.data ? modPane(p) : p.error ? paneHead('Mod') + `<div class="pane-body"><div class="err">${h(p.error)}</div></div>` : paneLoading('Loading mod');
    if (p.kind === 'col') return p.data ? colPane(p) : p.error ? paneHead('Collection') + `<div class="pane-body"><div class="err">${h(p.error)}</div></div>` : paneLoading('Loading collection');
    if (p.kind === 'discover') return discoverPane(p);
    if (p.kind === 'log') return logPane(p);
    if (p.kind === 'gamelog') return gameLogPane(p);
    if (p.kind === 'files') return filesPane(p);
    if (p.kind === 'crash') return crashPane(p);
    if (p.kind === 'preview') return previewPane(p);
    if (p.kind === 'bisect') return bisectPane(p);
    if (p.kind === 'backups') return backupsPane(p);
    if (p.kind === 'profiles') return profilesPane(p);
    if (p.kind === 'keys') return keysPane(p);
    if (p.kind === 'packs') return packsPane(p);
    return '';
  }

  // mod details
  async function openMod(id, mode) {
    id = +id;
    if (!id) return;
    if (S.pane && S.pane.kind === 'mod' && S.pane.id === id && S.pane.data && mode !== 'restore') { setPaneMin(false); return; }
    const p = { kind: 'mod', id, data: null, inspect: {}, showOld: false, filesOpen: null, descOpen: false, gal: null };
    openPane(p, mode);
    try {
      const d = await gql(`{ legacyModsByDomain(ids: [{gameDomain: "${GAME}", modId: ${id}}]) { nodes { ${MOD_FIELDS} ${REQ_FIELDS} pictureUrl description } } modFiles(modId: ${id}, gameId: 3333) { fileId name version category date sizeInBytes description } }`);
      const m = d.legacyModsByDomain && d.legacyModsByDomain.nodes && d.legacyModsByDomain.nodes[0];
      if (!m) throw new Error('Mod not found. It may be hidden, removed or adult-only.');
      p.data = { mod: m, files: d.modFiles || [] };
      p.gal = { list: galleryOf(m), i: 0, skip: new Set() };
    } catch (e) { p.error = e.message; }
    if (S.pane === p) renderPane();
  }

  // pictures: the Nexus main image, then images and videos from the description
  function galleryOf(m) {
    const list = [], seen = new Set();
    const add = x => { const k = x.kind === 'yt' ? 'yt:' + x.id : x.u; if (!x.u || seen.has(k) || list.length >= 40) return; seen.add(k); list.push(x); };
    if (m.pictureUrl) add({ u: m.pictureUrl, kind: 'img', keep: true });
    const d = decode(String(m.description || '').replace(/<br\s*\/?>/gi, '\n'));
    for (const x of d.matchAll(/\[img(?:=[^\]]*)?\]\s*(https?:\/\/[^\s\[\]"<>]+?)\s*\[\/img\]/gi)) add({ u: x[1], kind: 'img' });
    for (const x of d.matchAll(/(?:\[youtube\]\s*|youtube\.com\/watch\?(?:[^\s\[\]"]*&)?v=|youtu\.be\/|youtube\.com\/embed\/)([\w-]{11})/gi)) add({ u: `https://i.ytimg.com/vi/${x[1]}/hqdefault.jpg`, kind: 'yt', id: x[1] });
    return list;
  }
  const badImgs = new Set();
  const cssUrl = u => String(u).replace(/["'()\\\s]/g, c => '%' + c.charCodeAt(0).toString(16).padStart(2, '0'));
  // shown pictures and videos, capped by the Performance limits
  function galVisible(p) {
    const g = p.gal, P = perf();
    if (!g) return [];
    let pics = 0, vids = 0;
    return g.list.map((x, k) => k).filter(k => {
      const x = g.list[k];
      if (g.skip.has(x.u)) return false;
      return x.kind === 'yt' ? vids++ < P.vidMax : pics++ < P.galMax;
    });
  }
  // small copies for the strip: Nexus keeps a 385 px thumbnail of every picture, YouTube a 320 px one
  const thumbOf = x => x.kind === 'yt' ? String(x.u).replace('/hqdefault.', '/mqdefault.') : String(x.u).replace(/^(https?:\/\/staticdelivery\.nexusmods\.com\/mods\/\d+\/images\/)(\d+\/)/i, '$1thumbnails/$2');
  function galCur(p) { const vis = galVisible(p); return !vis.length ? -1 : vis.includes(p.gal.i) ? p.gal.i : vis[0]; }
  function galleryHtml(p) {
    const g = p.gal, vis = g ? galVisible(p) : [];
    if (!vis.length) return '';
    if (IMG.paused) return '<div class="gal-off">Pictures are paused while the game runs.</div>';
    const i = galCur(p), x = g.list[i], pos = vis.indexOf(i), img = `${perf().fx ? `<div class="gal-bg" style="background-image:url('${h(cssUrl(x.u))}')"></div>` : ''}<img class="gimg" data-u="${h(x.u)}" ${IMG.attr(x.u)} referrerpolicy="no-referrer" alt="">`;
    const main = x.kind === 'yt'
      ? `<a class="gal-main" href="https://www.youtube.com/watch?v=${h(x.id)}" title="Watch on YouTube">${img}<span class="gal-play">${ic('play')}</span></a>`
      : `<div class="gal-main" data-act="gal-zoom" title="Click to enlarge">${img}</div>`;
    const nav = vis.length > 1 ? `<button class="gal-nav prev" data-act="gal-step" data-v="-1" aria-label="Previous picture">${ic('back')}</button><button class="gal-nav next" data-act="gal-step" data-v="1" aria-label="Next picture">${ic('fwd')}</button>` : '';
    const strip = vis.length > 1 ? `<div class="gal-strip">${vis.map(k => { const y = g.list[k]; return `<button class="gal-thumb${k === i ? ' on' : ''}" data-act="gal-pick" data-v="${k}" aria-label="${y.kind === 'yt' ? 'Video' : 'Picture'} ${vis.indexOf(k) + 1}"><img class="gthumb" data-u="${h(y.u)}" ${IMG.attr(thumbOf(y))} referrerpolicy="no-referrer" alt="">${y.kind === 'yt' ? `<span class="vid">${ic('play')}</span>` : ''}</button>`; }).join('')}</div>` : '';
    return `<div class="gal" id="gal"><div class="gal-stage">${main}${nav}<span class="gal-count">${x.kind === 'yt' ? 'Video &middot; ' : ''}${pos + 1} / ${vis.length}</span></div>${strip}</div>`;
  }
  function galRefresh() {
    const p = S.pane, el = $('#gal');
    if (!p || !p.gal || !el) return;
    const strip = el.querySelector('.gal-strip'), left = strip ? strip.scrollLeft : 0;
    const tmp = document.createElement('div');
    tmp.innerHTML = galleryHtml(p);
    const nu = tmp.firstElementChild;
    if (!nu) { el.remove(); return; }
    el.replaceWith(nu);
    const s2 = nu.querySelector('.gal-strip'), on = s2 && s2.querySelector('.on');
    if (s2) s2.scrollLeft = left;
    if (on) { const x = on.offsetLeft - s2.scrollLeft; if (x < 0 || x + on.offsetWidth > s2.clientWidth) s2.scrollLeft = on.offsetLeft - (s2.clientWidth - on.offsetWidth) / 2; }
  }
  function galStep(d) {
    const p = S.pane;
    if (!p || !p.gal) return;
    const vis = galVisible(p), pos = vis.indexOf(galCur(p));
    if (vis.length < 2) return;
    p.gal.i = vis[(pos + d + vis.length) % vis.length];
    galRefresh();
  }
  // badges, buttons and banner headings from descriptions are not screenshots
  function galCheck(img) {
    const p = S.pane;
    if (!p || !p.gal) return;
    if (img.getAttribute('src') !== img.dataset.src) return;
    const x = p.gal.list.find(y => y.u === img.dataset.u);
    if (!x || x.keep) return;
    const w = img.naturalWidth, ht = img.naturalHeight;
    if (w && ht && (w < 240 || ht < 135 || w / ht > 3 || ht / w > 2.2)) galDrop(x.u);
  }
  function galDrop(u) {
    const p = S.pane;
    if (!p || !p.gal || p.gal.skip.has(u)) return;
    p.gal.skip.add(u);
    debounce('gal', galRefresh, 60);
  }
  function galItems(p) { return galVisible(p).map(k => p.gal.list[k]); }

  // full-screen picture viewer
  function openLightbox(items, i, title) {
    if (!items || !items.length) return;
    S.lb = { items, i: Math.max(0, Math.min(i, items.length - 1)), title: title || '' };
    renderLightbox();
  }
  function closeLightbox() { if (!S.lb) return; S.lb = null; renderLightbox(); }
  function lbStep(d) { if (!S.lb) return; const n = S.lb.items.length; S.lb.i = (S.lb.i + d + n) % n; renderLightbox(); }
  function renderLightbox() {
    const el = $('#lightbox');
    if (!S.lb) { el.hidden = true; el.innerHTML = ''; return; }
    const { items, i, title } = S.lb, x = items[i], n = items.length;
    const body = x.kind === 'yt'
      ? `<a class="lb-yt" href="https://www.youtube.com/watch?v=${h(x.id)}"><img src="${h(x.u)}" referrerpolicy="no-referrer" alt=""><span class="gal-play">${ic('play')}</span><span class="lb-ytl">Watch on YouTube</span></a>`
      : `<img src="${h(x.u)}" referrerpolicy="no-referrer" alt=""${n > 1 ? ' data-act="lb-step" data-v="1" title="Next picture"' : ' data-act="lb-noop"'}>`;
    el.innerHTML = `<div class="lb-top"><span class="lbx-title">${h(title)}</span><span class="dim">${i + 1} / ${n}</span><button class="icon-btn" data-act="lb-close" title="Close (Esc)" aria-label="Close">${ic('x')}</button></div>
      <div class="lb-stage" data-act="lb-close">${body}${n > 1 ? `<button class="lb-nav prev" data-act="lb-step" data-v="-1" aria-label="Previous picture">${ic('back')}</button><button class="lb-nav next" data-act="lb-step" data-v="1" aria-label="Next picture">${ic('fwd')}</button>` : ''}</div>`;
    el.hidden = false;
  }
  function familyMatch(modId, f) {
    const same = stMods().filter(x => +x.modId === +modId);
    if (!same.length) return null;
    const byName = same.filter(x => x.fileName && norm(x.fileName) === norm(f.name));
    if (byName.length === 1) return byName[0];
    if (same.length === 1 && !same[0].fileName && f.category === 'MAIN') return same[0];
    return null;
  }
  function modAction(m, files) {
    if (FW[m.modId]) return { kind: 'fw' };
    const inst = stMods().filter(x => +x.modId === +m.modId);
    if (inst.length) {
      for (const e of inst) {
        const cur = files.find(f => +f.fileId === +e.fileId);
        const cand = files.filter(f => LIVE.includes(f.category) && +f.fileId !== +e.fileId && (cur ? norm(f.name) === norm(cur.name) && f.date > cur.date : f.category === 'MAIN')).sort((a, b) => b.date - a.date)[0];
        if (cand) return { kind: 'installed', entry: e, upd: cand };
      }
      return { kind: 'installed', entry: inst[0] };
    }
    const dis = stDis().find(x => +x.modId === +m.modId);
    if (dis) return { kind: 'disabled', entry: dis };
    const mains = files.filter(f => f.category === 'MAIN').sort((a, b) => b.date - a.date);
    if (mains.length === 1) return { kind: 'get', file: mains[0] };
    if (mains.length > 1) return { kind: 'choose', n: mains.length };
    return { kind: 'none' };
  }
  function queueName(m, f, files) {
    const mains = files.filter(x => x.category === 'MAIN');
    return f.category === 'MAIN' && mains.length <= 1 ? decode(m.name) : `${decode(m.name)} - ${decode(f.name)}`;
  }
  function modPane(p) {
    const m = p.data.mod, files = p.data.files, c = compatOf(m), pt = patch(), a = modAction(m, files);
    const reqs = (m.modRequirements && m.modRequirements.nexusRequirements && m.modRequirements.nexusRequirements.nodes) || [];
    const missing = reqs.filter(r => !r.externalRequirement && +r.modId && modStatus(r.modId) !== 'inst').length;
    const liveFiles = files.filter(f => LIVE.includes(f.category));
    const verdict = FW[m.modId] ? callout('info', '<b>Framework.</b> cpmods installs and updates this from GitHub. Use Library, More tools, Update frameworks.')
      : c.k === 'ok' ? callout('ok', `<b>Updated ${fmtDate(m.updatedAt)}</b>, after ${h(pt.label)} came out.`)
        : c.k === 'warn' ? callout('warn', `<b>Not updated since ${h(pt.label)}.</b> It runs scripts, so it may be broken. Check "Contents" on a file and the Posts tab on Nexus first.`)
          : callout('neutral', `<b>Last updated ${fmtDate(m.updatedAt)}.</b> No script requirements, so it usually keeps working across patches.`);
    const how = `Opens the file on Nexus in ${h(browserName())}. Click <b>Slow download</b> there and cpmods installs it automatically.`;
    let action = '';
    if (a.kind === 'get') action = `<div class="action-row"><div class="action-file"><b>${h(decode(a.file.name))}</b><span>v${h(a.file.version || '?')} &middot; ${fmtSize(a.file.sizeInBytes)} &middot; ${fmtDate(a.file.date)}</span></div>
        <button class="btn lg primary" data-act="get" data-mod="${+m.modId}" data-file="${+a.file.fileId}" data-name="">${ic('dl')}Download</button>
        <button class="btn lg" data-act="queue-add" data-mod="${+m.modId}" data-file="${+a.file.fileId}" data-name="${h(queueName(m, a.file, files))}" title="Download later; queued pages open one after another">${ic('plus')}Queue</button></div><div class="helper">${how}</div>${missing ? `<div class="helper" style="color:var(--warn)">Needs ${plural(missing, 'other mod')} first: see Requirements below.</div>` : ''}`;
    else if (a.kind === 'installed') action = `<div class="action-row"><div class="action-file"><b>Installed${a.entry.version ? ' v' + h(a.entry.version) : ''}</b><span>${a.upd ? `Version ${h(a.upd.version || '?')} is available (${fmtDate(a.upd.date)}).` : 'This is in your Library.'}</span></div>
        ${a.upd ? `<button class="btn lg primary" data-act="get" data-mod="${+m.modId}" data-file="${+a.upd.fileId}" data-name="${h(a.entry.name)}">${ic('refresh')}Update</button>` : ''}<button class="btn lg" data-act="go-lib">Open in Library</button></div>${a.upd ? `<div class="helper">${how} The old version is replaced.</div>` : ''}`;
    else if (a.kind === 'disabled') action = `<div class="action-row"><div class="action-file"><b>Disabled</b><span>Its files are set aside. Turn it back on any time.</span></div><button class="btn lg primary" data-act="mod-enable" data-name="${h(a.entry.name)}">Enable</button></div>`;
    else if (a.kind === 'choose') action = `<div class="action-row"><div class="action-file"><b>${a.n} main files</b><span>This mod comes in several versions. Pick one under Files below.</span></div></div>`;
    else if (a.kind === 'none') action = `<div class="action-row"><div class="action-file"><b>No downloadable files</b><span>Check the mod page on Nexus.</span></div></div>`;
    const filesOpen = p.filesOpen != null ? p.filesOpen : a.kind === 'choose';
    const desc = m.description ? bbToHtml(m.description) : '', long = desc.length > 1400 || /<img/.test(desc), sum = stripBB(m.summary);
    const reqHead = reqs.length ? `<span class="n${missing ? ' hot' : ''}">${missing ? missing + ' missing' : reqs.length}</span>` : '';
    // optional setting: hide requirements that are already installed
    const isInst = r => !r.externalRequirement && +r.modId && modStatus(r.modId) === 'inst';
    const instN = reqs.filter(isInst).length, hideInst = !!prefs.reqMissingOnly && !p.allReqs;
    const shownReqs = hideInst ? reqs.filter(r => !isInst(r)) : reqs;
    let reqBody = '<p class="dim small" style="margin:0">None listed on Nexus. It works on its own, or the author did not list them.</p>';
    if (reqs.length) {
      reqBody = (shownReqs.length ? `<div class="card"><div class="list">${shownReqs.map(reqRow).join('')}</div></div>` : '');
      if (hideInst && instN) reqBody += shownReqs.length
        ? `<p class="req-note">${plural(instN, 'installed requirement')} hidden. <button class="link-btn" data-act="reqs-all">Show</button></p>`
        : `<p class="req-note ok">${ic('check')}${instN === 1 ? 'The requirement is' : `All ${instN} requirements are`} installed. <button class="link-btn" data-act="reqs-all">Show</button></p>`;
      else if (prefs.reqMissingOnly && p.allReqs && instN) reqBody += '<p class="req-note"><button class="link-btn" data-act="reqs-all">Hide installed ones</button></p>';
    }
    return paneHead(decode(m.name), `<a class="icon-btn" href="${NEXUS}/mods/${+m.modId}" target="_blank" rel="noopener" title="Open on Nexus">${ic('ext')}</a>`)
      + galleryHtml(p)
      + `<div class="pane-body">
        <h2>${h(decode(m.name))}</h2>
        <div class="facts"><span>by ${h(m.author || (m.uploader && m.uploader.name) || 'unknown')}</span>${m.modCategory ? `<span>${h(m.modCategory.name)}</span>` : ''}<span>v${h(m.version || '?')}</span></div>
        <div class="statline">${stats(m)}</div>
        ${sum ? `<p class="lead">${h(sum)}</p>` : ''}
        ${verdict}
        ${action ? `<div class="action-card">${action}</div>` : ''}
        ${localSection(p, localEntries(m.modId))}
        <section class="sect"><div class="sect-head"><h3>Requirements</h3>${reqHead}</div>${reqBody}</section>
        <section class="sect"><div class="sect-head"><h3>About this mod</h3></div>
          ${desc ? `<div class="bb${long && !p.descOpen ? ' clamp' : ''}">${desc}</div>${long ? `<button class="btn sm" data-act="desc-more" style="margin-top:10px">${p.descOpen ? 'Show less' : 'Show the full description'}</button>` : ''}` : '<p class="dim small" style="margin:0">No description.</p>'}</section>
        <section class="sect"><button class="sect-toggle" data-act="toggle-files" aria-expanded="${filesOpen}"><span class="chev">${ic(filesOpen ? 'down' : 'fwd')}</span><h3>Files</h3><span class="n">${liveFiles.length}</span><span class="hint">Versions, optional files, what is inside</span></button>
          ${filesOpen ? `<div class="sect-body">${filesTab(p, m, files)}</div>` : ''}</section>
      </div>`;
  }
  function filesTab(p, m, files) {
    const isFw = !!FW[m.modId];
    const groups = FILE_CATS.map(([k, l]) => [l, files.filter(f => f.category === k).sort((a, b) => b.date - a.date)]).filter(g => g[1].length);
    const old = files.filter(f => f.category === 'OLD_VERSION').sort((a, b) => b.date - a.date);
    if (!groups.length && !old.length) return '<div class="empty">No files listed.</div>';
    return groups.map(([l, list]) => `<div class="sub-label">${h(l)}</div><div class="flist">${list.map(f => fileRow(p, m, f, files, isFw)).join('')}</div>`).join('')
      + (old.length ? `<details class="old"${p.showOld ? ' open' : ''} style="margin-top:14px"><summary data-act="toggle-old">Old versions (${old.length})</summary><div class="flist" style="margin-top:8px">${old.map(f => fileRow(p, m, f, files, isFw)).join('')}</div></details>` : '');
  }
  function fileRow(p, m, f, files, isFw) {
    const pt = patch(), pre = f.date < pt.epoch, ins = p.inspect[f.fileId];
    let acts;
    if (isFw) acts = '<span class="pill">via GitHub</span>';
    else if (stMods().some(x => +x.fileId === +f.fileId)) acts = '<span class="pill accent">Installed</span>';
    else if (stDis().some(x => +x.fileId === +f.fileId)) acts = '<span class="pill">Disabled</span>';
    else {
      const fam = familyMatch(m.modId, f), queued = stQueue().some(x => +x.fileId === +f.fileId && !x.done);
      acts = `<button class="btn sm primary" data-act="get" data-mod="${+m.modId}" data-file="${+f.fileId}" data-name="${h(fam ? fam.name : '')}">${fam ? 'Update' : 'Download'}</button>`
        + (queued ? '<span class="pill info">Queued</span>' : `<button class="btn sm" data-act="queue-add" data-mod="${+m.modId}" data-file="${+f.fileId}" data-name="${h(fam ? fam.name : queueName(m, f, files))}">Queue</button>`);
    }
    acts += `<button class="btn sm ghost" data-act="inspect" data-mod="${+m.modId}" data-file="${+f.fileId}" title="What is inside this file">${ins ? 'Hide' : 'Contents'}</button>`;
    return `<div class="frow"><div class="frow-top"><div class="frow-main"><div class="frow-name">${h(decode(f.name))} <span class="pill ${pre ? '' : 'ok'}">${pre ? 'pre-' + h(pt.label) : h(pt.label) + '+'}</span></div>
      <div class="frow-sub">v${h(f.version || '?')} &middot; ${fmtDate(f.date)} &middot; ${fmtSize(f.sizeInBytes)}</div></div><div class="frow-acts">${acts}</div></div>
      ${f.description ? `<div class="frow-desc">${h(stripBB(f.description))}</div>` : ''}${ins ? inspectHtml(ins, f) : ''}</div>`;
  }
  function inspectHtml(info, f) {
    if (info.loading) return '<div class="inspect"><span class="spin"></span> Reading the file list from Nexus</div>';
    if (info.error) return `<div class="inspect err">${h(info.error)}</div>`;
    const k = info.kinds || {}, pt = patch(), pre = f.date < pt.epoch, parts = [];
    if (k.native) parts.push('native plugin (.dll)'); if (k.redscript) parts.push('redscript'); if (k.cet) parts.push('CET Lua'); if (k.tweak) parts.push('TweakXL'); if (k.archivexl) parts.push('ArchiveXL'); if (k.archive) parts.push('game archives'); if (k.input) parts.push('XML'); if (k.config) parts.push('ini');
    let cls = 'ok', v;
    if (!info.fileCount) { cls = ''; v = 'Nexus has no file list for this upload.'; }
    else if (!pre) v = `Uploaded after ${h(pt.label)} came out.`;
    else if (k.native) { cls = 'bad'; v = `Native plugin built before ${h(pt.label)}: almost always needs an update after a patch.`; }
    else if (k.redscript || k.cet) { cls = 'warn'; v = `Scripts from before ${h(pt.label)}: many still work, some break.`; }
    else v = 'Assets only: usually keeps working across patches.';
    return `<div class="inspect"><div><span class="pill ${cls}">${pre ? 'pre-' + h(pt.label) : h(pt.label) + '+'}</span> ${v}</div><div class="dim" style="margin-top:6px">${info.fileCount} files${parts.length ? ': ' + h(parts.join(', ')) : ''}${info.fomod ? ' &middot; has installer options' : ''}${info.sha256 ? ' &middot; checksum verified on download' : ''}</div>${info.files && info.files.length ? `<pre>${h(info.files.join('\n'))}</pre>` : ''}</div>`;
  }
  function reqRow(r) {
    const id = +r.modId;
    if (r.externalRequirement || !id) return `<div class="li"><div class="li-main"><div class="li-title"><span class="t">${h(decode(r.modName || 'External requirement'))}</span><span class="pill">not on Nexus</span></div><div class="li-sub"><span>${h(stripBB(r.notes || ''))}</span></div></div></div>`;
    const st = modStatus(id);
    const right = st === 'inst' ? '<span class="pill ok">Installed</span>' : FW[id] ? '<button class="btn sm" data-act="fw-sync">Install frameworks</button>' : st === 'q' ? '<span class="pill info">Queued</span>' : st === 'dis' ? '<span class="pill">Disabled</span>' : '<span class="pill warn">Missing</span>';
    return `<div class="li click" data-act="open-mod" data-id="${id}" tabindex="0" role="button" title="Show this mod"><div class="li-main"><div class="li-title"><span class="t">${h(decode(r.modName || 'Mod ' + id))}</span></div>${r.notes ? `<div class="li-sub"><span>${h(stripBB(r.notes))}</span></div>` : ''}</div><div class="li-acts">${right}<span class="li-go">${ic('fwd')}</span></div></div>`;
  }
  async function inspect(modId, fileId) {
    const p = S.pane;
    if (!p || p.kind !== 'mod') return;
    if (p.inspect[fileId]) { delete p.inspect[fileId]; renderPane(); return; }
    p.inspect[fileId] = { loading: true }; renderPane();
    try { p.inspect[fileId] = await api(`/api/fileinfo?mod=${+modId}&file=${+fileId}`); } catch (e) { p.inspect[fileId] = { error: e.message }; }
    if (S.pane === p) renderPane();
  }

  // collection details
  async function openCollection(slug, mode) {
    if (!slug) return;
    if (S.pane && S.pane.kind === 'col' && S.pane.slug === slug && S.pane.data && mode !== 'restore') { setPaneMin(false); return; }
    const p = { kind: 'col', slug, data: null, filter: 'all', q: '', showAll: false };
    openPane(p, mode);
    try {
      const d = await gql(`query($s: String!) { collection(slug: $s, domainName: "${GAME}") { slug name summary description endorsements totalDownloads user { name } tileImage { url } headerImage { url } category { name } latestPublishedRevision { revisionNumber modCount totalSize updatedAt adultContent gameVersions { reference } modFiles { fileId optional file { fileId name version category date sizeInBytes mod { modId name author updatedAt adultContent modCategory { name } } } } } } }`, { s: slug });
      if (!d.collection) throw new Error('Collection not found');
      p.data = d.collection;
    } catch (e) { p.error = e.message; }
    if (S.pane === p) renderPane();
  }
  function colRows(col) {
    const mf = ((col.latestPublishedRevision && col.latestPublishedRevision.modFiles) || []).filter(x => x.file && x.file.mod), per = {};
    mf.forEach(x => { per[x.file.mod.modId] = (per[x.file.mod.modId] || 0) + 1; });
    return mf.map(x => {
      const mod = x.file.mod, id = +mod.modId, fid = +x.fileId;
      let status = 'missing';
      if (stMods().some(m => +m.fileId === fid)) status = 'inst';
      else if (FW[id] && stMods().some(m => +m.modId === id)) status = 'fw';
      else if (stMods().some(m => +m.modId === id)) status = 'other';
      else if (stDis().some(m => +m.modId === id)) status = 'dis';
      else if (stQueue().some(q => +q.fileId === fid && !q.done)) status = 'q';
      return { x, mod, id, fid, status, optional: !!x.optional, name: per[mod.modId] > 1 ? `${decode(mod.name)} - ${decode(x.file.name)}` : decode(mod.name) };
    }).sort((a, b) => (a.optional - b.optional) || a.name.localeCompare(b.name));
  }
  function colPane(p) {
    const col = p.data, r = col.latestPublishedRevision || {}, pt = patch(), rows = colRows(col), ok = gvOk(col);
    const missReq = rows.filter(x => x.status === 'missing' && !x.optional && !FW[x.id]), missAll = rows.filter(x => x.status === 'missing' && !FW[x.id]);
    const have = rows.filter(x => ['inst', 'fw', 'other'].includes(x.status)).length;
    const segs = [['all', 'All', rows.length], ['missing', 'Missing', missAll.length], ['have', 'Installed', have], ['optional', 'Optional', rows.filter(x => x.optional).length]];
    const hero = [col.headerImage && col.headerImage.url, col.tileImage && col.tileImage.url].find(u => u && !badImgs.has(u));
    return paneHead(decode(col.name), `<a class="icon-btn" href="${NEXUS_NEXT}/collections/${encodeURIComponent(col.slug)}" target="_blank" rel="noopener" title="Open on Nexus">${ic('ext')}</a>`)
      + (hero && perf().pics !== 'off' ? `<img class="pane-hero" ${IMG.attr(hero)} alt="">` : '')
      + `<div class="pane-body">
        <h2>${h(decode(col.name))}</h2>
        <div class="facts"><span>by ${h(col.user ? col.user.name : '?')}</span>${col.category ? `<span>${h(col.category.name)}</span>` : ''}<span>revision ${h(r.revisionNumber)}</span><span>${fmtSize(r.totalSize)}</span></div>
        <div class="statrow"><div class="statbox"><b>${rows.length}</b><span>mods</span></div><div class="statbox"><b>${have}</b><span>you have</span></div><div class="statbox"><b>${missReq.length}</b><span>required, missing</span></div></div>
        ${ok ? callout('ok', `<b>Built for game ${h(gvList(col)[0] || '?')}</b>, your version.`) : callout('warn', `<b>Built for game ${h(gvList(col)[0] || '?')}.</b> Some of these mods may be broken on ${h(pt.label)}.`)}
        <div class="action-card"><div class="action-row"><div class="action-file"><b>Get what you are missing</b><span>Each mod needs one "Slow download" click on Nexus; pages open one after another.</span></div></div>
          <div class="toolbar" style="margin-top:12px"><button class="btn primary" data-act="col-queue" data-scope="req"${missReq.length ? '' : ' disabled'}>Queue ${missReq.length} required</button><button class="btn" data-act="col-queue" data-scope="all"${missAll.length ? '' : ' disabled'}>Queue all ${missAll.length} missing</button></div></div>
        <div class="tabs" style="gap:8px;padding-top:10px;padding-bottom:10px"><div class="seg">${segs.map(([v, l, n]) => `<button data-act="col-filter" data-v="${v}" class="${p.filter === v ? 'on' : ''}">${l} <span class="n">${n}</span></button>`).join('')}</div><input type="search" id="col-q" placeholder="Filter" value="${h(p.q)}" style="flex:1;min-width:120px"></div>
        <div id="colrows">${colRowsHtml(p, rows)}</div>
        ${col.description || col.summary ? `<div class="sub-label" style="margin-top:24px">About</div><div class="bb">${bbToHtml(col.description || col.summary)}</div>` : ''}
      </div>`;
  }
  function colRowsHtml(p, rows) {
    const q = p.q.trim().toLowerCase();
    let list = rows;
    if (p.filter === 'missing') list = list.filter(x => x.status === 'missing' && !FW[x.id]);
    else if (p.filter === 'have') list = list.filter(x => ['inst', 'fw', 'other'].includes(x.status));
    else if (p.filter === 'optional') list = list.filter(x => x.optional);
    if (q) list = list.filter(x => x.name.toLowerCase().includes(q));
    const shown = p.showAll ? list : list.slice(0, 120), pt = patch();
    if (!list.length) return '<div class="empty">No mods match.</div>';
    const st = { inst: '<span class="pill accent">Installed</span>', fw: '<span class="pill ok">Framework</span>', other: '<span class="pill muted">Other version</span>', dis: '<span class="pill">Disabled</span>', q: '<span class="pill info">Queued</span>', missing: '' };
    return `<div class="card"><div class="list">${shown.map(row => {
      const f = row.x.file, pre = f.date < pt.epoch;
      return `<div class="li click" data-act="open-mod" data-id="${row.id}" tabindex="0" role="button" title="Show this mod"><div class="li-main"><div class="li-title"><span class="t">${h(decode(row.mod.name))}</span>${row.optional ? '<span class="pill">optional</span>' : ''}${st[row.status]}</div>
        <div class="li-sub"><span>${h(decode(f.name))} v${h(f.version || '?')}</span><span style="color:${pre ? 'var(--text3)' : 'var(--ok)'}">${fmtDate(f.date)}</span></div></div>
        <div class="li-acts">${row.status === 'missing' ? `<button class="btn sm" data-act="get" data-mod="${row.id}" data-file="${row.fid}" data-name="${h(row.name)}">Download</button>` : ''}<span class="li-go">${ic('fwd')}</span></div></div>`;
    }).join('')}</div></div>${list.length > shown.length ? `<div class="foot"><button class="btn sm" data-act="col-all">Show all ${list.length}</button></div>` : ''}`;
  }
  async function colQueue(scope) {
    const p = S.pane;
    if (!p || p.kind !== 'col') return;
    const rows = colRows(p.data).filter(x => x.status === 'missing' && !FW[x.id] && (scope === 'all' || !x.optional));
    if (!rows.length) return;
    if (!await ask({ title: `Queue ${plural(rows.length, 'mod')}?`, body: `From <b>${h(decode(p.data.name))}</b>. The first Nexus page opens now. After each <b>Slow download</b> click, cpmods installs the file and opens the next page.`, ok: 'Queue and start' })) return;
    queueAdd(rows.map(x => ({ modId: x.id, fileId: x.fid, name: x.name, why: 'Collection: ' + decode(p.data.name) })), true);
  }

  // tool panes
  function openTool(tool, mode) {
    // old links (#/library/tool/compat): it is a page now
    if (tool === 'compat') return go('compat');
    if (tool === 'bisect') return openBisect(mode);
    if (tool === 'discover') return runTool({ kind: 'discover', sel: {}, open: {} }, '/api/discover', (d, p) => { (d.mods || []).forEach(m => { if (!m.vortex && !m.framework) p.sel[m.id] = true; }); }, mode);
    if (tool === 'gamelog') return runTool({ kind: 'gamelog' }, '/api/check', null, mode);
    if (tool === 'log') return runTool({ kind: 'log' }, '/api/log', null, mode);
    if (tool === 'backups') return runTool({ kind: 'backups', tab: S.pane && S.pane.kind === 'backups' ? S.pane.tab : 'points', plans: {} }, '/api/backups', null, mode);
    if (tool === 'profiles') return runTool({ kind: 'profiles' }, '/api/profiles', null, mode);
    if (tool === 'keys') return runTool({ kind: 'keys' }, '/api/keymap', null, mode);
    if (tool === 'packs') return openPane({ kind: 'packs' }, mode);
  }
  async function runTool(p, url, after, mode) {
    p.loading = true;
    openPane(p, mode);
    try { p.data = await api(url); if (after) after(p.data, p); } catch (e) { p.error = e.message; }
    p.loading = false;
    if (S.pane === p) renderPane();
  }
  function toolShell(p, title, intro, inner) {
    return paneHead(title) + `<div class="pane-body"><h2>${h(title)}</h2><p class="muted" style="margin:0 0 16px">${intro}</p>${p.loading ? '<div class="callout neutral"><span class="spin"></span><div>Working on it. This can take a few seconds.</div></div>' : p.error ? `<div class="err">${h(p.error)}</div>` : inner()}</div>`;
  }
  const ISSUE_KIND = { requirement: 'Missing requirement', files: 'Same files', archive: 'Asset overlap', note: 'Author note', script: 'Script clash', tweak: 'Shared tweaks', outdated: 'Not updated' };
  function pageCompat(el) {
    const L = S.lib, d = L.compat;
    el.innerHTML = `<header class="page-head"><div class="ph-top">
        <div><h1>Compatibility</h1><p class="sub">Missing requirements, mods that install the same files or change the same game assets, script functions replaced twice, shared database tweaks and script mods not updated for the current patch. Each finding gets a risk level with the reasons behind it.</p></div>
        <div class="ph-actions"><button class="btn" data-act="compat-run"${L.compatLoading ? ' disabled' : ''}>${L.compatLoading ? '<span class="spin"></span>Checking' : ic('refresh') + 'Run again'}</button></div></div></header>
      <div class="page-body">${!d ? '<div class="callout neutral"><span class="spin"></span><div>Checking your mods. This can take a few seconds.</div></div>' : d.error ? `<div class="err">${h(d.error)}</div>` : compatHtml(d)}</div>`;
    // only the first visit starts a check: a failed one waits for "Run again" (drawing this page must not retry it)
    if (!d) ensureCompat(false);
  }
  function compatHtml(d) {
      const all = d.issues || [], live = all.filter(i => !i.ignored), ign = all.filter(i => i.ignored);
      const by = r => live.filter(i => (i.risk || 'low') === r), hi = by('high'), me = by('medium'), lo = by('low'), ok = by('ok');
      const head = !live.length ? callout('ok', `<b>No problems found</b> across ${d.mods} mods and ${fmtNum(d.assets)} game assets.`)
        : callout(hi.length ? 'bad' : me.length ? 'warn' : 'ok', `<b>${hi.length} high, ${me.length} medium and ${lo.length} low risk${ok.length ? `, plus ${ok.length} intended overlap${ok.length === 1 ? '' : 's'}` : ''}.</b> High risk usually means something will not work. Low risk and intended overlaps can be left alone.`);
      const legend = `<div class="legend" style="margin:10px 0 4px">${['high', 'medium', 'low', 'ok'].map(r => `<span>${riskPill(r)} ${h({ high: 'likely breaks something', medium: 'worth a look', low: 'usually fine', ok: 'on purpose, leave it' }[r])}</span>`).join('')}</div>`;
      // a group you opened or closed stays that way when the page is drawn again (S.compatOpen, kept by the toggle listener)
      const group = (title, list, open) => list.length ? `<details class="risk-group" data-grp="${h(title)}"${(S.compatOpen && title in S.compatOpen ? S.compatOpen[title] : open) ? ' open' : ''}><summary>${h(title)} <span class="n">${list.length}</span></summary>${list.map(issueCard).join('')}</details>` : '';
      const rules = arr(d.loadOrder);
      const loCard = rules.length ? `<div class="card lo-card"><div class="card-head"><h3>${ic('list')} Winners you chose</h3><span class="dim small">These archives load first and win; cpmods keeps it that way after updates</span></div><div class="list">${rules.map(r => `<div class="li slim"><div class="li-main"><div class="li-title"><span class="t">${h(r.mod)}</span></div><div class="li-sub"><span class="mono-path">${h(r.name)}</span><span>wins over ${h(arr(r.over).join(', '))}</span></div></div><button class="btn sm ghost" data-act="lo-undo" data-archive="${h(r.name)}">${ic('undo')}Undo</button></div>`).join('')}</div></div>` : '';
      return loCard + head + legend + group('High risk', hi, true) + group('Medium risk', me, true) + group('Low risk', lo, hi.length + me.length < 4) + group('Intended overlaps and your choices', ok, false) + group('Marked as fine', ign, false)
        + `<p class="dim small" style="margin-top:14px">Checked ${h(fmtTime(d.checked))}.</p>`;
  }
  // asset overlap: a "Let X win" for each mod (files[0] is the one that wins now); the one you chose shows as chosen
  function winBtn(i, k) {
    const name = i.mods[k];
    if (!findItem(name)) return '';
    if (i.chosen === name) return `<span class="pill ok" title="Undo it under Winners you chose">${h(short(name, 22))} wins, your choice</span>`;
    const tip = k === 0 ? 'It wins now. This keeps it that way and settles this overlap.' : `Renames ${i.files[1]} with a ! in front so it loads first. cpmods keeps the name after updates; you can undo it.`;
    return `<button class="btn sm" data-act="lo-win" data-archive="${h(i.files[k])}" data-over="${h(i.files[1 - k])}" data-mod="${h(name)}" title="${h(tip)}">Let ${h(short(name, 22))} win</button>`;
  }
  function issueCard(i) {
    const mods = (i.mods || []).map(n => findItem(n) ? `<button class="mchip sm" data-act="lib-open" data-name="${h(n)}">${h(n)}</button>` : `<span class="mchip sm static">${h(n)}</span>`).join('');
    return `<div class="issue ${h(i.risk || 'low')}${i.ignored ? ' ignored' : ''}"><div class="issue-top">${riskPill(i.risk)}<span class="pill">${h(ISSUE_KIND[i.kind] || i.kind)}</span><b>${h(i.title)}</b></div>
      ${(i.why || []).length ? `<ul class="why">${i.why.map(w => `<li>${h(w)}</li>`).join('')}</ul>` : ''}
      ${i.detail && i.kind !== 'archive' ? `<p class="issue-detail">${h(i.detail)}</p>` : ''}
      <div class="issue-acts">${mods}<span class="spacer"></span>${i.kind === 'requirement' && i.reqId ? `<button class="btn sm primary" data-act="open-mod" data-id="${+i.reqId}">Get it</button>` : ''}${i.kind === 'archive' && arr(i.files).length === 2 && !i.ignored ? winBtn(i, 0) + winBtn(i, 1) : ''}${i.key ? `<button class="btn sm ghost" data-act="compat-ignore" data-key="${h(i.key)}" data-on="${i.ignored ? '0' : '1'}" title="${i.ignored ? 'Count it again' : 'Hide it from the summary; it moves to Marked as fine'}">${i.ignored ? 'Undo' : 'Mark as fine'}</button>` : ''}</div></div>`;
  }
  function discoverPane(p) {
    return toolShell(p, 'Find existing mods', 'Mods in your game folder that cpmods did not install, matched against Nexus. Adopting only starts tracking their files: nothing is moved or changed.', () => {
      const d = p.data, mods = d.mods || [], can = m => !m.vortex && !m.framework, n = mods.filter(m => p.sel[m.id] && can(m)).length;
      const fwHand = (d.frameworks || []).filter(f => !f.managed).map(f => f.name);
      if (!mods.length) return callout('ok', '<b>Nothing to adopt.</b> Every mod in your game folder is already managed by cpmods.') + (fwHand.length ? callout('info', `Frameworks installed by hand: <b>${h(fwHand.join(', '))}</b>. "Update frameworks" takes them over and backs up the current files.`) : '');
      return (fwHand.length ? callout('info', `Frameworks installed by hand: <b>${h(fwHand.join(', '))}</b>. "Update frameworks" takes them over and backs up the current files.`) : '')
        + `<div class="toolbar" style="margin:12px 0"><button class="btn primary" data-act="disc-adopt"${n ? '' : ' disabled'}>Adopt ${n} selected</button><button class="btn sm ghost" data-act="disc-all" data-v="1">Select all</button><button class="btn sm ghost" data-act="disc-all" data-v="0">Select none</button></div>
        <div class="card"><div class="list">${mods.map(m => {
          const pill = m.vortex ? '<span class="pill warn">Managed by Vortex</span>' : m.framework ? '<span class="pill">Framework</span>' : m.match === 'files' ? '<span class="pill ok">Identified</span>' : m.match === 'name' ? '<span class="pill muted">Matched by name</span>' : '<span class="pill">Not identified</span>';
          return `<div class="li" style="flex-wrap:wrap"><input type="checkbox" class="check" data-disc="${h(m.id)}"${can(m) ? '' : ' disabled'}${p.sel[m.id] && can(m) ? ' checked' : ''} aria-label="Select ${h(m.name)}">
            <div class="li-main"><div class="li-title"><span class="t">${h(decode(m.name))}</span>${pill}</div><div class="li-sub"><span>${m.fileCount} files</span><span>${h((m.roots || []).slice(0, 2).join(', '))}${(m.roots || []).length > 2 ? ', ...' : ''}</span>${m.vortex ? '<span>keep using Vortex for it</span>' : ''}</div></div>
            <div class="li-acts">${m.modId ? `<button class="btn sm ghost" data-act="open-mod" data-id="${+m.modId}">Nexus</button>` : ''}<button class="btn sm ghost" data-act="disc-files" data-id="${h(m.id)}">${p.open[m.id] ? 'Hide' : 'Files'}</button></div>
            ${p.open[m.id] ? `<pre class="mono" style="flex-basis:100%">${h((m.files || []).join('\n'))}</pre>` : ''}</div>`;
        }).join('')}</div></div>`;
    });
  }
  function gameLogPane(p) {
    return toolShell(p, 'Game logs', 'Errors from RED4ext, redscript and Cyber Engine Tweaks logs in the last 24 hours, plus mods with missing files.', () => {
      const c = p.data, parts = [];
      if (!c.checkedLogs) parts.push(callout('neutral', 'No mod logs yet. Launch the game once, then check again.'));
      if (c.missing.length) parts.push(callout('bad', `Files missing for: ${c.missing.map(x => `<b>${h(x.name)}</b> (${x.count})`).join(', ')}. Reinstall those mods.`));
      if (c.logs.length) parts.push(c.logs.map(l => `<div class="card" style="margin-top:12px"><div class="card-head"><h3>${h(l.file)}</h3><span class="dim small">${fmtDate(l.modified)}</span></div><div class="card-body"><pre class="mono" style="margin:0">${h(l.lines.join('\n'))}</pre></div></div>`).join(''));
      else if (c.checkedLogs) parts.push(callout('ok', `<b>No errors</b> in ${c.checkedLogs} mod logs from the last 24 hours.`));
      return parts.join('') + `<div class="toolbar" style="margin-top:14px"><button class="btn" data-act="tool" data-tool="gamelog">${ic('refresh')}Check again</button></div>`;
    });
  }
  function logPane(p) {
    return toolShell(p, 'Activity log', 'What cpmods did, newest at the bottom.', () => `<pre class="mono" style="max-height:none">${h((p.data.lines || []).join('\n'))}</pre>`);
  }
  // files grouped by game folder and drawn as a tree from the game folder down
  function fileSchema(files, opts) {
    opts = opts || {};
    const groups = new Map(), explain = prefs.explain === true;
    for (const f of files) { const L = locOf(f.path); if (!groups.has(L.k)) groups.set(L.k, []); groups.get(L.k).push(f); }
    const nodes = LOCS.filter(L => groups.has(L.k)).map(L => {
      const list = groups.get(L.k), size = list.reduce((s, f) => s + (+f.size || 0), 0);
      return `<div class="loc">${locHead(L, `${plural(list.length, 'file')}${size ? ' &middot; ' + fmtSize(size) : ''}`)}${explain ? `<p class="loc-d"><b>${h(L.by)}.</b> ${h(L.d)}</p>` : ''}<div class="loc-tree">${treeHtml(buildTree(list, L.p), opts)}</div></div>`;
    }).join('');
    return `<div class="schema compact"><div class="schema-root">${ic('folder')}<b>Cyberpunk 2077</b><span>game folder</span><span class="spacer"></span><button class="link-btn small" data-act="toggle-explain">${explain ? 'Hide' : 'Explain'} folders</button></div><div class="schema-branches">${nodes}</div></div>`;
  }
  function buildTree(items, base) {
    const root = { d: new Map(), f: [] }, cut = base ? base.length + 1 : 0;
    for (const it of items) {
      const parts = String(it.path).slice(cut).split('\\');
      let n = root;
      for (let i = 0; i < parts.length - 1; i++) { if (!n.d.has(parts[i])) n.d.set(parts[i], { d: new Map(), f: [] }); n = n.d.get(parts[i]); }
      n.f.push(Object.assign({ leaf: parts[parts.length - 1] }, it));
    }
    return root;
  }
  const treeCount = n => n.f.length + [...n.d.values()].reduce((s, x) => s + treeCount(x), 0);
  function treeHtml(n, opts) {
    const dirs = [...n.d.entries()].sort((a, b) => a[0].localeCompare(b[0]));
    return '<ul class="tr">' + dirs.map(([name, sub]) => { const c = treeCount(sub); return `<li class="tr-dir"><details${c <= 24 ? ' open' : ''}><summary>${ic('folder')}<span class="tr-name">${h(name)}</span><span class="tr-n">${c}</span></summary>${treeHtml(sub, opts)}</details></li>`; }).join('')
      + n.f.sort((a, b) => a.leaf.localeCompare(b.leaf)).map(f => fileLeaf(f, opts)).join('') + '</ul>';
  }
  function fileLeaf(f, opts) {
    const flags = [];
    if (f.exists === false && !opts.preview) flags.push('<span class="pill bad" title="cpmods installed it, but it is not in the game folder any more">Missing</span>');
    if ((f.shared || []).length) flags.push(`<span class="pill warn" title="Also installed by ${h(f.shared.join(', '))}. The copy installed last is used.">Also in ${h(f.shared[0])}${f.shared.length > 1 ? ' +' + (f.shared.length - 1) : ''}</span>`);
    if (f.backup) flags.push('<span class="pill muted" title="It replaced an original game file. The original is backed up and comes back when you remove the mod.">Replaces a game file</span>');
    if (opts.preview && f.owner) flags.push(`<span class="pill warn" title="This file is installed now by ${h(f.owner)}">Replaces a file of ${h(f.owner)}</span>`);
    else if (opts.preview && f.exists) flags.push('<span class="pill muted">Replaces an existing file</span>');
    const canReveal = !opts.preview && f.exists !== false;
    return `<li class="tr-file${f.exists === false && !opts.preview ? ' missing' : ''}">${kindChip(f.kind, false)}<span class="tr-name" title="${h(f.path)}&#10;${h(kindInfo(f.kind).t)}">${h(f.leaf)}</span>${flags.join('')}${f.size != null ? `<span class="tr-size">${fmtSize(f.size)}</span>` : ''}${canReveal ? `<button class="icon-btn xs" data-act="reveal" data-path="${h(f.path)}" title="Open its folder" aria-label="Open the folder of ${h(f.leaf)}">${ic('folder')}</button>` : ''}</li>`;
  }

  // what a library mod has in the game folder: status, download, files tree, last launch, conflicts
  async function loadLocal(p, name) {
    p.local = p.local || {};
    const cur = p.local[name];
    if (cur && (cur.loading || cur.sig === S.sig)) return;
    p.local[name] = { loading: true };
    try { p.local[name] = { data: await api('/api/modinfo?name=' + encodeURIComponent(name)), sig: S.sig }; }
    catch (e) { p.local[name] = { error: e.message, sig: S.sig }; }
    if (S.pane === p) renderPane();
  }
  const localEntries = modId => { const id = +modId; return id && S.st ? libItems().filter(m => +m.modId === id) : []; };
  function localSection(p, entries) {
    if (!entries.length) return '';
    return `<section class="sect"><div class="sect-head"><h3>In your game</h3>${entries.length > 1 ? `<span class="n">${entries.length} entries from this mod</span>` : ''}</div>${entries.map(e => localBlock(p, e)).join('')}</section>`;
  }
  function localBlock(p, m) {
    const L = p.local && p.local[m.name];
    if (!L || (!L.loading && L.sig !== S.sig)) setTimeout(() => loadLocal(p, m.name), 0);
    const d = L && L.data, iss = modIssues(m.name), ln = S.launch.data && (S.launch.data.mods || []).find(x => x.name === m.name);
    const sw = m.fw ? '<span class="pill">Framework, always on</span>' : `<label class="switch" title="${m.on ? 'On: click to disable (files are set aside)' : 'Off: click to enable'}"><input type="checkbox" data-toggle="${h(m.name)}"${m.on ? ' checked' : ''} aria-label="${m.on ? 'Disable' : 'Enable'} ${h(m.name)}"><span></span></label>`;
    const meta = [m.on ? 'On' : 'Off', m.version ? 'v' + String(m.version).replace(/^v/i, '') : '', SRC_LABEL[srcOf(m)], m.on && m.installed ? 'added ' + fmtDate(m.installed) : !m.on && m.disabledAt ? 'off since ' + fmtDate(m.disabledAt) : ''].filter(Boolean).map(h).join(' &middot; ');
    const head = `<div class="lb-head">${sw}<div class="lb-title"><b>${h(m.name)}</b><span>${meta}</span></div>${isNewSinceLaunch(m) ? '<span class="pill info" title="Installed after your last launch">New</span>' : ''}<button class="icon-btn" data-act="row-menu" data-name="${h(m.name)}" title="More actions" aria-label="More actions">${ic('more')}</button></div>`;
    if (!d) return `<div class="lblock">${head}${L && L.error ? `<div class="err">${h(L.error)}</div>` : '<div class="sk sk-line" style="width:60%"></div><div class="sk" style="height:110px;margin-top:10px"></div>'}</div>`;
    const parts = [], arch = d.archive;
    if (arch) parts.push(arch.exists ? `<div class="kv">${ic('dl')}<span>Download</span><b title="${h(arch.file)}">${h(arch.file)}</b><em>${fmtSize(arch.size)}, ${h(fmtDate(arch.date))}</em><button class="link-btn" data-act="reveal-dl" data-file="${h(arch.file)}">Show</button></div>` : callout('warn', 'Its download was deleted, so turning it off and on again needs a new download.'));
    else if (m.adopted || d.adopted) parts.push(callout('neutral', 'Installed before cpmods: there is no download to reinstall from. Turning it off moves its files aside; removing sends them to the Recycle Bin.'));
    if (!m.on && d.planned) parts.push(callout('neutral', 'It is off. These are the files that come back when you turn it on.'));
    else if (!m.on && !d.files.length) parts.push(callout('neutral', 'It is off and its files are set aside.'));
    const bk = (d.backups || []).length, sharedN = d.files.filter(f => (f.shared || []).length).length, missing = d.files.filter(f => f.exists === false).length;
    if (m.on && missing) parts.push(callout('bad', `${plural(missing, 'file')} of this mod ${missing === 1 ? 'is' : 'are'} missing from the game folder. Turn it off and on again to reinstall.`));
    if (bk) parts.push(callout('info', `It replaced ${plural(bk, 'original game file')}. cpmods keeps the originals and puts them back when you remove it.`));
    if (sharedN) parts.push(callout('warn', `${plural(sharedN, 'file')} also ${sharedN === 1 ? 'comes' : 'come'} from another mod: the copy installed last is the one in use.`));
    if (ln) {
      const bad = (ln.notes || []).filter(x => x.level === 'error' || x.level === 'warn'), word = { error: 'had a problem', warn: 'worth a check', new: 'not tested yet (added after it)', ok: 'loaded fine', assets: 'assets, loaded by the game' }[ln.status] || ln.status;
      parts.push(`<div class="lb-launch ${h(ln.status)}">${ic(bad.length ? 'alert' : ln.status === 'new' ? 'info' : 'check')}<div><b>Last launch:</b> ${h(word)}${(bad.length ? bad : (ln.notes || []).slice(0, 2)).map(x => `<div class="dim small">${h(x.text)}${x.note ? ' ' + h(x.note) : ''}</div>`).join('')}</div></div>`);
    }
    // only what can crash the game shows here; everything else is on the Compatibility page
    const crash = iss.filter(crashy), rest = iss.length - crash.length;
    if (iss.length) parts.push(`<div class="lb-issues">${crash.map(i => `<button class="lb-issue" data-act="go" data-page="compat" title="Open the Compatibility page">${riskPill(i.risk)}<span>${h(i.title)}</span></button>`).join('')}${rest ? `<button class="link-btn small" data-act="go" data-page="compat">${plural(rest, 'other compatibility note')}</button>` : ''}</div>`);
    if (d.files.length) {
      // collapsed by default (open by default in the files-only panel); the button says where the files go
      const fs = p.filesShown = p.filesShown || {}, open = m.name in fs ? fs[m.name] : p.kind === 'files';
      const where = [...new Set(d.files.map(f => locOf(f.path).t))].slice(0, 3).join(', ');
      parts.push(`<button class="files-toggle${open ? ' open' : ''}" data-act="local-files" data-name="${h(m.name)}" aria-expanded="${open}"><span class="chev">${ic(open ? 'down' : 'fwd')}</span>${ic('folder')}<span class="ft-txt"><b>${open ? 'Hide files' : 'Show files'}</b><span>${plural(d.files.length, 'file')}${d.total ? ', ' + fmtSize(d.total) : ''}${d.planned ? ', when turned on' : ''}${where ? ' &middot; ' + h(where) : ''}</span></span></button>${open ? `<div class="files-box">${fileSchema(d.files, {})}</div>` : ''}`);
    }
    return `<div class="lblock">${head}${parts.join('')}</div>`;
  }
  function filesPane(p) {
    const m = findItem(p.name);
    if (!m) return paneHead(p.name) + `<div class="pane-body"><div class="err">${h(p.name)} is not in your library any more.</div></div>`;
    return paneHead(p.name, m.modId ? `<button class="icon-btn" data-act="open-mod" data-id="${+m.modId}" title="Nexus details">${ic('info')}</button>` : '')
      + `<div class="pane-body"><h2>${h(p.name)}</h2><div class="facts"><span>${h(SRC_LABEL[srcOf(m)])}</span>${m.fw ? '<span>Framework</span>' : ''}${(m.kinds || []).length ? `<span class="kchips">${kindChips(m.kinds, 6)}</span>` : ''}</div>
        ${!m.modId ? callout('neutral', 'cpmods has no Nexus page for this mod, so only what is in your game folder is shown.') : ''}${localSection(p, [m])}</div>`;
  }
  function openFiles(name, mode) {
    if (S.pane && S.pane.kind === 'files' && S.pane.name === name && mode !== 'restore') { setPaneMin(false); return; }
    openPane({ kind: 'files', name, local: {} }, mode);
  }

  // what a downloaded archive holds and where each file would go
  async function openPreview(file, mode) {
    const p = { kind: 'preview', file, data: null };
    openPane(p, mode);
    try { p.data = await api('/api/preview?file=' + encodeURIComponent(file)); } catch (e) { p.error = e.message; }
    if (S.pane === p) renderPane();
  }
  function previewPane(p) {
    const d = p.data, dl = (S.st.downloads || []).find(x => x.file === p.file);
    const head = paneHead(p.file, `<button class="icon-btn" data-act="reveal-dl" data-file="${h(p.file)}" title="Show in folder">${ic('folder')}</button>`);
    if (p.error) return head + `<div class="pane-body"><div class="err">${h(p.error)}</div></div>`;
    if (!d) return head + '<div class="pane-body"><span class="spin"></span> Reading the archive</div>';
    const files = d.files || [], clash = files.filter(f => f.exists);
    const st = dl ? { installed: 'installed', disabled: 'disabled', pending: 'waiting to install', failed: 'needs attention', unused: 'not installed' }[dl.status] || dl.status : '';
    return head + `<div class="pane-body">
      <h2>${h((dl && dl.name) || p.file)}</h2>
      <div class="facts"><span>${plural(d.count, 'file')} inside</span><span>${fmtSize(d.size)} unpacked</span>${st ? `<span>${h(st)}</span>` : ''}</div>
      ${d.error ? callout('warn', h(d.error) + ((d.variants || []).length ? `<br>Versions inside: ${d.variants.map(h).join(', ')}` : '')) : callout('info', `This is where the ${plural(files.length, 'file')} ${files.length === 1 ? 'goes' : 'go'} when installed.${clash.length ? ` <b>${plural(clash.length, 'file')}</b> already exist${clash.length === 1 ? 's' : ''} and would be replaced.` : ''}`)}
      ${files.length ? fileSchema(files, { preview: true }) : ''}
      ${(d.skipped || []).length ? `<details class="old" style="margin-top:14px"><summary>${plural(d.skipped.length, 'file')} not installed (readmes, images, other versions)</summary><pre class="mono">${h(d.skipped.join('\n'))}</pre></details>` : ''}
      <div class="toolbar" style="margin-top:16px">${dl && dl.status === 'unused' && !d.error ? `<button class="btn primary" data-act="dl-install" data-archive="${h(p.file)}">Install</button>` : ''}${dl && dl.modId ? `<button class="btn" data-act="open-mod" data-id="${+dl.modId}">Mod page</button>` : ''}<button class="btn ghost" data-act="reveal-dl" data-file="${h(p.file)}">${ic('folder')}Show in folder</button></div>
    </div>`;
  }

  // crash report details
  async function openCrash(id, mode) {
    const p = { kind: 'crash', id };
    openPane(p, mode);
    if (!S.launch.data) await loadLaunch(false);
    if (S.pane === p) renderPane();
  }
  function crashPane(p) {
    const d = S.launch.data, c = d && (d.crashes || []).find(x => x.id === p.id);
    if (!c) return paneHead('Crash report') + `<div class="pane-body">${S.launch.loading || !d ? '<span class="spin"></span> Reading the crash report' : '<div class="err">This crash report is not there any more.</div>'}</div>`;
    const others = (d.crashes || []).filter(x => x.signature && x.signature === c.signature && x.id !== c.id);
    const stackMods = (c.stack || []).filter(x => x.mod), inGame = /^cyberpunk2077\.exe$/i.test(c.module || '');
    const plugMods = [...new Set((c.plugins || []).map(x => x.mod))].sort((a, b) => a.localeCompare(b));
    return paneHead('Crash report', `<button class="icon-btn" data-act="reveal-crash" data-id="${h(c.id)}" title="Open the crash folder">${ic('folder')}</button>`) + `<div class="pane-body">
      <h2>Crash ${h(fmtWhen(c.time))}</h2>
      <div class="facts"><span>${h(c.when)}</span>${c.uptime != null ? `<span>after ${h(fmtDur(c.uptime))}</span>` : ''}${c.stage ? `<span>stage: ${h(c.stage)}</span>` : ''}${c.patch ? `<span>game ${h(c.patch)}</span>` : ''}</div>
      ${callout('bad', `<b>${h(c.reason || 'Crash')}</b>${c.message ? `<br>${h(c.message)}` : ''}`)}
      <section class="sect"><div class="sect-head"><h3>Where it crashed</h3></div>
        <div class="kv"><span>Code location</span><b class="mono">${h(c.signature || 'unknown')}</b></div>
        ${c.moduleMod ? callout('warn', `That file belongs to <b>${h(c.moduleMod)}</b>, the main suspect. Update it, or turn it off and test.`) : inGame ? callout('neutral', 'Inside the game\'s own code. That does not name a mod by itself; a mod can still cause it. If it keeps happening, use "Find the problem mod".') : ''}
        ${others.length ? callout('warn', `<b>Same crash spot as ${plural(others.length, 'other report')}</b> (${others.map(x => h(fmtWhen(x.time))).join(', ')}). It comes back, so it is worth tracking down.`) : callout('neutral', 'No other crash report has this exact spot, so it may have been a one-off.')}
      </section>
      ${stackMods.length ? `<section class="sect"><div class="sect-head"><h3>Mods seen on the crashed thread</h3></div><p class="dim small" style="margin:0 0 8px">Leftovers of what that thread ran recently: a hint, not proof.</p><div class="mchips">${stackMods.map(x => `<button class="mchip" data-act="lib-open" data-name="${h(x.mod)}">${h(x.mod)}<span>${h(x.module)}</span></button>`).join('')}</div></section>` : ''}
      ${plugMods.length ? `<section class="sect"><div class="sect-head"><h3>Mod plugins loaded at the time</h3><span class="n">${plugMods.length}</span></div><div class="mchips">${plugMods.map(n => `<span class="mchip static">${h(n)}</span>`).join('')}</div></section>` : ''}
      <section class="sect"><div class="sect-head"><h3>System</h3></div><div class="kv"><span>Graphics card</span><b>${h(c.gpu || '?')}</b></div><div class="kv"><span>Driver</span><b>${h(c.driver || '?')}</b></div><div class="kv"><span>Out of memory</span><b>${c.oom === 'true' ? 'yes' : 'no'}</b></div></section>
      <div class="toolbar" style="margin-top:18px"><button class="btn primary" data-act="bisect-open">${ic('bug')}Find the problem mod</button><button class="btn" data-act="reveal-crash" data-id="${h(c.id)}">${ic('folder')}Open crash folder</button></div>
    </div>`;
  }

  // troubleshooting setup: pick the suspects
  function openBisect(mode) {
    openPane({ kind: 'bisect', sel: null, scope: '' }, mode);
    if (!S.launch.data) loadLaunch(false);
  }
  function bisectCandidates() {
    const fw = new Set(S.st.frameworks.map(f => f.name));
    return S.st.mods.filter(m => !fw.has(m.name) && !/^github:/.test(m.source || '') && (m.archive || m.adopted)).sort((a, b) => a.name.localeCompare(b.name));
  }
  // mods added after the last launch that closed normally are the usual suspects
  function lastGoodStart() { const d = S.launch.data, g = d && (d.history || []).find(x => x.result === 'clean'); return g ? toDate(g.start) : null; }
  function bisectPane(p) {
    const bs = S.st.bisect;
    if (bs && bs.active) return paneHead('Find the problem mod') + `<div class="pane-body"><h2>Troubleshooting is running</h2><p class="muted">Answer on the Reports page after each launch.</p><button class="btn primary" data-act="go" data-page="reports">Go to the Reports page</button></div>`;
    const cands = bisectCandidates(), good = lastGoodStart();
    const changed = good ? cands.filter(m => { const t = toDate(m.installed); return t && t > good; }) : [];
    if (!p.sel) { p.sel = {}; (changed.length ? changed : cands).forEach(m => { p.sel[m.name] = true; }); p.scope = changed.length ? 'changed' : 'all'; }
    const n = cands.filter(m => p.sel[m.name]).length, rounds = n > 1 ? 1 + Math.ceil(Math.log2(n)) : 1;
    return paneHead('Find the problem mod') + `<div class="pane-body">
      <h2>Find the problem mod</h2>
      <p class="muted" style="margin:0 0 12px">For a crash or bug that happens every time. cpmods turns the suspects off, you launch the game and say whether the problem happened, then it brings half of them back. Each answer halves the list until one mod is left.</p>
      <ol class="steps"><li>Pick the suspects below: usually the mods added since the game last worked.</li><li>cpmods turns them off. Their files are set aside, not deleted.</li><li>Launch, check, answer. About <b>${rounds} launch${rounds === 1 ? '' : 'es'}</b> for ${plural(n, 'mod')}.</li></ol>
      <div class="toolbar" style="margin:14px 0 10px"><div class="seg">
        <button data-act="bisect-scope" data-v="changed" class="${p.scope === 'changed' ? 'on' : ''}"${changed.length ? '' : ' disabled'} title="${good ? 'Installed after your launch of ' + h(fmtWhen(good)) + ', which closed normally' : 'No launch that closed normally yet'}">Added since last good launch <span class="n">${changed.length}</span></button>
        <button data-act="bisect-scope" data-v="all" class="${p.scope === 'all' ? 'on' : ''}">All mods <span class="n">${cands.length}</span></button>
        <button data-act="bisect-scope" data-v="none" class="${p.scope === 'none' ? 'on' : ''}">None</button></div></div>
      <div class="card"><div class="list">${cands.map(m => `<label class="li check-row"><input type="checkbox" class="check" data-bsel="${h(m.name)}"${p.sel[m.name] ? ' checked' : ''}><div class="li-main"><div class="li-title"><span class="t">${h(m.name)}</span>${changed.includes(m) ? '<span class="pill info">new</span>' : ''}</div><div class="li-sub"><span class="kchips">${kindChips(m.kinds, 3)}</span><span>added ${h(fmtDate(m.installed))}</span></div></div></label>`).join('')}</div></div>
      <p class="dim small">Frameworks (RED4ext, Cyber Engine Tweaks, redscript, ArchiveXL...) stay on: other mods need them.</p>
      <div class="action-card"><div class="action-row"><div class="action-file"><b>${plural(n, 'mod')} selected</b><span>The game must be closed. cpmods turns them off now, then you launch the game.</span></div><button class="btn lg primary" data-act="bisect-start"${n ? '' : ' disabled'}>${ic('bug')}Start</button></div></div>
    </div>`;
  }
  async function adoptSelected() {
    const p = S.pane;
    if (!p || p.kind !== 'discover' || !p.data) return;
    const items = p.data.mods.filter(m => p.sel[m.id] && !m.vortex && !m.framework).map(m => ({ name: decode(m.name), modId: m.modId || 0, files: m.files, roots: m.roots }));
    if (!items.length) return;
    if (await action({ op: 'adopt', items }, `Adopting ${plural(items.length, 'mod')}`)) closePane();
  }

  // ---------- menus, modal, toasts ----------
  let menuAnchor = null;
  function openMenu(anchor, items) {
    const m = $('#menu');
    if (menuAnchor === anchor && !m.hidden) { closeMenu(); return; }
    m.innerHTML = items.map(it => it === '-' ? '<div class="menu-sep"></div>' : `<button class="menu-item${it.danger ? ' danger' : ''}" role="menuitem" data-act="${it.act}" ${Object.entries(it.data || {}).map(([k, v]) => `data-${k}="${h(v)}"`).join(' ')}>${it.icon ? ic(it.icon) : ''}${h(it.label)}</button>`).join('');
    m.hidden = false; menuAnchor = anchor;
    const r = anchor.getBoundingClientRect(), w = m.offsetWidth, ht = m.offsetHeight;
    m.style.left = Math.max(8, Math.min(window.innerWidth - w - 8, r.right - w)) + 'px';
    m.style.top = (r.bottom + ht + 8 > window.innerHeight ? Math.max(8, r.top - ht - 4) : r.bottom + 4) + 'px';
  }
  function closeMenu() { const m = $('#menu'); if (!m.hidden) { m.hidden = true; m.innerHTML = ''; } menuAnchor = null; }
  function ask({ title, body, ok = 'Confirm', danger = false, cancel = 'Cancel' }) {
    return new Promise(res => {
      const m = $('#modal');
      m.innerHTML = `<div class="modal-card" role="dialog" aria-modal="true" aria-label="${h(title)}"><h3>${h(title)}</h3><div class="modal-body">${body}</div><div class="modal-actions"><button class="btn ghost" data-m="0">${h(cancel)}</button><button class="btn ${danger ? 'danger' : 'primary'}" data-m="1">${h(ok)}</button></div></div>`;
      m.hidden = false;
      const done = v => { m.hidden = true; m.innerHTML = ''; document.removeEventListener('keydown', kd, true); m.onclick = null; res(v); };
      const kd = e => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); done(false); } else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); done(true); } };
      document.addEventListener('keydown', kd, true);
      m.onclick = e => { const b = e.target.closest('[data-m]'); if (b) done(b.dataset.m === '1'); else if (e.target === m) done(false); };
      m.querySelector('[data-m="1"]').focus();
    });
  }
  // several answers: resolves { v, picked } (picked = checked [data-pick] boxes in the body) or null for "decide later"/Esc
  function choose({ title, body, options, cancel = 'Cancel' }) {
    return new Promise(res => {
      const m = $('#modal');
      // options with a description (desc: trusted HTML) show as a list of full-width choices instead of a button row
      const list = options.some(o => o.desc);
      const choices = list ? `<div class="choices">${options.map(o => `<button class="choice${o.kind === 'primary' ? ' rec' : ''}" data-m="${h(o.v)}"><b>${h(o.label)}${o.kind === 'primary' ? '<em class="rec-tag">Recommended</em>' : ''}</b>${o.desc ? `<span>${o.desc}</span>` : ''}</button>`).join('')}</div>` : '';
      const acts = list ? `<span class="spacer"></span><button class="btn ghost" data-m="">${h(cancel)}</button>`
        : `<button class="btn ghost" data-m="">${h(cancel)}</button><span class="spacer"></span>${options.map(o => `<button class="btn ${o.kind || ''}" data-m="${h(o.v)}"${o.disabled ? ' disabled' : ''}>${h(o.label)}</button>`).join('')}`;
      m.innerHTML = `<div class="modal-card wide" role="dialog" aria-modal="true" aria-labelledby="m-title"><h3 id="m-title">${h(title)}</h3><div class="modal-body">${body}${choices}</div><div class="modal-actions">${acts}</div></div>`;
      m.hidden = false;
      const done = v => { const picked = [...m.querySelectorAll('[data-pick]:checked')].map(x => x.dataset.pick); m.hidden = true; m.innerHTML = ''; document.removeEventListener('keydown', kd, true); m.onclick = null; m.onchange = null; res(v ? { v, picked } : null); };
      const kd = e => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); done(''); } };
      document.addEventListener('keydown', kd, true);
      m.onclick = e => { const b = e.target.closest('button[data-m]'); if (b) done(b.dataset.m); else if (e.target === m) done(''); };
      // when picking items, the main button follows how many are ticked
      m.onchange = () => { const n = m.querySelectorAll('[data-pick]:checked').length, b = m.querySelector('.btn.primary'); if (b && m.querySelector('[data-pick]')) b.disabled = !n; };
      const first = m.querySelector('.choice.rec') || m.querySelector('.choice') || m.querySelector('.modal-actions .btn.primary') || m.querySelector('.modal-actions .btn:not(.ghost)');
      if (first) first.focus();
    });
  }
  // act: optional { label, act, data } button that runs a normal data-act action and closes the toast
  function toast(title, msg, kind, ms, act) {
    const el = document.createElement('div');
    el.className = 'toast ' + (kind || '');
    const btn = act ? `<button class="btn sm" data-act="${h(act.act)}" data-toast="1" ${Object.entries(act.data || {}).map(([k, v]) => `data-${k}="${h(v)}"`).join(' ')}>${h(act.label)}</button>` : '';
    el.innerHTML = `<div class="tx"><b>${h(title)}</b>${msg ? h(msg) : ''}${btn ? `<div class="toast-act">${btn}</div>` : ''}</div><button class="icon-btn" data-act="toast-close" aria-label="Dismiss" style="width:26px;height:26px">${ic('x')}</button>`;
    $('#toasts').appendChild(el);
    setTimeout(() => el.remove(), ms || 7000);
  }

  // ---------- actions ----------
  async function getFile(modId, fileId, name) {
    try { await api('/api/get', { modId: +modId, fileId: +fileId, name: name || undefined }); toast('Download page opened', `In ${browserName()}: click "Slow download". cpmods installs it when it arrives.`, '', 6000); }
    catch (e) { toast('Could not open the download page', e.message, 'bad'); }
  }
  async function queueAdd(items, start) {
    try {
      const r = await api('/api/queue', { op: 'add', items, start: !!start });
      await refreshState();
      if (start && r.opened) toast('Queue started', `Download page opened for ${r.opened}. Click "Slow download"; the next page follows automatically.`, 'ok', 9000);
      else toast('Added to queue', items.length === 1 ? `${items[0].name}. Start it from the bar at the bottom.` : r.result, 'ok', 5000);
    } catch (e) { toast('Could not add to queue', e.message, 'bad'); }
  }
  async function queueOp(body) {
    try { const r = await api('/api/queue', body); if (r.opened) toast('Download page opened', `${r.opened}: click "Slow download" in ${browserName()}.`, '', 6000); else if (body.op === 'next') toast('The queue is empty', '', '', 3000); await refreshState(); }
    catch (e) { toast('Queue', e.message, 'bad'); }
  }
  async function action(body, msg) {
    try { const r = await api('/api/action', body); if (msg) toast(msg, 'Progress shows in the bar at the bottom.', '', 3500); await refreshState(); return r || true; }
    catch (e) { toast('That did not work', e.message, 'bad', 10000); return null; }
  }
  async function saveSettings(ch, resetBrowse) {
    try { await api('/api/settings', ch); if (resetBrowse) { S.b.loaded = false; S.b.items = []; S.b.seq++; } await refreshState(); toast('Saved', '', 'ok', 2000); }
    catch (e) { toast('Could not save', e.message, 'bad'); }
  }
  // before launching: point out high-risk conflicts once (setting "Warn before launching")
  async function playCheck() {
    const s = S.st && S.st.settings, c = S.lib.compat;
    if (!s || s.warnRisk === false || !c || !c.issues) return true;
    const hi = c.issues.filter(crashy);
    if (!hi.length) return true;
    return ask({ title: 'Launch anyway?', body: `The compatibility check found ${plural(hi.length, 'problem')} that can crash the game:<ul class="ask-list">${hi.slice(0, 5).map(i => `<li>${h(i.title)}</li>`).join('')}</ul>Launching does not harm your files, but these mods may not work or may crash the game.`, ok: 'Launch anyway', cancel: 'Not now' });
  }
  async function sys(op, extra) {
    if (op === 'quit' && !await ask({ title: 'Quit cpmods?', body: 'Running downloads finish first. Reopen it from the "Cyberpunk Mods" shortcut.', ok: 'Quit', danger: true })) return;
    if (op === 'play' && !await playCheck()) return;
    try {
      await api('/api/system', Object.assign({ op }, extra || {}));
      if (op === 'register') { toast('Download links now open cpmods', '', 'ok'); refreshState(); }
      if (op === 'play') { const direct = extra && extra.mode ? extra.mode === 'direct' : S.st.settings.launchMode === 'direct'; toast('Starting Cyberpunk 2077', direct ? 'Directly from Cyberpunk2077.exe.' : 'Through Steam.', '', 4000); }
      if (op === 'quit') { S.offline = true; renderBanner(); setTimeout(() => window.close(), 400); }
    } catch (e) { toast(op === 'play' ? 'Could not start the game' : 'Failed', e.message, 'bad', 12000); }
  }
  const sysQuiet = (body, fail) => api('/api/system', body).catch(e => toast(fail || 'Could not open it', e.message, 'bad', 8000));
  function playMenuItems() {
    const g = S.st && S.st.game, items = [];
    if (g && !g.running) {
      items.push({ label: 'Play through Steam', act: 'play-mode', data: { mode: 'steam' }, icon: 'play' }, { label: 'Play directly (Cyberpunk2077.exe)', act: 'play-mode', data: { mode: 'direct' }, icon: 'play' });
      if (!S.st.vanilla) items.push({ label: 'Play without mods (once)', act: 'vanilla-start', icon: 'play' });
      items.push('-');
    }
    if (gameProcs().length) items.push({ label: 'Force close the game', act: 'kill', icon: 'stop', danger: true }, '-');
    items.push({ label: 'Game folders', act: 'game-at', data: { k: 'folders' }, icon: 'folder' });
    items.push('-', { label: 'Last launch report', act: 'go', data: { page: 'reports' }, icon: 'reports' }, { label: 'Find the problem mod', act: 'bisect-open', icon: 'bug' }, { label: 'Copy my saves now', act: 'bk-saves-now', icon: 'save' }, { label: 'Backups and restore points', act: 'tool', data: { tool: 'backups' }, icon: 'history' }, { label: 'Verify game files (Steam)', act: 'steam', data: { what: 'validate' }, icon: 'shield' }, { label: 'Launch settings', act: 'game-at', data: { k: 'launch' }, icon: 'gear' });
    return items;
  }
  // force-closes the game, or what is left of it (crash reporter, launcher) when Steam still says "Running"
  async function killGame() {
    const procs = gameProcs(), game = procs.includes('Cyberpunk2077');
    if (!procs.length) { toast('Nothing to close', 'The game is not running.', '', 3000); return; }
    const names = procs.map(x => PROC_LABEL[x] || x);
    const ok = await ask(game ? { title: 'Force close the game?', body: 'Cyberpunk 2077 closes right away and anything since your last save is lost. Use this when the game froze or will not close.', ok: 'Force close', danger: true }
      : { title: 'Close what is left of the game?', body: `Still open: <b>${h(names.join(', '))}</b>. While it runs, Steam counts the game as running and will not start it again.`, ok: 'Close it', danger: true });
    if (!ok) return;
    S.killedAt = Date.now();
    try {
      const r = await api('/api/system', { op: 'kill' }), left = arr(r.left);
      toast(left.length ? 'Some of it is still open' : 'Game closed', left.length ? left.map(x => PROC_LABEL[x] || x).join(', ') + ' did not close. It may need administrator rights.' : 'Everything that belonged to the game is closed.', left.length ? 'warn' : 'ok', 6000);
    } catch (e) { toast('Could not close the game', e.message, 'bad', 10000); }
    await refreshState();
  }
  async function saveKey() {
    const inp = $('#s-key'), key = inp ? inp.value.trim() : '';
    if (!key) { toast('Paste your key first', 'Get it from the Nexus page with the button next to the field.', 'warn', 5000); return; }
    try { const r = await api('/api/key', { key }); inp.value = ''; toast('API key saved', `Nexus account ${r.name}${r.premium ? ' (premium)' : ''}.`, 'ok', 5000); await refreshState(); if (S.page === 'settings') renderPage(); }
    catch (e) { toast('Key not saved', e.message, 'bad', 10000); }
  }
  async function steamOp(what) {
    if (what === 'validate' && !await ask({ title: 'Verify game files?', body: 'Steam checks the game\'s own files and re-downloads damaged or missing ones. Files in mod folders stay, but any original game file that a mod replaced is put back, which can switch that mod off.', ok: 'Open Steam' })) return;
    sysQuiet({ op: 'steam', what }, 'Could not open Steam');
  }
  async function bisectStart() {
    const p = S.pane;
    if (!p || p.kind !== 'bisect') return;
    const names = bisectCandidates().filter(m => p.sel && p.sel[m.name]).map(m => m.name);
    if (!names.length) return;
    if (S.st.game.running) { toast('Close the game first', 'Mods cannot be switched while it runs.', 'warn', 5000); return; }
    if (!await ask({ title: `Turn off ${plural(names.length, 'mod')}?`, body: 'Their files are set aside, not deleted. Then launch the game and answer on the Reports page. You can stop at any time: everything is turned back on.', ok: 'Start' })) return;
    try { await api('/api/bisect', { op: 'start', names }); toast('Troubleshooting started', 'Turning the mods off. Launch the game when it is done.', 'ok', 6000); await refreshState(); go('reports'); }
    catch (e) { toast('Could not start', e.message, 'bad', 10000); }
  }
  async function bisectResult(ok) {
    try { await api('/api/bisect', { op: 'result', ok }); toast(ok ? 'Noted: it worked' : 'Noted: the problem happened', 'Switching mods for the next round.', '', 4000); await refreshState(); }
    catch (e) { toast('Could not save the answer', e.message, 'bad', 10000); }
  }
  async function bisectStop(keep) {
    const bs = S.st.bisect;
    const body = keep ? `<b>${h(bs.culprit)}</b> stays off; every other mod cpmods switched off comes back.` : 'Every mod cpmods switched off for troubleshooting is turned back on.';
    if (!await ask({ title: keep ? 'Finish troubleshooting?' : 'Turn everything back on?', body, ok: keep ? 'Finish' : 'Turn back on' })) return;
    try { await api('/api/bisect', { op: 'stop', keep }); await refreshState(); }
    catch (e) { toast('Could not stop', e.message, 'bad', 10000); }
  }
  async function compatIgnore(key, on) {
    try {
      await api('/api/compat', { op: 'ignore', key, on });
      if (S.lib.compat && S.lib.compat.issues) S.lib.compat.issues.forEach(i => { if (i.key === key) i.ignored = on; });
      if (S.page === 'compat') renderPage();
      if (S.page === 'library') { renderLibSum(); renderLibList(); }
      renderNav();
      toast(on ? 'Marked as fine' : 'Counted again', '', 'ok', 2000);
    } catch (e) { toast('Could not save', e.message, 'bad'); }
  }
  // the game just closed: refresh the report and say how it went
  async function onGameExit() {
    // a launch without mods writes no mod logs: the report would describe the launch before it
    if (S.vanillaRun) { S.vanillaRun = false; toast('Game closed', 'Bringing your mods back.', '', 6000); return; }
    await new Promise(r => setTimeout(r, 2500));
    await loadLaunch(true);
    const d = S.launch.data, s = d && d.session, bs = S.st && S.st.bisect;
    if (bs && bs.active && bs.phase !== 'done') { toast('Game closed', 'Tell cpmods whether the problem happened.', 'warn', 20000, { label: 'Answer', act: 'go', data: { page: 'reports' } }); return; }
    if (!s || (S.st.settings && S.st.settings.reportOnExit === false) || Date.now() - S.killedAt < 30000) return;
    const n = (d.issues || []).filter(i => i.level === 'bad' || i.level === 'warn').length;
    const title = s.result === 'crash' ? 'The game crashed' : s.result === 'clean' ? 'Game closed normally' : 'The game stopped';
    const msg = s.result === 'crash' && s.crash ? `${s.crash.when}${s.crash.moduleMod ? ', inside ' + s.crash.moduleMod : ''}.` : n ? `${plural(n, 'thing')} to check in the launch report.` : 'Every mod loaded without errors.';
    toast(title, msg, s.result === 'crash' ? 'bad' : n ? 'warn' : 'ok', 15000, { label: 'See report', act: 'go', data: { page: 'reports' } });
  }
  async function exportModList() {
    try {
      const r = await api('/api/modlist'), a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([JSON.stringify(r, null, 2)], { type: 'application/json' }));
      a.download = 'cpmods-modlist.json'; document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 5000);
      toast('Mod list saved to Downloads', `${r.mods.length} Nexus mods. A friend opens it in Downloads, Modpacks.`, 'ok', 8000);
    } catch (e) { toast('Could not export', e.message, 'bad'); }
  }
  // a mod list file goes through the same checks and choices as a modpack code
  async function importModList(file) {
    let j;
    try { j = JSON.parse(await file.text()); } catch (e) { toast('Could not import', 'This is not a cpmods mod list file.', 'bad'); return; }
    packFlow({ list: j });
  }
  async function makePackage(appOnly) {
    toast('Creating share package', '', '', 2500);
    try { const r = await api('/api/system', { op: 'package', appOnly: !!appOnly, settings: !!S.shareSettings }); toast('Share package created', `${r.path} (its folder is open).`, 'ok', 12000); }
    catch (e) { toast('Could not create the package', e.message, 'bad'); }
  }
  async function loadVariant(archive, name) {
    S.dl.variant = { archive, name, loading: true, sub: null }; renderDlBody();
    try { const r = await api('/api/archive?file=' + encodeURIComponent(archive)); Object.assign(S.dl.variant, { loading: false, candidates: r.candidates || [], fomod: !!r.fomod }); }
    catch (e) { Object.assign(S.dl.variant, { loading: false, error: e.message }); }
    if (S.page === 'downloads') renderDlBody();
  }
  function findItem(name) { return libItems().find(m => m.name === name); }
  async function removeMod(name) {
    const m = findItem(name);
    if (!m) return;
    const adopted = /^adopted/.test(m.source || '');
    const body = !m.on ? `Forget <b>${h(name)}</b>? It is disabled; its set-aside files are deleted${adopted ? ' (sent to the Recycle Bin)' : ''}.`
      : adopted ? `<b>${h(name)}</b> was installed before cpmods, so its files go to the <b>Recycle Bin</b>. You can restore them from there.`
        : `The files of <b>${h(name)}</b> are deleted from the game folder, and any game files it replaced are restored. To keep it for later, use the switch to disable it instead.`;
    if (await ask({ title: `Remove ${name}?`, body, ok: 'Remove', danger: true })) action({ op: 'remove', name }, `Removing ${name}`);
  }

  // ---------- installs that need a choice: another mod already installed some of the same files ----------
  async function chooseConflict(archive) {
    const list = needChoice(), p = list.find(x => x.archive === archive) || list[0];
    if (!p) return;
    const cf = arr(p.conflict), by = {};
    cf.forEach(c => arr(c.owners).forEach(o => { (by[o] = by[o] || []).push(c.path); }));
    const owners = Object.keys(by);
    // combining is offered when every shared file can be merged (game JSON files both mods edited)
    const canMerge = cf.every(c => c.merge), clashes = [...new Set(cf.flatMap(c => arr(c.merge && c.merge.clashes)))];
    const nm = short(p.name, 30), old = owners.length === 1 ? short(owners[0], 30) : 'the other mods';
    const body = `<p style="margin-top:0"><b>${h(p.name)}</b> has ${plural(cf.length, 'file')} that ${owners.length === 1 ? `<b>${h(owners[0])}</b> already installed` : 'other mods already installed'}. The game can only use one copy of each file.</p>
      ${owners.map(o => `<div class="cf-owner"><b>${h(o)}</b><ul class="cf-files">${by[o].slice(0, 5).map(x => `<li class="mono-path">${h(x)}</li>`).join('')}${by[o].length > 5 ? `<li class="dim">and ${by[o].length - 5} more</li>` : ''}</ul></div>`).join('')}`;
    const options = [
      canMerge && { v: 'merge', label: 'Combine both', kind: 'primary', desc: `One file with the changes of both mods.${clashes.length ? ` Where both change the same setting, ${h(nm)}'s value is used: <span class="mono-path">${h(clashes.slice(0, 4).join(', '))}</span>${clashes.length > 4 ? ` and ${clashes.length - 4} more` : ''}.` : ' They change different settings, so nothing is lost.'} Removing either mod later gives the other its own copy back.` },
      { v: 'overwrite', label: `Use ${nm}'s files`, kind: canMerge ? '' : 'primary', desc: `${h(nm)}'s copy replaces it. ${h(old)} gets its files back if you remove ${h(nm)} later.` },
      { v: 'keep', label: `Keep ${old}'s files`, desc: `${h(nm)} installs everything else and leaves these files alone.` },
      { v: 'skip', label: 'Don\'t install', desc: 'Nothing changes. The download stays in Downloads.' },
    ].filter(Boolean);
    const r = await choose({ title: `Install ${p.name}?`, body, cancel: 'Decide later', options });
    if (!r) return;
    if (r.v === 'skip') { action({ op: 'dismiss', name: p.name }); return; }
    action({ op: 'install', archive: p.archive, name: p.name, conflict: r.v }, `Installing ${p.name}`);
  }

  // ---------- profiles: named sets of mods to switch between ----------
  async function reloadProfiles() {
    const p = S.pane;
    if (!p || p.kind !== 'profiles') return;
    try { p.data = await api('/api/profiles'); p.error = null; } catch (e) { p.error = e.message; }
    if (S.pane === p) renderPane();
  }
  const profChanges = x => [[arr(x.off).length, 'off'], [arr(x.on).length, 'on'], [arr(x.install).length, 'reinstalled']].filter(c => c[0]).map(c => `${c[0]} ${c[1]}`).join(', ');
  function profilesPane(p) {
    return toolShell(p, 'Profiles', 'A profile remembers which mods are on. Switching turns mods off and on, and reinstalls ones you removed from their download. Versions stay as they are, frameworks stay on, and cpmods makes a restore point first.', () => {
      const list = arr(p.data.profiles), busy = S.st.jobs.some(j => j.kind === 'profile' && j.status === 'running'), run = S.st.game.running;
      const save = `<div class="keyrow prof-new"><input type="text" id="prof-name" maxlength="60" spellcheck="false" placeholder="A name for the mods on now, like Story or Photo mode" aria-label="Profile name"><button class="btn sm primary" data-act="prof-save">${ic('plus')}Save as a profile</button></div>`;
      if (!list.length) return save + '<div class="card"><div class="empty"><h3>No profiles yet</h3>Save the mods that are on now as a profile. Change your mods, save another one, then switch between them with one click.</div></div>';
      return save + `<div class="card"><div class="list">${list.map(x => {
        const ch = profChanges(x), miss = arr(x.missing).length;
        const sub = x.inUse ? '<span class="pill ok">In use</span>' : `<span>${ch ? 'Switching: ' + h(ch) : 'Nothing to switch'}${miss ? ` &middot; ${plural(miss, 'mod')} cannot come back` : ''}</span>`;
        return `<div class="li bk-row"><span class="st-ic ${x.inUse ? 'ok' : 'muted'}">${ic(x.inUse ? 'check' : 'collections')}</span><div class="li-main"><div class="li-title"><span class="t">${h(x.name)}</span></div><div class="li-sub"><span>${plural(x.mods, 'mod')} on</span><span>saved ${h(fmtWhen(x.at))}</span>${sub}</div></div>
          <div class="li-acts">${x.inUse ? '' : `<button class="btn sm primary" data-act="prof-apply" data-name="${h(x.name)}"${busy || run || !ch ? ' disabled' : ''}${run ? ' title="Close the game first"' : ''}>Switch</button>`}<button class="btn sm ghost" data-act="prof-update" data-name="${h(x.name)}" title="Save the mods that are on now into this profile">Update</button><button class="icon-btn" data-act="prof-del" data-name="${h(x.name)}" title="Delete this profile" aria-label="Delete the profile ${h(x.name)}">${ic('x')}</button></div></div>`;
      }).join('')}</div></div>${busy ? '<div class="helper"><span class="spin"></span> Switching mods; progress shows in the bar at the bottom.</div>' : ''}`;
    });
  }
  async function profSave(name, replace) {
    name = String(name || '').trim();
    if (!name) { toast('Name the profile first', 'For example Story or Photo mode.', 'warn', 4000); return; }
    const p = S.pane, exists = p && p.data && arr(p.data.profiles).some(x => x.name === name);
    if ((exists || replace) && !await ask({ title: `Update ${name}?`, body: `<b>${h(name)}</b> then holds the mods that are on now (${plural(stMods().length, 'mod')}).`, ok: 'Update' })) return;
    try {
      const r = await api('/api/profiles', { op: 'save', name });
      toast(`Profile ${r.name} saved`, plural(r.mods, 'mod') + ' on.', 'ok', 4000);
      const i = $('#prof-name'); if (i) i.value = '';
      await reloadProfiles(); refreshState();
    } catch (e) { toast('Could not save the profile', e.message, 'bad', 8000); }
  }
  async function profApply(name) {
    const x = arr(S.pane && S.pane.data && S.pane.data.profiles).find(y => y.name === name);
    if (!x) return;
    if (S.st.game.running) { toast('Close the game first', 'Mods cannot change while it runs.', 'warn', 5000); return; }
    const body = planGrp('Turned off', arr(x.off)) + planGrp('Turned back on', arr(x.on)) + planGrp('Installed again', arr(x.install)) + planGrp('Cannot come back', arr(x.missing).map(m => `${m.name}: ${m.why}`), 'bad-t') + '<p class="dim small">cpmods makes a restore point first, so you can go back.</p>';
    if (!await ask({ title: `Switch to ${name}?`, body, ok: 'Switch' })) return;
    try { await api('/api/profiles', { op: 'apply', name }); toast(`Switching to ${name}`, 'Progress shows in the bar at the bottom.', '', 4000); await refreshState(); if (S.pane && S.pane.kind === 'profiles') renderPane(); }
    catch (e) { toast('Could not switch', e.message, 'bad', 10000); }
  }
  async function profDelete(name) {
    if (!await ask({ title: `Delete the profile ${name}?`, body: 'Only the profile goes. Your mods stay as they are.', ok: 'Delete', danger: true })) return;
    try { await api('/api/profiles', { op: 'delete', name }); await reloadProfiles(); refreshState(); }
    catch (e) { toast('Could not delete it', e.message, 'bad', 8000); }
  }
  // ---------- modpacks: a code (or mod list file) with Nexus mods to get, or one made from yours ----------
  function packsPane(p) {
    return toolShell(p, 'Modpacks', 'A modpack code is a short line of letters and digits listing Nexus mods and their versions. Paste a friend\'s code to get their mods, or make one from the mods you have on. Mods you already have are skipped, and cpmods makes a restore point first.', () => {
      const busy = S.st.jobs.some(j => j.kind === 'pack' && j.status === 'running');
      return `<div class="card"><div class="card-head"><h3>Get a modpack</h3></div><div class="card-body">
          <textarea class="pack-code" id="pack-code" rows="4" spellcheck="false" autocomplete="off" placeholder="Paste a modpack code here, or the whole message with it. It starts with CPMODS" aria-label="Modpack code">${h(p.input || '')}</textarea>
          <div class="toolbar" style="margin-top:10px"><button class="btn sm primary" data-act="pack-check"${busy ? ' disabled' : ''}>See what it changes</button><button class="btn sm ghost" data-act="modlist-import">Use a mod list file instead</button><input type="file" id="ml-file" accept=".json,application/json" hidden></div>
          ${busy ? '<div class="helper"><span class="spin"></span> Getting a modpack; progress shows in the bar at the bottom.</div>' : ''}</div></div>
        <div class="card" style="margin-top:12px"><div class="card-head"><h3>Share your mods</h3></div><div class="card-body">
          <div class="keyrow prof-new"><input type="text" id="pack-name" maxlength="60" spellcheck="false" placeholder="A name for your modpack (optional)" aria-label="Modpack name" value="${h(p.name || '')}"><button class="btn sm primary" data-act="pack-make">Make a code</button></div>
          ${p.code ? `<textarea class="pack-code" id="pack-out" rows="4" readonly aria-label="Your modpack code">${h(p.code)}</textarea>
          <div class="toolbar" style="margin-top:10px"><button class="btn sm primary" data-act="pack-copy">Copy the code</button><button class="btn sm ghost" data-act="pack-copy" data-long="1" title="Also lists each file's mod, so it does not need Nexus to find them. Works with cpmods 1.4.0 too.">Copy the long code</button><span class="dim small">${plural(p.count, 'mod')}, ${p.code.length} characters (long code: ${p.long.length}).${p.code.length > 2000 ? ' Discord sends a code this long as a file: your friend opens it and copies the text.' : ''}</span></div>`
          : '<p class="dim small" style="margin:0">The code lists the Nexus mods you have on, with their versions. Frameworks are left out: cpmods installs them by itself.</p>'}
          <div class="toolbar" style="margin-top:10px"><button class="btn sm ghost" data-act="modlist-export">Save as a file instead</button></div></div></div>`;
    });
  }
  // src: { code } or { list } (a mod list file). Shows what changes, asks about other versions, then gets the mods
  async function packFlow(src) {
    let pl;
    toast('Reading the modpack', 'Looking up its mods on Nexus.', '', 2500);
    try { pl = await api('/api/pack', Object.assign({ op: 'plan' }, src)); }
    catch (e) { toast('Could not read the modpack', e.message, 'bad', 10000); return; }
    const nw = arr(pl.new), on = arr(pl.turnOn), v = arr(pl.versions), fw = arr(pl.frameworks), have = arr(pl.have), gone = arr(pl.gone);
    if (!nw.length && !on.length && !v.length && !fw.length) { toast('Nothing to get', gone.length ? `You have the rest; ${plural(gone.length, 'mod')} of it no longer on Nexus.` : `You already have all ${plural(pl.total, 'mod')} of this modpack.`, 'ok', 6000); return; }
    if (S.st.game.running) { toast('Close the game first', 'Mods cannot change while it runs.', 'warn', 5000); return; }
    // other versions: by default yours is updated where the pack has a newer file, never downgraded
    const up = v.filter(x => x.newer), many = v.length > 1;
    const vrows = v.length ? `<div class="bk-grp"><b>You have another version (${v.length})</b><div class="list">${v.map(x => `<label class="li check-row">${many ? `<input type="checkbox" class="check" data-pick="${h(x.name)}"${x.newer ? ' checked' : ''}>` : ''}<div class="li-main"><div class="li-title"><span class="t">${h(x.name)}</span>${x.newer ? '<span class="pill ok">newer in the pack</span>' : x.older ? '<span class="pill">older in the pack</span>' : ''}${x.on ? '' : '<span class="pill">off</span>'}</div><div class="li-sub"><span>yours ${h(x.mine || '?')}, the pack's ${h(x.pack || '?')}</span>${x.back ? '' : '<span class="bad-t">yours has no download left: replacing it cannot be undone</span>'}</div></div></label>`).join('')}</div></div>` : '';
    const body = (pl.game ? `<p class="dim small" style="margin-top:0">Made with game version ${h(pl.game)}.</p>` : '')
      + planGrp(`Downloaded (${nw.length})`, nw.map(m => m.name)) + planGrp('Turned back on', on) + planGrp('Frameworks installed', fw) + vrows
      + planGrp(`No longer on Nexus, skipped (${gone.length})`, gone, 'bad-t')
      + `<p class="dim small">${have.length ? `You already have ${plural(have.length, 'mod')} of it. ` : ''}Before anything changes, cpmods makes a restore point and a backup of your mod settings (Library, Backups), and it keeps the downloads of replaced versions, so you can go back. Each download needs one "Slow download" click on Nexus; the next page opens by itself.</p>`;
    const options = [];
    if (!v.length) options.push({ v: 'keep', label: 'Get the modpack', desc: [plural(nw.length, 'download'), on.length ? `${on.length} turned back on` : '', fw.length ? plural(fw.length, 'framework') : ''].filter(Boolean).join(', ') + '.' });
    else {
      if (up.length) options.push({ v: 'update', label: 'Update my mods', kind: 'primary', desc: `The pack's newer version for ${plural(up.length, 'mod')}.${up.length < v.length ? ` Where yours is newer (${v.length - up.length}), yours stays.` : ''}` });
      options.push({ v: 'keep', label: many ? 'Keep my versions' : 'Keep my version', kind: up.length ? '' : 'primary', desc: many ? 'None of yours is replaced.' : 'Yours stays as it is.' });
      if (up.length < v.length) options.push({ v: 'pack', label: many ? 'Use the pack\'s versions' : 'Use the pack\'s version', desc: 'Also where the pack has an older version than yours.' });
      if (many) options.push({ v: 'picked', label: 'Only the ticked mods', desc: 'The ticked mods above get the pack\'s version; the others keep yours.' });
    }
    const r = await choose({ title: pl.name ? `Get the modpack ${pl.name}?` : 'Get this modpack?', body, options });
    if (!r) return;
    const use = r.v === 'update' ? up.map(x => x.name) : r.v === 'pack' ? v.map(x => x.name) : r.v === 'picked' ? r.picked : [];
    if (!nw.length && !on.length && !fw.length && !use.length) { toast('Nothing changes', 'You kept your versions and already have the rest.', 'ok', 6000); return; }
    try {
      await api('/api/pack', Object.assign({ op: 'apply', use }, src));
      toast('Getting the modpack', 'Progress shows in the bar at the bottom.', '', 5000);
      await refreshState();
      if (S.pane && S.pane.kind === 'packs') renderPane();
    } catch (e) { toast('Could not get the modpack', e.message, 'bad', 10000); }
  }
  async function packMake() {
    const p = S.pane;
    if (!p || p.kind !== 'packs') return;
    try { const r = await api('/api/pack', { op: 'make', name: ($('#pack-name') || {}).value || '' }); p.code = r.code; p.long = r.long; p.count = r.count; renderPane(); }
    catch (e) { toast('Could not make a code', e.message, 'bad', 8000); }
  }
  async function packCopy(long) {
    const t = $('#pack-out'), p = S.pane;
    if (!t || !p) return;
    try { await navigator.clipboard.writeText(long ? p.long : p.code); toast(long ? 'Long code copied' : 'Code copied', 'Your friend pastes it in cpmods: Downloads, Modpacks.', 'ok', 5000); }
    catch (e) { t.value = long ? p.long : p.code; t.focus(); t.select(); toast('Press Ctrl+C to copy', 'The code is selected.', '', 5000); }
  }

  // groups of mod names in a "what changes" list (restore points, profiles, modpacks)
  const planGrp = (title, items, cls) => items.length ? `<div class="bk-grp"><b class="${cls || ''}">${title}</b><div class="mchips">${items.map(t => `<span class="mchip sm static">${h(t)}</span>`).join('')}</div></div>` : '';

  // ---------- backups: restore points, save copies, mod settings ----------
  const POINT_KIND ={ clean: ['ok', 'check', 'Known good'], auto: ['muted', 'history', 'Automatic'], manual: ['info', 'pin', 'Made by you'] };
  async function reloadBackups() {
    const p = S.pane;
    if (!p || p.kind !== 'backups') return;
    try { p.data = await api('/api/backups'); p.error = null; p.plans = {}; } catch (e) { p.error = e.message; }
    if (S.pane === p) renderPane();
  }
  function backupsPane(p) {
    return toolShell(p, 'Backups', 'Ways back when something goes wrong: restore points for your mod setup, copies of your saves, and your mod settings.', () => {
      const d = p.data, tab = p.tab || 'points';
      const tabs = [['points', 'Restore points', d.points.length], ['saves', 'Saves', d.saves.length], ['settings', 'Mod settings', d.settings.length]];
      return `<div class="seg bk-tabs" role="tablist" aria-label="Backups">${tabs.map(([v, l, n]) => `<button data-act="bk-tab" data-v="${v}" class="${tab === v ? 'on' : ''}" role="tab" aria-selected="${tab === v}">${l} <span class="n">${n}</span></button>`).join('')}</div>`
        + ({ points: bkPoints, saves: bkSaves, settings: bkSettings }[tab] || bkPoints)(p, d, S.st.settings);
    });
  }
  function bkPoints(p, d, s) {
    const bar = `<div class="bk-bar"><p class="dim small">${s.autoRestore !== false ? 'Made by cpmods before installs, removals and switches, and after a launch that closed normally.' : 'Automatic restore points are off in Settings.'}</p><button class="btn sm primary" data-act="bk-point">${ic('plus')}Make one now</button></div>`;
    if (!d.points.length) return bar + '<div class="card"><div class="empty"><h3>No restore points yet</h3>cpmods makes the first one before your next install or removal.</div></div>';
    return bar + `<div class="card"><div class="list">${d.points.map(x => {
      const k = POINT_KIND[x.kind] || POINT_KIND.auto, diff = x.added + x.gone + x.changed, open = p.open === x.id;
      const since = diff ? [x.added ? `${x.added} added` : '', x.gone ? `${x.gone} gone` : '', x.changed ? `${x.changed} changed` : ''].filter(Boolean).join(', ') + ' since then' : 'Same as now';
      return `<div class="li bk-row${open ? ' open' : ''}"><span class="st-ic ${k[0]}" title="${k[2]}">${ic(k[1])}</span><div class="li-main"><div class="li-title"><span class="t">${h(x.label || k[2])}</span></div><div class="li-sub"><span>${h(fmtWhen(x.at))}</span><span>${plural(x.mods, 'mod')} on</span><span class="${diff ? 'warn-t' : ''}">${h(since)}</span></div>${open ? planHtml(p, x) : ''}</div>
        <div class="li-acts"><button class="btn sm" data-act="bk-plan" data-id="${h(x.id)}" aria-expanded="${open}">${open ? 'Hide' : 'Go back...'}</button><button class="icon-btn" data-act="bk-del" data-what="point" data-id="${h(x.id)}" title="Delete this restore point" aria-label="Delete this restore point">${ic('x')}</button></div></div>`;
    }).join('')}</div></div>`;
  }
  function planHtml(p, x) {
    const pl = p.plans && p.plans[x.id];
    if (!pl) return '<div class="bk-plan"><span class="spin"></span> Working out what would change</div>';
    if (pl.error) return `<div class="bk-plan err">${h(pl.error)}</div>`;
    const grp = planGrp;
    const n = arr(pl.off).length + arr(pl.on).length + arr(pl.install).length + arr(pl.version).length;
    return `<div class="bk-plan">${!n && !arr(pl.missing).length ? '<p class="dim small" style="margin:0">Nothing to change: your mods are already like this.</p>'
      : grp('Turned off', arr(pl.off)) + grp('Turned back on', arr(pl.on)) + grp('Installed again', arr(pl.install)) + grp('Back to an older version', arr(pl.version).map(v => `${v.name} ${v.from} → ${v.to}`)) + grp('Cannot come back', arr(pl.missing).map(m => `${m.name}: ${m.why}`), 'bad-t')}
      ${n ? `<div class="toolbar" style="margin-top:10px"><button class="btn sm primary" data-act="bk-restore" data-id="${h(x.id)}">${ic('undo')}Go back to this point</button><span class="dim small">${plural(pl.same, 'mod')} stay as they are.</span></div>` : ''}</div>`;
  }
  function bkSaves(p, d, s) {
    const bar = `<div class="bk-bar"><p class="dim small">${s.saveBackup !== false ? `Copied before a launch when your mods changed; the newest ${s.saveKeep || 5} copies are kept.` : 'Automatic copies are off in Settings.'} Copies only: your saves are never moved.</p><button class="btn sm primary" data-act="bk-saves-now">${ic('save')}Copy saves now</button></div>`;
    if (!d.saves.length) return bar + `<div class="card"><div class="empty"><h3>No save copies yet</h3>The first copy is made before your next launch with changed mods.<br><span class="mono-path">${h(d.savesDir)}</span></div></div>`;
    return bar + `<div class="card"><div class="list">${d.saves.map(x => `<div class="li bk-row"><span class="st-ic muted">${ic('save')}</span><div class="li-main"><div class="li-title"><span class="t">${h(fmtWhen(x.at))}</span></div><div class="li-sub"><span>${h(x.reason || '')}</span><span>${plural(arr(x.saves).length, 'save')}</span><span>${fmtSize(x.size)}</span></div></div>
      <div class="li-acts"><button class="btn sm" data-act="bk-saves-restore" data-id="${h(x.id)}">Restore...</button><button class="icon-btn" data-act="bk-open" data-id="${h(x.id)}" title="Open this copy's folder" aria-label="Open this copy's folder">${ic('folder')}</button><button class="icon-btn" data-act="bk-del" data-what="saves" data-id="${h(x.id)}" title="Delete this copy" aria-label="Delete this copy">${ic('x')}</button></div></div>`).join('')}</div></div>`;
  }
  function bkSettings(p, d) {
    const bar = `<div class="bk-bar"><p class="dim small">What mods write for themselves (CET mods, Mod Settings, plugin options, CET hotkeys) and config files you edited. Backed up with every automatic restore point.</p><span class="btn-pair"><button class="btn sm primary" data-act="bk-set-now">${ic('plus')}Back up now</button><button class="btn sm" data-act="bk-set-import" title="A mod-settings.zip from a friend's share package">Import file</button></span><input type="file" id="bk-file" accept=".zip,application/zip" hidden></div>`;
    if (!d.settings.length) return bar + '<div class="card"><div class="empty"><h3>No settings backups yet</h3>The first one is made with your next automatic restore point.</div></div>';
    const KINDS = { auto: 'Automatic', manual: 'Made by you', imported: 'Imported' };
    return bar + `<div class="card"><div class="list">${d.settings.map(x => `<div class="li bk-row"><span class="st-ic muted">${ic('gear')}</span><div class="li-main"><div class="li-title"><span class="t">${h(fmtWhen(x.at))}</span><span class="pill">${h(KINDS[x.kind] || x.kind)}</span></div><div class="li-sub"><span>${h(x.reason || '')}</span><span>${plural(x.count, 'file')}</span><span>${fmtSize(x.size)}</span></div></div>
      <div class="li-acts"><button class="btn sm" data-act="bk-set-restore" data-id="${h(x.id)}">Restore...</button><button class="icon-btn" data-act="bk-del" data-what="settings" data-id="${h(x.id)}" title="Delete this backup" aria-label="Delete this backup">${ic('x')}</button></div></div>`).join('')}</div></div>`;
  }
  async function bkPlan(id) {
    const p = S.pane;
    if (!p || p.kind !== 'backups') return;
    p.open = p.open === id ? null : id; p.plans = p.plans || {};
    renderPane();
    if (!p.open || p.plans[id]) return;
    try { p.plans[id] = await api('/api/restoreplan?id=' + encodeURIComponent(id)); } catch (e) { p.plans[id] = { error: e.message }; }
    if (S.pane === p) renderPane();
  }
  async function bkRestorePoint(id) {
    const p = S.pane, pl = p && p.plans && p.plans[id];
    if (!pl || pl.error) return;
    if (S.st.game.running) { toast('Close the game first', 'Mods cannot change while it runs.', 'warn', 5000); return; }
    const c = [[arr(pl.off).length, 'turned off'], [arr(pl.on).length, 'turned back on'], [arr(pl.install).length, 'installed again'], [arr(pl.version).length, 'back to an older version']].filter(x => x[0]).map(x => `${plural(x[0], 'mod')} ${x[1]}`);
    if (!await ask({ title: 'Go back to this restore point?', body: `${h(c.join(', '))}.${arr(pl.missing).length ? `<br>${plural(arr(pl.missing).length, 'mod')} cannot come back.` : ''}<br><br>Mods that get turned off keep their downloads, and a restore point of your current setup is made first, so you can return to it.`, ok: 'Go back' })) return;
    try { await api('/api/backups', { op: 'point-restore', id }); toast('Going back', 'Progress shows in the bar at the bottom.', '', 4000); p.plans = {}; p.open = null; await refreshState(); }
    catch (e) { toast('Could not go back', e.message, 'bad', 10000); }
  }
  async function bkOp(body, okMsg) {
    try { const r = await api('/api/backups', body); if (okMsg) toast(okMsg, '', 'ok', 3000); await reloadBackups(); return r || true; }
    catch (e) { toast('That did not work', e.message, 'bad', 10000); return null; }
  }
  async function bkDelete(what, id) {
    const label = { point: 'restore point', saves: 'copy of your saves', settings: 'settings backup' }[what];
    if (!label || !await ask({ title: `Delete this ${label}?`, body: what === 'saves' ? 'Only cpmods\' copy is deleted. Your saves in the game folder stay.' : 'Only this backup is deleted; your mods stay as they are.', ok: 'Delete', danger: true })) return;
    bkOp({ op: what + '-delete', id });
  }
  async function bkRestoreSaves(id) {
    const p = S.pane, x = p && p.data && p.data.saves.find(b => b.id === id);
    if (!x) return;
    if (S.st.game.running) { toast('Close the game first', 'Saves cannot be replaced while it runs.', 'warn', 5000); return; }
    const body = `<p style="margin-top:0">Tick the saves to put back. Your current versions of those saves are copied aside first, so this can be undone.</p><div class="pick-list">${arr(x.saves).map(sv => `<label class="pick"><input type="checkbox" class="check" data-pick="${h(sv.name)}" checked><span>${h(sv.name)}</span><span class="dim small">saved ${h(fmtWhen(sv.time))}</span></label>`).join('')}</div>`;
    const r = await choose({ title: `Restore saves copied ${fmtWhen(x.at)}?`, body, options: [{ v: 'go', label: 'Restore ticked saves', kind: 'primary' }] });
    if (!r || !r.picked.length) return;
    try { await api('/api/backups', { op: 'saves-restore', id, names: r.picked }); toast('Restoring saves', 'The current versions are copied aside first.', '', 4000); }
    catch (e) { toast('Could not restore', e.message, 'bad', 10000); }
  }
  async function bkRestoreSettings(id) {
    let pv;
    try { pv = await api('/api/settingsplan?id=' + encodeURIComponent(id)); } catch (e) { toast('Could not read the backup', e.message, 'bad', 8000); return; }
    const w = arr(pv.write), sk = arr(pv.skip);
    const body = `<p style="margin-top:0">${plural(w.length, 'file')} would be put back${sk.length ? `, ${sk.length} skipped` : ''}. Your current settings are backed up first.</p>${sk.length ? `<details class="old"><summary>Skipped (${sk.length})</summary><ul class="ask-list">${sk.slice(0, 12).map(x => `<li><span class="mono-path">${h(x.path)}</span>: ${h(x.why)}</li>`).join('')}</ul></details>` : ''}`;
    if (!w.length) { await ask({ title: 'Nothing to restore', body, ok: 'OK', cancel: 'Close' }); return; }
    if (S.st.game.running) { toast('Close the game first', 'Mods read their settings while it runs.', 'warn', 5000); return; }
    if (!await ask({ title: 'Restore mod settings?', body, ok: 'Restore' })) return;
    const r = await bkOp({ op: 'settings-restore', id });
    if (r) toast('Mod settings restored', `${plural(arr(r.write).length, 'file')} put back.`, 'ok', 5000);
  }
  async function bkImport(file) {
    if (!file) return;
    if (file.size > 50 * 1048576) { toast('That file is too big for a settings backup', '', 'bad'); return; }
    const buf = new Uint8Array(await file.arrayBuffer());
    let bin = '';
    for (let i = 0; i < buf.length; i += 32768) bin += String.fromCharCode.apply(null, buf.subarray(i, i + 32768));
    const r = await bkOp({ op: 'settings-import', data: btoa(bin) });
    if (r) toast('Settings file imported', `${plural(r.count, 'file')}.${r.code ? ` ${plural(r.code, 'mod code file')} (init.lua, .reds) left out: those are not settings.` : ''} Use Restore on it to apply them.`, 'ok', 9000);
  }

  // ---------- key bindings ----------
  const KEY_NAME = { LShift: 'Left Shift', RShift: 'Right Shift', LControl: 'Left Ctrl', RControl: 'Right Ctrl', LAlt: 'Left Alt', RAlt: 'Right Alt', LeftMouse: 'Left mouse', RightMouse: 'Right mouse', MiddleMouse: 'Middle mouse', MouseX1: 'Mouse 4', MouseX2: 'Mouse 5', MouseWheelUp: 'Wheel up', MouseWheelDown: 'Wheel down', Escape: 'Esc', Semicolon: '; ($ on AZERTY)', Tilde: '`', Comma: ',', Period: '.', Slash: '/', Minus: '-', Equals: '=', LeftBracket: '[', RightBracket: ']', Backslash: '\\', SingleQuote: '\'', PageUp: 'Page up', PageDown: 'Page down', CapsLock: 'Caps Lock' };
  const keyName = k => { const n = String(k).replace(/^IK_/, ''); return KEY_NAME[n] || n.replace(/^NumPad(\d)$/, 'Num $1'); };
  const actName = a => { const s = String(a || '').replace(/(_Button|_Axis)$/, '').replace(/_+/g, ' ').replace(/([a-z0-9])([A-Z])/g, '$1 $2').trim(); return s ? s[0].toUpperCase() + s.slice(1).toLowerCase() : ''; };
  const GAME_CTX = { Locomotion: 'on foot', General: 'general', Braindance: 'braindance', UI: 'menus', Vehicle: 'vehicles' };
  const KEY_SRC = { input: 'the mod\'s key file in r6\\input', modsettings: 'the Mod Settings menu in game', cet: 'the CET overlay, Bindings', game: 'the game\'s Settings, Controls' };
  function keysPane(p) {
    return toolShell(p, 'Key bindings', 'Keys your mods use, next to the game controls as you set them. Two mods on one key can both react; that is only fine when they work in different situations, like on foot and in a car.', () => {
      const d = p.data, c = d.counts;
      if (!p.filter) p.filter = c.clash ? 'clash' : 'mod';
      const head = c.clash ? callout('warn', `<b>${plural(c.clash, 'key')} used by two or more mods.</b> If one key does two things at once, change one of them where its tooltip says.`) : callout('ok', '<b>No two mods share a key.</b>');
      const seg = `<div class="toolbar" style="margin:12px 0"><div class="seg" role="group" aria-label="Show">${[['clash', 'Used by 2 mods', c.clash], ['mod', 'All mod keys', c.mod], ['all', 'Everything', d.keys.length]].map(([v, l, n]) => `<button data-act="keys-filter" data-v="${v}" class="${p.filter === v ? 'on' : ''}">${l} <span class="n">${n}</span></button>`).join('')}</div><div class="searchbar sm" style="flex:1;min-width:160px">${ic('search')}<input type="search" id="keys-q" placeholder="Key, mod or action" value="${h(p.q || '')}" aria-label="Filter keys"></div></div>`;
      const foot = `<p class="dim small" style="margin-top:12px">Where to change a key: game keys in the game's Settings, Controls. Mod Settings keys in its menu in game. CET hotkeys in the CET overlay, Bindings. Keys from key files only in that mod's file in r6\\input.${d.userSettings ? '' : ' The game\'s settings file was not found, so game keys are missing.'}</p>`;
      return head + seg + `<div id="keyrows">${keyRowsHtml(p)}</div>` + foot;
    });
  }
  function keyRowsHtml(p) {
    const d = p.data, q = String(p.q || '').trim().toLowerCase(), order = { clash: 0, shared: 1, mod: 2, game: 3 };
    let keys = d.keys.filter(k => p.filter === 'clash' ? k.state === 'clash' : p.filter === 'mod' ? k.state !== 'game' : true);
    if (q) keys = keys.filter(k => keyName(k.key).toLowerCase().includes(q) || arr(k.uses).some(u => `${u.who} ${actName(u.action)}`.toLowerCase().includes(q)));
    keys.sort((a, b) => order[a.state] - order[b.state] || keyName(a.key).localeCompare(keyName(b.key)));
    if (!keys.length) return '<div class="card"><div class="empty" style="padding:24px 16px">Nothing matches.</div></div>';
    return `<div class="card"><div class="list">${keys.map(k => {
      const mods = {}, game = [];
      arr(k.uses).forEach(u => {
        if (u.src === 'game') { game.push(u); return; }
        const m = mods[u.who] = mods[u.who] || { acts: new Set(), src: new Set() };
        m.acts.add(actName(u.action) + (u.ctx ? ` (${u.ctx})` : '')); m.src.add(KEY_SRC[u.src]);
      });
      const chips = Object.entries(mods).map(([who, m]) => `<span class="kuse" title="Change it in ${h([...m.src].join(' or '))}"><b>${h(who)}</b> ${h([...m.acts].slice(0, 2).join(', '))}${m.acts.size > 2 ? ` +${m.acts.size - 2}` : ''}</span>`).join('')
        + (game.length ? `<span class="kuse game" title="Change it in ${h(KEY_SRC.game)}"><b>Game</b> ${h(game.slice(0, 3).map(u => actName(u.action)).join(', '))}${game.length > 3 ? ` +${game.length - 3}` : ''}<em>${h([...new Set(game.map(u => GAME_CTX[u.ctx] || u.ctx))].join(', '))}</em></span>` : '');
      const pill = k.state === 'clash' ? `<span class="pill warn">${plural(arr(k.mods).length, 'mod')}</span>` : k.state === 'shared' ? '<span class="pill muted" title="A mod uses a key the game also uses, usually in another situation">Game key too</span>' : '';
      return `<div class="li key-row"><kbd class="keycap">${h(keyName(k.key))}</kbd><div class="li-main key-uses">${chips}</div>${pill}</div>`;
    }).join('')}</div></div>`;
  }

  // ---------- load order: let the losing archive win by renaming it ----------
  async function loWin(t) {
    try {
      const r = await api('/api/loadorder', { op: 'win', archive: t.dataset.archive, over: t.dataset.over });
      toast(`${t.dataset.mod} wins, as you chose`, r.name === t.dataset.archive ? 'It already loads first; cpmods remembers your choice.' : `Its archive is now ${r.name}. cpmods keeps that name after updates.`, 'ok', 9000, { label: 'Undo', act: 'lo-undo', data: { archive: r.name } });
      ensureCompat(true);
    } catch (e) { toast('Could not change the load order', e.message, 'bad', 10000); }
  }
  async function loUndo(archive) {
    try {
      await api('/api/loadorder', { op: 'undo', archive });
      toast('Choice undone', '', 'ok', 4000);
      ensureCompat(true);
    } catch (e) { toast('Could not undo', e.message, 'bad', 10000); }
  }

  // ---------- one launch without mods ----------
  async function vanillaStart() {
    const g = S.st && S.st.game;
    if (!g || g.running) { toast('The game is running', 'Close it first.', 'warn', 4000); return; }
    if (!await ask({ title: 'Play without mods, once?', body: 'cpmods sets your mods aside (moved to a folder inside the game folder, nothing is deleted), starts the game, and puts every mod back as soon as the game closes, along with your game settings (the game resets them when it starts without mods). Settings you change while playing without mods are not kept.<br><br>Use it to check whether a problem comes from a mod. Saving while playing without mods can drop items that mods added, so avoid saving over your main saves.', ok: 'Play without mods' })) return;
    try { await api('/api/vanilla', { op: 'start' }); toast('Setting your mods aside', 'The game starts in a moment.', '', 5000); await refreshState(); }
    catch (e) { toast('Could not start', e.message, 'bad', 10000); }
  }
  async function vanillaBack() {
    try { await api('/api/vanilla', { op: 'restore' }); toast('Bringing your mods back', '', '', 3000); await refreshState(); }
    catch (e) { toast('Could not bring them back', e.message, 'bad', 10000); }
  }

  const A = {
    'go': t => go(t.dataset.page),
    'go-lib': () => go('library'),
    'play': () => sys('play'),
    'open-mod': t => openMod(t.dataset.id),
    'open-col': t => openCollection(t.dataset.slug),
    'pane-close': () => closePane(),
    'pane-back': () => history.back(),
    'pane-min': () => setPaneMin(true),
    'pane-expand': () => setPaneMin(false),
    'hist-back': () => history.back(),
    'hist-fwd': () => history.forward(),
    'toggle-files': () => { const p = S.pane; if (p && p.kind === 'mod' && p.data) { p.filesOpen = !(p.filesOpen != null ? p.filesOpen : modAction(p.data.mod, p.data.files).kind === 'choose'); renderPane(); } },
    'desc-more': () => {
      const p = S.pane;
      if (!p) return;
      p.descOpen = !p.descOpen; renderPane();
      if (!p.descOpen) { const s = $('#pane .bb'); if (s && s.getBoundingClientRect().top < 0) s.closest('.sect').scrollIntoView({ block: 'start' }); }
    },
    'gal-step': t => galStep(+t.dataset.v),
    'gal-pick': t => { const p = S.pane; if (p && p.gal) { p.gal.i = +t.dataset.v; galRefresh(); } },
    'gal-zoom': () => { const p = S.pane; if (p && p.gal) { const items = galItems(p); openLightbox(items, items.indexOf(p.gal.list[galCur(p)]), paneTitle(p)); } },
    'bb-img': t => {
      const p = S.pane, u = t.dataset.u, items = p && p.gal ? galItems(p) : [];
      const i = items.findIndex(x => x.u === u);
      if (i >= 0) openLightbox(items, i, paneTitle(p)); else openLightbox([{ u, kind: 'img' }], 0, p ? paneTitle(p) : '');
    },
    'reqs-all': () => { const p = S.pane; if (p) { p.allReqs = !p.allReqs; renderPane(); } },
    'pick-preset': t => { const k = t.dataset.k; S[k] = cwOf(t.dataset.v, k); PICKERS[k].set(t.dataset.v, true); },
    'lb-close': () => closeLightbox(),
    'lb-step': t => lbStep(+t.dataset.v),
    'lb-noop': () => { },
    'toggle-old': () => { if (S.pane) { S.pane.showOld = !S.pane.showOld; renderPane(); } },
    'col-filter': t => { if (S.pane) { S.pane.filter = t.dataset.v; S.pane.showAll = false; renderPane(); } },
    'col-all': () => { if (S.pane) { S.pane.showAll = true; renderPane(); } },
    'col-queue': t => colQueue(t.dataset.scope),
    'get': t => getFile(t.dataset.mod, t.dataset.file, t.dataset.name),
    'queue-add': t => queueAdd([{ modId: +t.dataset.mod, fileId: +t.dataset.file, name: t.dataset.name, why: 'Added by you' }], false),
    'inspect': t => inspect(t.dataset.mod, t.dataset.file),
    'b-more': () => { S.b.err = null; loadBrowse(false); },
    'b-view': t => { S.b.view = t.dataset.v; savePrefs(); pageDiscover($('#page')); },
    'b-compat': t => { S.b.compat = t.dataset.v; savePrefs(); document.querySelectorAll('[data-act="b-compat"]').forEach(b => b.classList.toggle('on', b.dataset.v === S.b.compat)); loadBrowse(true); },
    'lib-filter': t => { S.lib.filter = t.dataset.v; renderLibBody(); },
    'lib-updates': () => checkUpdates(),
    'upd-batch': () => updateSelected(),
    'compat-run': () => ensureCompat(true),
    'lib-more': t => openMenu(t, [{ label: 'Key bindings', act: 'tool', data: { tool: 'keys' }, icon: 'key' }, { label: 'Find existing mods', act: 'tool', data: { tool: 'discover' }, icon: 'scan' }, { label: 'Check game logs', act: 'tool', data: { tool: 'gamelog' }, icon: 'info' }, { label: 'Update frameworks', act: 'fw-sync', icon: 'refresh' }, { label: 'Modpacks: share or get mods', act: 'tool', data: { tool: 'packs' }, icon: 'collections' }, '-', { label: 'Open game folder', act: 'sys', data: { op: 'folder' }, icon: 'folder' }]),
    'map-loc': t => { const o = S.lib.mapOpen, k = t.dataset.k; if (o.has(k)) o.delete(k); else o.add(k); renderLibList(); },
    'map-all': () => { const o = S.lib.mapOpen, ks = [...document.querySelectorAll('[data-act="map-loc"]')].map(b => b.dataset.k), all = ks.every(k => o.has(k)); ks.forEach(k => { if (all) o.delete(k); else o.add(k); }); renderLibList(); },
    'local-files': t => { const p = S.pane; if (!p) return; const fs = p.filesShown = p.filesShown || {}, n = t.dataset.name, cur = n in fs ? fs[n] : p.kind === 'files'; fs[n] = !cur; renderPane(); },
    'kill': () => killGame(),
    'key-save': () => saveKey(),
    'rep-tab': t => { S.rep.tab = t.dataset.v; renderReportsBody(); },
    'toggle-flowhelp': () => { prefs.flowHelp = !prefs.flowHelp; savePrefs(); renderReportsBody(); },
    'rep-hidden': () => { S.rep.showHidden = !S.rep.showHidden; renderReportsBody(); },
    'issue-hide': t => setIssueHidden(t.dataset.key, t.dataset.on === '1'),
    'issue-off': async t => {
      const n = t.dataset.name;
      if (!await ask({ title: `Turn off ${n}?`, body: 'Its files are set aside, not deleted, and the game starts without it. Turn it back on in the Library at any time.<br><br>This report changes after your next launch.', ok: 'Turn off' })) return;
      action({ op: 'disable', name: n }, `Turning off ${n}`);
    },
    'open-log': t => sysQuiet({ op: 'openFile', path: t.dataset.path }, 'Could not open the log'),
    'game-at': t => openGameAt(t.dataset.k),
    'disk-clean': () => diskClean(),
    'prof-save': () => profSave(($('#prof-name') || {}).value),
    'prof-update': t => profSave(t.dataset.name, true),
    'prof-apply': t => profApply(t.dataset.name),
    'prof-del': t => profDelete(t.dataset.name),
    'pack-check': () => { const c = (($('#pack-code') || {}).value || '').trim(); if (c) packFlow({ code: c }); else toast('Paste a code first', 'It starts with CPMODS.', 'warn', 4000); },
    'pack-make': () => packMake(),
    'pack-copy': t => packCopy(!!t.dataset.long),
    'disk-refresh': () => { S.disk = null; const el = $('#disk-now'); if (el) el.innerHTML = diskHtml(); loadDisk(); },
    'row-menu': t => {
      const m = findItem(t.dataset.name);
      if (!m) return;
      const nx = String(m.source || '').match(/nexus:(\d+)/), items = [];
      items.push({ label: 'Details and files', act: 'lib-open', data: { name: m.name }, icon: 'info' });
      if (m.modId) items.push({ label: 'Files only', act: 'show-files', data: { name: m.name }, icon: 'map' });
      if (nx) items.push({ label: 'Open on Nexus', act: 'open-url', data: { url: `${NEXUS}/mods/${nx[1]}` }, icon: 'ext' });
      if (m.archive) items.push({ label: 'Open the folder of its download', act: 'reveal-dl', data: { file: m.archive }, icon: 'folder' });
      if (m.fw) items.push({ label: 'Reinstall or update frameworks', act: 'fw-sync', icon: 'refresh' });
      if (!m.fw) { items.push('-'); items.push({ label: m.on ? 'Remove...' : 'Forget...', act: 'mod-remove', data: { name: m.name }, danger: true }); }
      openMenu(t, items);
    },
    'lib-open': t => { const m = findItem(t.dataset.name); if (!m) { toast('Not in your library', t.dataset.name, 'warn', 3000); return; } if (m.modId) openMod(m.modId); else openFiles(m.name); },
    'lib-view': t => { S.lib.view = t.dataset.v; savePrefs(); renderLibBody(); },
    'open-url': t => sysQuiet({ op: 'open', url: t.dataset.url }, 'Could not open the link'),
    'side-toggle': () => toggleSide(),
    'play-menu': t => openMenu(t, playMenuItems()),
    'play-mode': t => sys('play', { mode: t.dataset.mode }),
    'open-loc': t => sysQuiet({ op: 'openLoc', loc: t.dataset.loc }),
    'reveal': t => sysQuiet({ op: 'reveal', path: t.dataset.path }),
    'reveal-dl': t => sysQuiet({ op: 'reveal', file: t.dataset.file }),
    'reveal-crash': t => sysQuiet({ op: 'reveal', crash: t.dataset.id }),
    'steam': t => steamOp(t.dataset.what),
    'launch-refresh': () => loadLaunch(true),
    'open-crash': t => openCrash(t.dataset.id),
    'rep-mods': t => { S.rep.mods = t.dataset.v; renderReportsBody(); },
    'bisect-open': () => openBisect(),
    'bisect-scope': t => {
      const p = S.pane;
      if (!p || p.kind !== 'bisect') return;
      const v = t.dataset.v, cands = bisectCandidates(), good = lastGoodStart();
      p.scope = v; p.sel = {};
      if (v === 'all') cands.forEach(m => { p.sel[m.name] = true; });
      else if (v === 'changed' && good) cands.filter(m => { const x = toDate(m.installed); return x && x > good; }).forEach(m => { p.sel[m.name] = true; });
      renderPane();
    },
    'bisect-start': () => bisectStart(),
    'bisect-result': t => bisectResult(t.dataset.ok === '1'),
    'bisect-stop': t => bisectStop(t.dataset.keep === '1'),
    'compat-ignore': t => compatIgnore(t.dataset.key, t.dataset.on === '1'),
    'preview': t => openPreview(t.dataset.file),
    'dl-menu': t => {
      const f = t.dataset.file, st = t.dataset.status, mod = +t.dataset.mod, items = [];
      items.push({ label: 'What is inside, and where it goes', act: 'preview', data: { file: f }, icon: 'eye' });
      if (mod) items.push({ label: 'Mod page', act: 'open-mod', data: { id: mod }, icon: 'info' });
      items.push({ label: 'Open its folder', act: 'reveal-dl', data: { file: f }, icon: 'folder' });
      if (st === 'unused') items.push({ label: 'Install', act: 'dl-install', data: { archive: f }, icon: 'dl' });
      items.push('-', { label: 'Delete archive...', act: 'dl-delete', data: { file: f, status: st }, danger: true });
      openMenu(t, items);
    },
    'dl-jobs': t => { S.dl.jobs = t.dataset.v; savePrefs(); renderDlBody(); },
    'toggle-explain': () => {
      prefs.explain = prefs.explain !== true; savePrefs();
      if (S.pane) renderPane();
      if (S.page === 'library' && S.lib.view === 'map') renderLibList();
    },
    'show-files': t => openFiles(t.dataset.name),
    'tool': t => openTool(t.dataset.tool),
    'fw-sync': () => action({ op: 'sync' }, 'Installing frameworks and waiting mods'),
    'mod-remove': t => removeMod(t.dataset.name),
    'mod-enable': t => action({ op: 'enable', name: t.dataset.name }, `Enabling ${t.dataset.name}`),
    'disc-adopt': () => adoptSelected(),
    'disc-all': t => { const p = S.pane; if (p && p.data) { p.data.mods.forEach(m => { p.sel[m.id] = t.dataset.v === '1'; }); renderPane(); } },
    'disc-files': t => { const p = S.pane; if (p) { p.open[t.dataset.id] = !p.open[t.dataset.id]; renderPane(); } },
    'queue-next': () => queueOp({ op: 'next' }),
    'queue-clear': () => queueOp({ op: 'clear' }),
    'queue-skip': t => queueOp({ op: 'skip', fileId: +t.dataset.file }),
    'queue-remove': t => queueOp({ op: 'remove', fileId: +t.dataset.file }),
    'jobs-clear': () => action({ op: 'clearJobs' }),
    'job-cancel': (t) => action({ op: 'cancelJob', id: t.dataset.id }),
    'dl-arch': t => { S.dl.arch = t.dataset.v; savePrefs(); renderDlBody(); },
    'dl-done': () => { S.dl.showDone = !S.dl.showDone; renderDlBody(); },
    'variant': t => loadVariant(t.dataset.archive, t.dataset.name),
    'variant-cancel': () => { S.dl.variant = null; renderDlBody(); },
    'variant-install': () => { const v = S.dl.variant; if (!v || !v.sub) { toast('Pick a folder first', '', 'warn', 3000); return; } action({ op: 'install', archive: v.archive, name: (v.name || '').trim(), sub: v.sub }, 'Installing'); S.dl.variant = null; },
    'dl-install': t => action({ op: 'install', archive: t.dataset.archive }, 'Installing'),
    'dl-delete': async t => {
      const used = t.dataset.status === 'installed' || t.dataset.status === 'disabled';
      if (await ask({ title: 'Delete this archive?', body: `<b>${h(t.dataset.file)}</b>${used ? '<br><br>The mod stays installed, but you would have to download it again to turn it off and on or reinstall it.' : ''}`, ok: 'Delete', danger: true })) action({ op: 'deleteDownload', file: t.dataset.file });
    },
    'dismiss': t => action({ op: 'dismiss', name: t.dataset.name }),
    'modlist-export': () => exportModList(),
    'modlist-import': () => { const f = $('#ml-file'); if (f) { f.value = ''; f.click(); } },
    'package': t => makePackage(t.dataset.apponly === '1'),
    'settings-save': () => saveSettings({ patchLabel: $('#s-label').value, patchDate: $('#s-date').value }, true),
    'sys': t => sys(t.dataset.op),
    'win': t => window.chrome.webview.postMessage(t.dataset.v),
    'tb-reload': () => location.reload(),
    'perf-free': () => { IMG.free(); api('/api/free', {}).catch(() => { }); toast('Freeing memory', 'New numbers in a few seconds.', '', 2500); setTimeout(loadPerfNow, 4000); },
    'mouse-refresh': () => { S.mouse = null; const el = $('#mouse-set'); if (el) el.innerHTML = mouseHtml(); loadMouse(); },
    'perf-refresh': () => { S.perfNow = null; const el = $('#perf-now'); if (el) el.innerHTML = perfNowHtml(); loadPerfNow(); },
    'toast-close': t => { const x = t.closest('.toast'); if (x) x.remove(); },
    'settings-at': t => openSettings(t.dataset.k),
    'sx': t => toggleSection(t.dataset.k),
    'sx-all': () => { const open = setOpen(), all = SECTIONS.every(x => open.has(x.k)); prefs.setOpen = all ? [] : SECTIONS.map(x => x.k); savePrefs(); pageSettings($('#page')); },
    'perf-info': () => { prefs.perfInfo = prefs.perfInfo !== true; savePrefs(); pageSettings($('#page')); },
    'conflict-open': t => chooseConflict(t.dataset.archive),
    'bk-tab': t => { const p = S.pane; if (p && p.kind === 'backups') { p.tab = t.dataset.v; renderPane(); } },
    'bk-point': async () => { const r = await bkOp({ op: 'point' }, 'Restore point made'); if (r && !(S.pane && S.pane.kind === 'backups')) openTool('backups'); },
    'bk-plan': t => bkPlan(t.dataset.id),
    'bk-restore': t => bkRestorePoint(t.dataset.id),
    'bk-del': t => bkDelete(t.dataset.what, t.dataset.id),
    'bk-saves-now': () => api('/api/backups', { op: 'saves-backup' }).then(() => toast('Copying your saves', 'Progress shows in the bar at the bottom.', '', 3000)).catch(e => toast('Could not copy your saves', e.message, 'bad', 8000)),
    'bk-saves-restore': t => bkRestoreSaves(t.dataset.id),
    'bk-open': t => api('/api/backups', { op: 'open', id: t.dataset.id }).catch(e => toast('Could not open it', e.message, 'bad')),
    'bk-set-now': async () => { const r = await bkOp({ op: 'settings-backup' }); if (r) toast('Mod settings backed up', plural(r.count, 'file'), 'ok', 4000); },
    'bk-set-import': () => { const f = $('#bk-file'); if (f) { f.value = ''; f.click(); } },
    'bk-set-restore': t => bkRestoreSettings(t.dataset.id),
    'keys-filter': t => { const p = S.pane; if (p && p.kind === 'keys') { p.filter = t.dataset.v; renderPane(); } },
    'lo-win': t => loWin(t),
    'lo-undo': t => loUndo(t.dataset.archive),
    'vanilla-start': () => vanillaStart(),
    'vanilla-back': () => vanillaBack(),
  };

  document.addEventListener('click', ev => {
    const inMenu = ev.target.closest('#menu');
    if (!inMenu && menuAnchor && !menuAnchor.contains(ev.target)) closeMenu();
    const a = ev.target.closest('a[href^="http"]');
    if (a) { ev.preventDefault(); api('/api/system', { op: 'open', url: a.href }).catch(e => toast('Could not open link', e.message, 'bad')); return; }
    const t = ev.target.closest('[data-act]');
    if (!t) return;
    // a switch or checkbox inside a clickable row only toggles itself
    const ctl = ev.target.closest('input, select, textarea, label');
    if (ctl && ctl !== t && t.contains(ctl)) return;
    const fn = A[t.dataset.act];
    if (!fn) return;
    ev.preventDefault();
    if (inMenu) closeMenu();
    if (t.dataset.toast) { const x = t.closest('.toast'); if (x) x.remove(); }
    fn(t, ev);
  });
  // toggle does not bubble: caught on the way down
  document.addEventListener('toggle', ev => { const d = ev.target; if (d && d.dataset && d.dataset.grp) (S.compatOpen || (S.compatOpen = {}))[d.dataset.grp] = d.open; }, true);
  document.addEventListener('input', ev => {
    const t = ev.target;
    const pk = (t.id || '').match(/^(cw|bw)-(l|hex)$/);
    if (pk) {
      const k = pk[1], P = PICKERS[k];
      if (pk[2] === 'l') { const cw = S[k] || cwOf(P.cur(), k); S[k] = Object.assign({}, cw, { l: +t.value }); P.set(hslHex(S[k].h, S[k].s, S[k].l)); }
      else if (validHex(t.value)) { const x = normHex(t.value); S[k] = cwOf(x, k); P.set(x); }
      return;
    }
    if (t.id === 'b-q') { S.b.q = t.value; debounce('bq', () => loadBrowse(true), 380); }
    else if (t.id === 'c-q') { S.c.q = t.value; debounce('cq', renderColResults, 150); }
    else if (t.id === 'lib-q') { S.lib.q = t.value; renderLibList(); }
    else if (t.id === 'dl-q') { S.dl.q = t.value; debounce('dlq', renderDlBody, 120); }
    else if (t.id === 'col-q' && S.pane && S.pane.kind === 'col') { S.pane.q = t.value; const box = $('#colrows'); if (box) box.innerHTML = colRowsHtml(S.pane, colRows(S.pane.data)); }
    else if (t.id === 'v-name' && S.dl.variant) S.dl.variant.name = t.value;
    else if (t.id === 'keys-q' && S.pane && S.pane.kind === 'keys') { S.pane.q = t.value; const box = $('#keyrows'); if (box) box.innerHTML = keyRowsHtml(S.pane); }
    else if (S.pane && S.pane.kind === 'packs' && (t.id === 'pack-code' || t.id === 'pack-name')) S.pane[t.id === 'pack-code' ? 'input' : 'name'] = t.value;
  });
  document.addEventListener('change', ev => {
    const t = ev.target, d = t.dataset;
    if (t.id === 'b-sort') { S.b.sort = t.value; savePrefs(); loadBrowse(true); }
    else if (t.id === 'b-cat') { S.b.cat = t.value; savePrefs(); loadBrowse(true); }
    else if (t.id === 'b-tag') { S.b.tag = t.value; savePrefs(); loadBrowse(true); }
    else if (d.chip) { S.b[d.chip] = t.checked; t.closest('.chip').classList.toggle('on', t.checked); savePrefs(); loadBrowse(true); }
    else if (t.id === 'c-sort') { S.c.sort = t.value; savePrefs(); renderColResults(); }
    else if (t.id === 'c-cat') { S.c.cat = t.value; savePrefs(); renderColResults(); }
    else if (d.cchip) { S.c[d.cchip] = t.checked; t.closest('.chip').classList.toggle('on', t.checked); savePrefs(); renderColResults(); }
    else if (t.id === 'lib-kind') { S.lib.kind = t.value; savePrefs(); renderLibList(); }
    else if (t.id === 'lib-src') { S.lib.src = t.value; savePrefs(); renderLibList(); }
    else if (t.id === 'lib-sort') { S.lib.sort = t.value; savePrefs(); renderLibList(); }
    else if (t.id === 'dl-sort') { S.dl.sort = t.value; savePrefs(); renderDlBody(); }
    else if (d.usel) { S.lib.updSel[d.usel] = t.checked; renderLibList(); }
    else if (t.id === 'upd-all') { batchable().forEach(m => { S.lib.updSel[m.name] = t.checked; }); renderLibList(); }
    else if (d.toggle) action({ op: t.checked ? 'enable' : 'disable', name: d.toggle }, `${t.checked ? 'Enabling' : 'Disabling'} ${d.toggle}`);
    else if (d.disc && S.pane && S.pane.sel) { S.pane.sel[d.disc] = t.checked; renderPane(); }
    else if (d.bsel && S.pane && S.pane.kind === 'bisect') { S.pane.sel = S.pane.sel || {}; S.pane.sel[d.bsel] = t.checked; S.pane.scope = 'custom'; renderPane(); }
    else if (t.name === 'variant' && S.dl.variant) S.dl.variant.sub = t.value;
    else if (t.name === 'theme') setTheme(t.value);
    else if (t.name === 'bg') setBg(t.value);
    else if (t.id === 'cw-l' || t.id === 'bw-l') savePrefs();
    else if (t.id === 'cw-hex' || t.id === 'bw-hex') { if (validHex(t.value)) { t.value = normHex(t.value); savePrefs(); } else { t.value = PICKERS[t.id.slice(0, 2)].cur(); toast('Not a color code', 'Use 6 hex digits, like #ff3349.', 'warn', 4000); } }
    else if (d.perf) {
      prefs.perf = Object.assign({}, prefs.perf || {}, { [d.perf]: t.type === 'checkbox' ? t.checked : /^\d+$/.test(t.value) ? +t.value : t.value });
      savePrefs(); applyPerf(d.perf);
    }
    else if (d.pref) {
      prefs[d.pref] = t.checked; savePrefs();
      if (d.pref === 'sideMin') { applySide(); renderSideFoot(); layoutPane(); }
      if (S.pane) renderPane();
      toast('Saved', '', 'ok', 2000);
    }
    else if (d.setsel) saveSettings({ [d.setsel]: t.value }, false);
    else if (d.setting) saveSettings({ [d.setting]: t.checked }, false);
    else if (t.id === 's-browser') saveSettings({ browser: t.value }, false);
    else if (t.id === 'ml-file' && t.files && t.files[0]) importModList(t.files[0]);
    else if (t.id === 'bk-file' && t.files && t.files[0]) bkImport(t.files[0]);
    else if (t.id === 's-share-set') S.shareSettings = t.checked;
  });
  document.addEventListener('keydown', ev => {
    if (!$('#modal').hidden) return;
    if (S.lb) {
      if (ev.key === 'Escape') { ev.preventDefault(); closeLightbox(); }
      else if (ev.key === 'ArrowLeft' && !ev.altKey) { ev.preventDefault(); lbStep(-1); }
      else if (ev.key === 'ArrowRight' && !ev.altKey) { ev.preventDefault(); lbStep(1); }
      return;
    }
    if (ev.key === 'Escape') { if (!$('#menu').hidden) { closeMenu(); return; } if (S.pane) { closePane(); return; } }
    if (ev.key === 'Enter' && ev.target.matches('[data-act][tabindex]')) { ev.preventDefault(); ev.target.click(); return; }
    if (ev.key === 'Enter' && ev.target.id === 's-key') { ev.preventDefault(); saveKey(); return; }
    if (ev.key === 'Enter' && ev.target.id === 'prof-name') { ev.preventDefault(); profSave(ev.target.value); return; }
    if ((ev.key === 'b' || ev.key === 'B') && (ev.ctrlKey || ev.metaKey) && !ev.altKey && !typing()) { ev.preventDefault(); toggleSide(); return; }
    if (ev.key === '/' && !typing()) { const s = $('#b-q') || $('#c-q') || $('#lib-q') || $('#dl-q'); if (s) { ev.preventDefault(); s.focus(); } }
    // color wheels: left/right = color, up/down = strength
    if ((ev.target.id === 'cw' || ev.target.id === 'bw') && /^Arrow/.test(ev.key) && !ev.altKey) {
      ev.preventDefault();
      const k = ev.target.id, cw = Object.assign({}, S[k] || cwOf(PICKERS[k].cur(), k)), step = ev.shiftKey ? 15 : 4;
      if (ev.key === 'ArrowLeft') cw.h = (cw.h - step + 360) % 360; else if (ev.key === 'ArrowRight') cw.h = (cw.h + step) % 360;
      else if (ev.key === 'ArrowUp') cw.s = Math.min(100, cw.s + step); else cw.s = Math.max(0, cw.s - step);
      S[k] = cw; PICKERS[k].set(hslHex(cw.h, cw.s, cw.l), true);
    }
  });
  // color wheel drag: angle = color, distance from the center = strength (one update per frame)
  document.addEventListener('pointerdown', e => {
    const w = e.target.closest && e.target.closest('#cw, #bw');
    if (!w || e.button !== 0) return;
    e.preventDefault(); w.focus(); w.setPointerCapture(e.pointerId);
    const k = w.id;
    let last = e, queued = false;
    const pick = () => {
      queued = false;
      const r = w.getBoundingClientRect(), dx = last.clientX - (r.left + r.width / 2), dy = last.clientY - (r.top + r.height / 2);
      const base = S[k] || cwOf(PICKERS[k].cur(), k);
      S[k] = { h: Math.round((Math.atan2(dy, dx) * 180 / Math.PI + 360) % 360), s: Math.round(Math.min(1, Math.hypot(dx, dy) / (r.width / 2)) * 100), l: base.l };
      PICKERS[k].set(hslHex(S[k].h, S[k].s, S[k].l));
    };
    pick();
    const move = ev => { last = ev; if (!queued) { queued = true; requestAnimationFrame(pick); } };
    const up = () => { w.removeEventListener('pointermove', move); w.removeEventListener('pointerup', up); w.removeEventListener('pointercancel', up); savePrefs(); };
    w.addEventListener('pointermove', move); w.addEventListener('pointerup', up); w.addEventListener('pointercancel', up);
  });
  ['#page', '#pane'].forEach(sel => $(sel).addEventListener('scroll', () => closeMenu(), { passive: true }));
  window.addEventListener('resize', () => { layoutPane(); closeMenu(); });
  // gallery images: drop ones that fail or look like badges (load/error do not bubble, so capture)
  $('#pane').addEventListener('load', e => { const t = e.target; if (t.classList && (t.classList.contains('gthumb') || t.classList.contains('gimg'))) galCheck(t); }, true);
  $('#pane').addEventListener('error', e => {
    const t = e.target;
    if (!t.classList) return;
    // a small copy that does not exist: fall back to the full picture before giving up
    if (t.classList.contains('gthumb') && t.dataset.src && t.dataset.src !== t.dataset.u) { t.dataset.src = t.dataset.u; t.src = t.dataset.u; return; }
    if (t.classList.contains('gthumb') || t.classList.contains('gimg')) galDrop(t.dataset.u);
    else if (t.classList.contains('pane-hero')) { badImgs.add(t.getAttribute('src')); t.remove(); }
  }, true);
  // drag the left edge of the panel to resize it; double-click resets
  (() => {
    const grip = $('#paneGrip');
    let drag = null;
    grip.addEventListener('pointerdown', e => {
      if (e.button !== 0) return;
      e.preventDefault();
      grip.setPointerCapture(e.pointerId);
      const box = $('#paneBox');
      drag = { right: box.getBoundingClientRect().right, overlay: box.classList.contains('overlay') };
      document.body.classList.add('resizing');
    });
    grip.addEventListener('pointermove', e => {
      if (!drag) return;
      const max = drag.overlay ? window.innerWidth - 40 : $('.workspace').clientWidth - LIST_MIN_W;
      prefs.paneW = Math.round(Math.max(PANE_MIN_W, Math.min(max, drag.right - e.clientX)));
      layoutPane();
    });
    const end = () => { if (!drag) return; drag = null; document.body.classList.remove('resizing'); savePrefs(); };
    grip.addEventListener('pointerup', end);
    grip.addEventListener('pointercancel', end);
    grip.addEventListener('dblclick', () => { delete prefs.paneW; savePrefs(); layoutPane(); });
  })();
  window.addEventListener('pagehide', () => { flushPrefs(true); try { navigator.sendBeacon('/api/bye?t=' + encodeURIComponent(TOKEN)); } catch (e) { /* closing */ } });

  // ---------- state polling ----------
  function notifyJobs(st) {
    const first = S.jobsSeen === null, seen = S.jobsSeen || {}, next = {};
    for (const j of st.jobs) {
      next[j.id] = j.status;
      if (first) continue;
      const prev = seen[j.id];
      if (j.status !== 'running' && prev !== j.status) {
        // an install that stopped to ask gets a button to answer
        if (j.status === 'done' && /waiting for your choice/.test(j.detail || '')) toast(j.title, j.detail, 'warn', 20000, { label: 'Choose', act: 'conflict-open' });
        else if (j.status === 'done') toast(j.title, j.detail || 'Done', 'ok');
        else toast(j.title, j.error || 'Failed', 'bad', 14000);
        if (['restore', 'saves', 'vanilla'].includes(j.kind)) reloadBackups();
        if (j.kind === 'cleanup' || (j.kind === 'saves' && $('#disk-now'))) loadDisk();
        if (j.kind === 'profile') reloadProfiles();
        if (j.kind === 'pack' && S.pane && S.pane.kind === 'packs') renderPane();
      }
    }
    S.jobsSeen = next;
  }
  function stateSig(st) {
    const lt = st.launch, bs = st.bisect;
    return JSON.stringify([st.mods.map(m => [m.name, m.version, m.fileId, m.fileCount, m.broken, m.size]), st.disabled.map(d => d.name), st.pending.map(p => p.name),
      st.failed.map(f => [f.name, f.error]), st.queue.map(q => [q.fileId, q.done]), st.downloads.map(d => [d.file, d.status]), st.settings, st.game, st.key, st.handler, (st.browsers || []).length,
      lt ? [lt.log, lt.result, lt.lastCrash, lt.running] : null, bs ? [bs.round, bs.phase, bs.stepAt, (bs.off || []).length, (bs.errors || []).length] : null, st.vanilla ? [st.vanilla.seen, st.vanilla.parked] : null, needChoice().length,
      st.jobs.some(j => j.kind === 'bisect' && j.status === 'running'), st.profile]);
  }
  function onState(st) {
    S.st = st; S.offline = false;
    notifyJobs(st);
    const run = !!(st.game && st.game.running);
    if (st.vanilla) S.vanillaRun = true;
    if (S.wasRunning === true && !run) onGameExit();
    S.wasRunning = run;
    applyLean();
    // installed mods changed: compatibility and the launch report need a fresh look
    const modSig = JSON.stringify(st.mods.map(m => [m.name, m.fileId, m.fileCount]));
    if (S.modSig && modSig !== S.modSig) { if (S.lib.compat) S.lib.compatStale = true; S.launch.key = ''; }
    S.modSig = modSig;
    renderNav(); renderSideFoot(); renderBanner(); renderActivity();
    const sig = stateSig(st);
    if (!S.booted) { S.booted = true; S.sig = sig; renderPage(); if (S.pane) renderPane(); return; }
    if (sig !== S.sig) {
      S.sig = sig;
      if (S.lib.compatStale && (S.page === 'library' || S.page === 'compat')) debounce('compat', () => ensureCompat(true), 1500);
      if (S.page === 'discover') renderResults(true);
      else if (S.page === 'collections') renderColResults();
      // the Compatibility page has its own data (redrawn when its check reruns), not this state
      else if (!typing()) { if (S.page === 'library') renderLibBody(); else if (S.page === 'downloads') { pageDownloads($('#page')); } else if (S.page !== 'compat') renderPage(); }
      if (S.pane && ['mod', 'col', 'files', 'bisect', 'crash', 'preview'].includes(S.pane.kind) && (S.pane.data || ['files', 'bisect', 'crash'].includes(S.pane.kind)) && !(typing() && $('#pane').contains(document.activeElement))) renderPane();
    } else if (S.page === 'downloads') { const j = $('#jobs'); if (j) j.innerHTML = jobsHtml(); }
  }
  async function refreshState() {
    try {
      // the server answers {same:true} when nothing changed since the copy we have
      const r = await api('/api/state' + (S.stSig ? '?have=' + S.stSig : ''));
      if (r && r.same) { if (S.offline) { S.offline = false; renderBanner(); } return; }
      S.stSig = (r && r.sig) || '';
      onState(r);
    }
    catch (e) { S.offline = true; renderBanner(); }
  }
  // every few seconds while visible, every 20 s while hidden; coming back refreshes at once
  let pollTimer = 0, polling = false;
  async function pollLoop() {
    clearTimeout(pollTimer);
    if (polling) return;
    polling = true;
    try { await refreshState(); } finally { polling = false; }
    const st = S.st, busy = st && st.jobs.some(j => j.status === 'running'), live = st && st.game && arr(st.game.procs).length;
    // light mode while the game runs: 6 s visible, 60 s hidden
    pollTimer = setTimeout(pollLoop, S.offline ? 5000 : busy ? (document.hidden ? 5000 : 1000) : document.hidden ? (S.lean ? 60000 : 20000) : S.lean ? 6000 : live ? 2500 : 4000);
  }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) pollLoop(); });

  // deep links: #/library, #/discover/mod/8144, #/collections/col/slug, #/library/tool/compat
  const boot = parseRoute(location.hash);
  if (boot) { S.page = boot.page; savePrefs(); }
  try { history.scrollRestoration = 'manual'; } catch (e) { /* unsupported */ }
  renderTitlebar();
  applyTheme();
  applyPerfClasses();
  if (prefsMoved) savePrefs();
  applySide();
  renderNav();
  renderPage();
  setEntry(false);
  const early = boot && (boot.kind === 'mod' || boot.kind === 'col');
  if (early) openRoute(boot, 'replace');
  pollLoop().then(() => { if (boot && boot.kind && !early) openRoute(boot, 'replace'); });
})();
