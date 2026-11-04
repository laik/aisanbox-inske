/**
 * Cyberpunk work style for the Harness Web UI.
 *
 * The style is applied through the Client theme registry, not through DOM
 * surgery: one `ctx.theme.overrideTokens()` layer replaces the alias-layer
 * tokens of whatever base theme is active, so Appearance (light / dark /
 * system) keeps working and the layer is disposed with the plugin.
 *
 * The palette therefore carries two coherent variants:
 *   - dark  → "Night City": deep-space surfaces, cyan ink, magenta alerts.
 *   - light → "Daylight Hacker": icy paper, ink text, violet accent.
 *
 * Two decorations complete the look inside allocated slots: a pointer-
 * transparent CRT scanline layer in `shell.overlay`, and a status line in
 * `conversation.composer.dock`.
 */
window.__ModuleLoader__.load({
  id: '@local/dsh-cyberpunk',
  factory(require) {
    const React = require('react');
    const h = React.createElement;

    /** Locale namespace owning this plugin's copy. */
    const NS = 'dsh.cyberpunk';
    /** Identity of the theme token layer (one layer per source). */
    const LAYER = '@local/dsh-cyberpunk';

    const zh = {
      'dock.online': '霓虹链路已接通',
    };
    const en = {
      'dock.online': 'NEON LINK ACTIVE',
    };

    /**
     * `[token, light value, dark value]` rows for the alias layer.
     * The two values are picked by the active theme's color scheme, so both
     * Appearance modes stay legible.
     */
    const TABLE = [
      // Surfaces ------------------------------------------------------------
      ['--dsw-alias-bg-base', '#f2f6ff', '#05060d'],
      ['--dsw-alias-bg-layer-1', '#ffffff', '#0a0d18'],
      ['--dsw-alias-bg-layer-2', '#f8fbff', '#0e1422'],
      ['--dsw-alias-bg-layer-3', '#eef4ff', '#121b2c'],
      ['--dsw-alias-bg-overlay', '#ffffff', '#0b1220'],
      ['--dsw-alias-bg-module-platform', '#e9f1ff', '#0d1424'],
      ['--dsw-alias-bg-multi-select', '#eef4ff', '#0b1120'],
      ['--dsw-alias-bg-document-preview', '#eef4ff', '#05060d'],
      ['--dsw-alias-bg-document-selection', 'rgba(0, 104, 168, 0.28)', 'rgba(0, 255, 247, 0.22)'],
      ['--dsw-alias-label-document-preview', '#3c5470', '#9fd8e6'],
      ['--dsw-alias-bg-skeleton', 'rgba(0, 60, 90, 0.07)', 'rgba(0, 255, 247, 0.08)'],
      ['--dsw-alias-bg-mask-1', 'rgba(9, 26, 44, 0.24)', 'rgba(2, 5, 12, 0.55)'],
      ['--dsw-alias-bg-mask-2', 'rgba(9, 26, 44, 0.12)', 'rgba(2, 5, 12, 0.28)'],
      ['--dsw-alias-bg-mask-3', 'rgba(9, 26, 44, 0.48)', 'rgba(2, 5, 12, 0.62)'],
      ['--dsw-alias-bg-mask-photo', 'rgba(4, 10, 20, 0.85)', 'rgba(1, 3, 8, 0.92)'],
      ['--dsw-alias-bg-mask-drop', 'rgba(240, 246, 255, 0.70)', 'rgba(8, 14, 26, 0.72)'],

      // Lines ---------------------------------------------------------------
      ['--dsw-alias-border-l1', 'rgba(0, 60, 90, 0.10)', 'rgba(0, 255, 247, 0.10)'],
      ['--dsw-alias-border-l2', 'rgba(0, 60, 90, 0.16)', 'rgba(0, 255, 247, 0.18)'],
      ['--dsw-alias-border-l2-darkmode-thin', 'rgba(0, 60, 90, 0.10)', 'rgba(0, 255, 247, 0.10)'],
      ['--dsw-alias-border-l3', 'rgba(0, 60, 90, 0.22)', 'rgba(0, 255, 247, 0.26)'],
      ['--dsw-alias-border-l4', 'rgba(0, 60, 90, 0.30)', 'rgba(0, 255, 247, 0.36)'],
      ['--dsw-alias-border-inverted', 'rgba(0, 60, 90, 0.08)', 'rgba(0, 255, 247, 0.08)'],
      ['--dsw-alias-border-inverted2', 'rgba(0, 60, 90, 0.12)', 'rgba(0, 255, 247, 0.10)'],

      // Ink -----------------------------------------------------------------
      ['--dsw-alias-label-primary', '#0a1424', '#e6feff'],
      ['--dsw-alias-label-secondary', '#3c5470', '#a3d4e2'],
      ['--dsw-alias-label-tertiary', '#5d7488', '#6d93a6'],
      ['--dsw-alias-label-caption', '#7b93a8', '#4e7386'],
      ['--dsw-alias-label-dimmed', '#dbe6f2', '#16232f'],
      ['--dsw-alias-label-primary-dimmed', '#0a1424', '#c6eef7'],
      ['--dsw-alias-label-primary-inverted', '#ffffff', '#0a0d18'],
      ['--dsw-alias-label-primary-foreground', '#ffffff', '#04070e'],
      ['--dsw-alias-label-primary-bluish', '#0a2a4a', '#dbfbff'],
      ['--dsw-alias-label-shimmer', 'rgba(10, 20, 36, 0.30)', 'rgba(0, 255, 247, 0.45)'],
      ['--dsw-alias-label-deep-diving', '#0f4a6b', '#8ef4ff'],
      ['--dsw-alias-label-deep-diving-shimmer', '#2a90b8', '#d6feff'],
      ['--dsw-alias-menu-icon', '#22374f', '#c6eef7'],
      ['--dsw-alias-link', '#0068a8', '#29e6ff'],

      // Brand and buttons ---------------------------------------------------
      ['--dsw-alias-brand-primary', '#5b2bff', '#00fff7'],
      ['--dsw-alias-brand-primary-invert', '#0a1424', '#7dfcff'],
      ['--dsw-alias-brand-primary-new-colorprimary-new-color', '#5b2bff', '#00fff7'],
      ['--dsw-alias-brand-text', '#2a1060', '#00fff7'],
      ['--dsw-alias-button-primary-fill', '#5b2bff', '#00fff7'],
      ['--dsw-alias-button-primary-hover', '#4a1fd6', '#8bffff'],
      ['--dsw-alias-button-primary-dimmed', '#dcd3ff', '#123c44'],
      ['--dsw-alias-button-contrast-fill', '#0a1424', '#d9f7ff'],
      ['--dsw-alias-button-elevated-fill', '#ffffff', '#0e1422'],
      ['--dsw-alias-button-floating-fill', '#ffffff', '#0b1220'],
      ['--dsw-alias-button-floating-hover', '#eff5ff', '#121b2c'],
      ['--dsw-alias-button-ghost-active-border', '#5b7a94', '#2fb6c4'],
      ['--dsw-alias-button-ghost-active-fill', '#e7efff', '#12303a'],
      ['--dsw-alias-button-ghost-active-hover', '#dce8ff', '#0f2530'],
      ['--dsw-alias-button-info-fill', '#007d9c', '#00b3ff'],
      ['--dsw-alias-button-info-hover', '#00a3c4', '#39c6ff'],
      ['--dsw-alias-button-tool-bar-fill-invisible', 'rgba(20, 40, 60, 0.30)', 'rgba(10, 20, 32, 0.55)'],
      ['--dsw-alias-button-tool-bar-fill', 'rgba(20, 40, 60, 0.45)', 'rgba(20, 56, 72, 0.62)'],
      ['--dsw-alias-button-tool-bar-hover', 'rgba(20, 40, 60, 0.60)', 'rgba(24, 72, 90, 0.78)'],

      // Interaction ---------------------------------------------------------
      ['--dsw-alias-interactive-bg-hover', 'rgba(0, 80, 120, 0.06)', 'rgba(0, 255, 247, 0.07)'],
      ['--dsw-alias-interactive-bg-active', 'rgba(0, 80, 120, 0.12)', 'rgba(0, 255, 247, 0.16)'],
      ['--dsw-alias-interactive-bg-hover-accent', 'rgba(91, 43, 255, 0.10)', 'rgba(0, 255, 247, 0.14)'],
      ['--dsw-alias-interactive-bg-hover-danger', 'rgba(216, 27, 96, 0.10)', 'rgba(255, 42, 109, 0.16)'],
      ['--dsw-alias-interactive-bg-hover-solid', '#e9f1ff', '#101a2b'],

      // States --------------------------------------------------------------
      ['--dsw-alias-state-business-primary', '#007f9e', '#00fff7'],
      ['--dsw-alias-state-business-tertiary', '#dff0ff', '#05323a'],
      ['--dsw-alias-state-success-primary', '#0e9f6e', '#2bff88'],
      ['--dsw-alias-state-success-secondary', '#38c99a', '#7dffb8'],
      ['--dsw-alias-state-success-tertiary', '#e2f7ee', '#06251a'],
      ['--dsw-alias-state-warn-primary', '#c77700', '#ffb020'],
      ['--dsw-alias-state-warn-secondary', '#e79a2b', '#ffd166'],
      ['--dsw-alias-state-warn-tertiary', '#fff3e0', '#241a05'],
      ['--dsw-alias-state-warn-label', '#a86400', '#ffc857'],
      ['--dsw-alias-state-error-primary', '#d81b60', '#ff2a6d'],
      ['--dsw-alias-state-error-secondary', '#ef5b8f', '#ff6f9d'],
      ['--dsw-alias-state-idle-primary', '#b9c9d8', '#24404f'],
      ['--dsw-alias-switch-thumb', '#ffffff', '#00fff7'],

      // Code and diffs ------------------------------------------------------
      ['--dsw-alias-markdown-code-block', '#edf4ff', '#070c16'],
      ['--dsw-alias-markdown-code-block-banner', '#e9f1ff', '#0b1322'],
      ['--dsw-alias-markdown-code-segment-selected', '#ffffff', '#0d1828'],
      ['--dsw-alias-markdown-code-segment-unselected', '#e7efff', '#070c16'],
      ['--dsw-alias-markdown-inline-code', '#e9f0fa', '#0c1524'],
      ['--dsw-alias-markdown-placeholder', '#eef4fb', '#0f1a29'],
      ['--dsw-alias-markdown-tag', '#e7efff', '#0d1726'],
      ['--dsw-alias-markdown-citation', '#e7f0ff', '#0b1424'],
      ['--dsw-alias-code-diff-added', 'rgba(14, 159, 110, 0.12)', 'rgba(43, 255, 136, 0.14)'],
      ['--dsw-alias-code-diff-deleted', 'rgba(216, 27, 96, 0.12)', 'rgba(255, 42, 109, 0.16)'],
      ['--dsw-alias-file-diff-added-bg', '#e8f8f0', '#06251a'],
      ['--dsw-alias-file-diff-added-gutter', '#f2fbf6', '#041a12'],
      ['--dsw-alias-file-diff-added-marker', '#0e9f6e', '#2bff88'],
      ['--dsw-alias-file-diff-deleted-bg', '#fde9f0', '#2a0714'],
      ['--dsw-alias-file-diff-deleted-gutter', '#fdf1f5', '#1c0510'],
      ['--dsw-alias-file-diff-deleted-marker', '#d81b60', '#ff2a6d'],

      // Surfaces of specific features ---------------------------------------
      ['--dsw-specific-bubble', '#e8f1ff', '#0b1a2e'],
      ['--dsw-specific-bubble-highlight', '#d8e8ff', '#123a52'],
      ['--dsw-specific-input-major', '#ffffff', '#080f1b'],
      ['--dsw-specific-login-input', '#f4f8ff', '#070c16'],
      ['--dsw-specific-sidebar-fill', '#eaf1fb', '#04060c'],
      ['--dsw-specific-sidebar-nav-item-active', '#e0ebff', '#0d2030'],
      ['--dsw-specific-sidebar-nav-item-active-accent', '#dff0ff', '#063a40'],
      ['--dsw-specific-sidebar-nav-item-hover', '#eaf2ff', '#0a1622'],
      ['--dsw-specific-selector', '#e9f1ff', '#0d1726'],
      ['--dsw-specific-tip', '#e8f1ff', '#0c1624'],
      ['--dsw-menu-surface-fill', 'rgba(255, 255, 255, 0.74)', 'rgba(6, 14, 24, 0.86)'],
      ['--dsw-specific-menu', 'rgba(255, 255, 255, 0.74)', 'rgba(6, 14, 24, 0.86)'],
      ['--dsw-alias-menu-group-header-fill', 'rgba(248, 251, 255, 0.94)', 'rgba(4, 10, 18, 0.94)'],
      ['--dsw-alias-toast-bg', '#0d1a2a', '#061018'],
      ['--dsw-alias-toast-label', '#eaf6ff', '#d9feff'],
      ['--dsw-alias-tooltip-bg', '#101f31', '#08121e'],
      ['--dsw-alias-tooltip-key-bg', '#1e3a52', '#122b3f'],

      // Chrome --------------------------------------------------------------
      ['--dsw-alias-scrollbar-bg-l1', '#c3d3e3', '#1b3b46'],
      ['--dsw-alias-scrollbar-bg-l2', '#b0c4d8', '#24505e'],
      ['--dsw-alias-scrollbar-hover-l1', '#a4b9cf', '#2d6b7c'],
      ['--dsw-alias-scrollbar-hover-l2', '#92aabf', '#3a8b9e'],
      ['--dsw-alias-turn-trigger-bg', '#edf4ff', 'rgba(0, 255, 247, 0.07)'],
      ['--dsw-alias-turn-trigger-bg-hover', 'rgba(0, 80, 120, 0.08)', 'rgba(0, 255, 247, 0.12)'],
      ['--dsw-elevation-stroke-color', 'rgba(0, 90, 120, 0.26)', 'rgba(0, 255, 247, 0.28)'],

      // Type and geometry (scheme-independent) -------------------------------
      [
        '--dsh-font-family-text',
        'ui-monospace, "SFMono-Regular", "SF Mono", "JetBrains Mono", "Cascadia Code", "Fira Code", Menlo, Consolas, "PingFang SC", monospace',
        'ui-monospace, "SFMono-Regular", "SF Mono", "JetBrains Mono", "Cascadia Code", "Fira Code", Menlo, Consolas, "PingFang SC", monospace',
      ],
      [
        '--dsh-font-family-code',
        '"JetBrains Mono", "Fira Code", "SF Mono", "Cascadia Code", Menlo, Consolas, monospace',
        '"JetBrains Mono", "Fira Code", "SF Mono", "Cascadia Code", Menlo, Consolas, monospace',
      ],
      ['--dsw-radius-xs', '2px', '2px'],
      ['--dsw-radius-sm', '4px', '4px'],
      ['--dsw-radius-md', '6px', '6px'],
      ['--dsw-radius-lg', '8px', '8px'],
      ['--dsw-radius-xl', '10px', '10px'],
      ['--dsw-radius-panel', '12px', '12px'],
    ];

    /** Composed `{ token: { light, dark } }` override map. */
    const TOKENS = {};
    for (const [name, light, dark] of TABLE) TOKENS[name] = { light, dark };

    /** CRT field: 1px dark rule every 3px plus a soft vignette, click-through. */
    const CRT_CSS = [
      '.dsh-cyberpunk-crt{position:absolute;inset:0;pointer-events:none;',
      'background-image:repeating-linear-gradient(to bottom,rgba(6,14,24,0.10) 0 1px,rgba(6,14,24,0) 1px 3px),',
      'radial-gradient(120% 90% at 50% 45%,rgba(4,10,18,0) 55%,rgba(4,10,18,0.22) 100%)}',
    ].join('');

    /** Neon status line under the composer card. */
    const STATUS_CSS = [
      '.dsh-cyberpunk-status{display:flex;align-items:center;justify-content:flex-end;gap:8px;',
      'padding:6px 2px 0;color:var(--dsw-alias-label-tertiary);font-size:11px;line-height:14px;',
      'letter-spacing:.16em;text-transform:uppercase;user-select:none;pointer-events:none}',
      '.dsh-cyberpunk-status-dot{width:6px;height:6px;border-radius:50%;flex:none;',
      'background:var(--dsw-alias-state-success-primary);box-shadow:0 0 6px var(--dsw-alias-state-success-primary);',
      'animation:dsh-cyberpunk-pulse 2.6s ease-in-out infinite}',
      '@keyframes dsh-cyberpunk-pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.35;transform:scale(.82)}}',
      '@media (prefers-reduced-motion:reduce){.dsh-cyberpunk-status-dot{animation:none}}',
    ].join('');

    /**
     * Frame-wide scanline layer; the overlay seat is click-through and the
     * root element keeps it that way even where the layer opts back in.
     * @returns the decoration tree.
     */
    function CrtOverlay() {
      return h(
        React.Fragment,
        null,
        h('style', null, CRT_CSS),
        h('div', { className: 'dsh-cyberpunk-crt', 'aria-hidden': true }),
      );
    }

    /**
     * Composer status line.
     * @param props - slot props; `t` comes from the `locale` registration.
     * @returns the status row.
     */
    function NeonStatus(props) {
      const t = props === undefined ? undefined : props.t;
      const label = typeof t === 'function' ? t('dock.online') : 'NEON LINK ACTIVE';
      return h(
        React.Fragment,
        null,
        h('style', null, STATUS_CSS),
        h(
          'div',
          { className: 'dsh-cyberpunk-status' },
          h('span', { className: 'dsh-cyberpunk-status-dot', 'aria-hidden': true }),
          h('span', null, label),
        ),
      );
    }

    return {
      inject: ['theme', 'locale', 'slots'],
      /**
       * Install the token layer and the two decorations for exactly the
       * plugin lifetime.
       * @param ctx - Client plugin context.
       */
      apply(ctx) {
        ctx.effect(() => ctx.theme.overrideTokens(LAYER, TOKENS), 'dsh-cyberpunk: token layer');
        ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'dsh-cyberpunk: dictionaries');

        ctx.slots.inject('shell.overlay', () =>
          ctx.slots.register(
            { name: 'shell.overlay', id: 'cyberpunk-crt', order: 900 },
            CrtOverlay,
          ),
        );
        ctx.slots.inject('conversation.composer.dock', () =>
          ctx.slots.register(
            { name: 'conversation.composer.dock', id: 'cyberpunk-status', order: 50, locale: NS },
            NeonStatus,
          ),
        );
      },
    };
  },
});
