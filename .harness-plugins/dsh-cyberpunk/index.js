/**
 * Host half of the cyberpunk work-style bundle.
 *
 * The whole style lives in the Client half (`client.js`): a `ctx.theme`
 * token layer plus two slot decorations. The Host row only has to exist so
 * the Loader entry — and with it the `dsh.client` bundle — is composed.
 *
 * @param {import('@deepseek-ai/cordis').Context} _ctx - owning plugin context.
 */
export function apply(_ctx) {}
